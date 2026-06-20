import Foundation
import Combine

enum ReplicateError: LocalizedError {
    case missingKey
    case http(status: Int, body: String)
    case decode(String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No Replicate API key. Add one in Settings > Agent."
        case .http(let status, let body): return "Replicate HTTP \(status): \(body)"
        case .decode(let s): return "Replicate response decode failed: \(s)"
        case .noResult: return "Replicate prediction succeeded with no media output."
        }
    }
}

/// BYOK provider talking to the Replicate prediction API. The model id is an official-model
/// slug `owner/name` (e.g. `google/veo-3.1`); submit POSTs to that model's predictions
/// endpoint and polling hits the global `/v1/predictions/{id}`, so no model is threaded
/// through the job id (unlike fal).
@MainActor
struct ReplicateGenerationProvider: GenerationProvider {
    private static let modelsBase = URL(string: "https://api.replicate.com/v1/models/")!
    private static let predictionsBase = URL(string: "https://api.replicate.com/v1/predictions/")!
    private static let pollInterval: UInt64 = 5_000_000_000

    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        // Replicate accepts inline data URIs for small inputs; large refs would need the
        // Files API. Curated Replicate models here are text-to-X, so this is rarely hit.
        let data = try Data(contentsOf: fileURL)
        return "data:\(contentType);base64,\(data.base64EncodedString())"
    }

    func submit(model: String, params: BackendGenerationParams, projectId: String?) async throws -> String {
        guard let key = ReplicateKeychain.load() else { throw ReplicateError.missingKey }
        let input = Self.input(for: params)
        let url = Self.modelsBase.appendingPathComponent(model).appendingPathComponent("predictions")
        let data = try await send(url: url, method: "POST", key: key, jsonBody: ["input": input])
        let decoded = try decode(ReplicateSubmitResponse.self, from: data)
        return decoded.id
    }

    func subscribe(jobId: String) -> AnyPublisher<BackendGenerationJob?, Never>? {
        guard let key = ReplicateKeychain.load() else { return nil }
        let subject = PassthroughSubject<BackendGenerationJob?, Never>()
        let task = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    let job = try await poll(predictionId: jobId, key: key)
                    subject.send(job)
                    if job.status == .succeeded || job.status == .failed {
                        subject.send(completion: .finished)
                        return
                    }
                } catch {
                    subject.send(BackendGenerationJob(
                        _id: jobId, status: .failed, resultUrls: nil,
                        errorMessage: error.localizedDescription, costCredits: nil, completedAt: nil
                    ))
                    subject.send(completion: .finished)
                    return
                }
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
        return subject
            .handleEvents(receiveCancel: { task.cancel() })
            .eraseToAnyPublisher()
    }

    // MARK: - Polling

    private func poll(predictionId: String, key: String) async throws -> BackendGenerationJob {
        let url = Self.predictionsBase.appendingPathComponent(predictionId)
        let data = try await send(url: url, method: "GET", key: key, jsonBody: nil)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReplicateError.decode(String(data: data, encoding: .utf8)?.prefix(200).description ?? "non-object")
        }
        switch (obj["status"] as? String ?? "").lowercased() {
        case "succeeded":
            let urls = Self.extractURLs(obj["output"])
            guard !urls.isEmpty else { throw ReplicateError.noResult }
            return BackendGenerationJob(
                _id: predictionId, status: .succeeded, resultUrls: urls,
                errorMessage: nil, costCredits: nil, completedAt: nil
            )
        case "failed", "canceled":
            let message = (obj["error"] as? String) ?? "Replicate prediction failed"
            return BackendGenerationJob(
                _id: predictionId, status: .failed, resultUrls: nil,
                errorMessage: message, costCredits: nil, completedAt: nil
            )
        default: // starting, processing
            return BackendGenerationJob(
                _id: predictionId, status: .running, resultUrls: nil,
                errorMessage: nil, costCredits: nil, completedAt: nil
            )
        }
    }

    /// Replicate `output` is model-specific: a single URL string, an array of URL strings,
    /// or an object with a `url` field. Collect whatever media URLs it carries.
    private static func extractURLs(_ output: Any?) -> [String] {
        switch output {
        case let s as String:
            return s.hasPrefix("http") ? [s] : []
        case let arr as [Any]:
            return arr.compactMap { ($0 as? String).flatMap { $0.hasPrefix("http") ? $0 : nil } }
        case let dict as [String: Any]:
            if let u = dict["url"] as? String, u.hasPrefix("http") { return [u] }
            return []
        default:
            return []
        }
    }

    // MARK: - Request input

    private static func input(for params: BackendGenerationParams) -> [String: Any] {
        switch params {
        case .video(let v):
            var input: [String: Any] = ["prompt": v.prompt]
            if !v.aspectRatio.isEmpty { input["aspect_ratio"] = v.aspectRatio }
            if v.duration > 0 { input["duration"] = v.duration }
            if let img = v.startFrameURL { input["start_image"] = img }
            return input
        case .image(let i):
            var input: [String: Any] = ["prompt": i.prompt]
            if !i.aspectRatio.isEmpty { input["aspect_ratio"] = i.aspectRatio }
            return input
        case .upscale(let u):
            return ["video": u.sourceURL]
        case .audio(let a):
            return ["prompt": a.prompt]
        }
    }

    // MARK: - HTTP

    private func send(url: URL, method: String, key: String, jsonBody: [String: Any]?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ReplicateError.http(status: http.statusCode, body: body)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ReplicateError.decode(String(data: data, encoding: .utf8)?.prefix(300).description ?? "\(error)")
        }
    }
}

private struct ReplicateSubmitResponse: Decodable {
    let id: String
}
