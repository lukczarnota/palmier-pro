import Foundation
import Combine

enum OpenRouterError: LocalizedError {
    case missingKey
    case unsupported(String)
    case http(status: Int, body: String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No OpenRouter API key. Add one in Settings > Agent."
        case .unsupported(let s): return s
        case .http(let status, let body): return "OpenRouter HTTP \(status): \(body)"
        case .decode(let s): return "OpenRouter response decode failed: \(s)"
        }
    }
}

/// BYOK provider talking to the OpenRouter video API
/// (`POST /api/v1/videos`, async polling, Bearer auth). Video only for now.
@MainActor
struct OpenRouterGenerationProvider: GenerationProvider {
    private static let base = URL(string: "https://openrouter.ai/api/v1/")!
    private static let pollInterval: UInt64 = 5_000_000_000

    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        // OpenRouter takes inline image data; encode as a data URL the submit body embeds.
        let data = try Data(contentsOf: fileURL)
        return "data:\(contentType);base64,\(data.base64EncodedString())"
    }

    func submit(model: String, params: BackendGenerationParams, projectId: String?) async throws -> String {
        guard let key = OpenRouterKeychain.load() else { throw OpenRouterError.missingKey }
        guard case .video(let v) = params else {
            throw OpenRouterError.unsupported("OpenRouter BYOK currently supports video generation only.")
        }

        var body: [String: Any] = [
            "model": model,
            "prompt": v.prompt,
            "generate_audio": v.generateAudio,
        ]
        if v.duration > 0 { body["duration"] = v.duration }
        if !v.aspectRatio.isEmpty { body["aspect_ratio"] = v.aspectRatio }
        if let r = v.resolution, !r.isEmpty { body["resolution"] = r }

        var frames: [[String: Any]] = []
        if let s = v.startFrameURL { frames.append(["type": "image_url", "image_url": ["url": s], "frame_type": "first_frame"]) }
        if let e = v.endFrameURL { frames.append(["type": "image_url", "image_url": ["url": e], "frame_type": "last_frame"]) }
        if !frames.isEmpty { body["frame_images"] = frames }

        let data = try await send(path: "videos", method: "POST", key: key, jsonBody: body)
        let decoded = try decode(OpenRouterSubmitResponse.self, from: data)
        return decoded.id
    }

    func subscribe(jobId: String) -> AnyPublisher<BackendGenerationJob?, Never>? {
        guard let key = OpenRouterKeychain.load() else { return nil }
        let subject = PassthroughSubject<BackendGenerationJob?, Never>()
        let task = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    let job = try await poll(jobId: jobId, key: key)
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

    private func poll(jobId: String, key: String) async throws -> BackendGenerationJob {
        let data = try await send(path: "videos/\(jobId)", method: "GET", key: key, jsonBody: nil)
        let job = try decode(OpenRouterJobResponse.self, from: data)
        switch job.normalizedStatus {
        case .completed:
            let urls = try await downloadResults(job.unsigned_urls ?? [], key: key)
            return BackendGenerationJob(
                _id: jobId, status: .succeeded, resultUrls: urls,
                errorMessage: nil, costCredits: nil, completedAt: nil
            )
        case .failed:
            return BackendGenerationJob(
                _id: jobId, status: .failed, resultUrls: nil,
                errorMessage: job.error ?? "OpenRouter generation failed", costCredits: nil, completedAt: nil
            )
        case .running:
            return BackendGenerationJob(
                _id: jobId, status: .running, resultUrls: nil,
                errorMessage: nil, costCredits: nil, completedAt: nil
            )
        }
    }

    /// Content endpoints require the API key, so fetch each with auth into a temp file and
    /// hand GenerationService a local file URL to finalize.
    private func downloadResults(_ urls: [String], key: String) async throws -> [String] {
        var out: [String] = []
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                throw OpenRouterError.http(status: http.statusCode, body: "content download failed")
            }
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("openrouter-\(UUID().uuidString.prefix(8)).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            out.append(dest.absoluteString)
        }
        return out
    }

    // MARK: - HTTP

    private func send(path: String, method: String, key: String, jsonBody: [String: Any]?) async throws -> Data {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.http(status: http.statusCode, body: body)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OpenRouterError.decode(String(data: data, encoding: .utf8)?.prefix(300).description ?? "\(error)")
        }
    }
}

private struct OpenRouterSubmitResponse: Decodable {
    let id: String
}

private struct OpenRouterJobResponse: Decodable {
    enum Normalized { case running, completed, failed }
    let id: String?
    let status: String?
    let unsigned_urls: [String]?
    let error: String?

    var normalizedStatus: Normalized {
        switch (status ?? "").lowercased() {
        case "completed", "succeeded": return .completed
        case "failed", "error", "cancelled": return .failed
        default: return .running
        }
    }
}
