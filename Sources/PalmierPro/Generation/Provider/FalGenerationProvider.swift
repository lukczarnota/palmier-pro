import Foundation
import Combine

enum FalError: LocalizedError {
    case missingKey
    case unsupported(String)
    case http(status: Int, body: String)
    case decode(String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No fal.ai API key. Add one in Settings > Agent."
        case .unsupported(let s): return s
        case .http(let status, let body): return "fal.ai HTTP \(status): \(body)"
        case .decode(let s): return "fal.ai response decode failed: \(s)"
        case .noResult: return "fal.ai job completed with no media output."
        }
    }
}

/// BYOK provider talking to the fal.ai queue API
/// (`POST https://queue.fal.run/{model}`, async polling, `Authorization: Key` auth).
/// The model id is the fal endpoint path (e.g. `fal-ai/kling-video/v2.1/master/text-to-video`),
/// which already encodes the t2v / i2v / upscale variant, so submit just POSTs to it.
@MainActor
struct FalGenerationProvider: GenerationProvider {
    private static let base = URL(string: "https://queue.fal.run/")!
    private static let pollInterval: UInt64 = 5_000_000_000
    /// `subscribe` only receives the job id, but fal polling needs the model path too,
    /// so submit packs both into an opaque token GenerationService passes straight back.
    private static let tokenSeparator = "~|~"

    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        // fal `image_url` fields accept inline data URIs, so no storage round-trip is needed.
        let data = try Data(contentsOf: fileURL)
        return "data:\(contentType);base64,\(data.base64EncodedString())"
    }

    func submit(model: String, params: BackendGenerationParams, projectId: String?) async throws -> String {
        guard let key = FalKeychain.load() else { throw FalError.missingKey }
        let body = try Self.requestBody(for: params)
        let data = try await send(url: Self.base.appendingPathComponent(model), method: "POST", key: key, jsonBody: body)
        let decoded = try decode(FalSubmitResponse.self, from: data)
        return "\(model)\(Self.tokenSeparator)\(decoded.request_id)"
    }

    func subscribe(jobId token: String) -> AnyPublisher<BackendGenerationJob?, Never>? {
        guard let key = FalKeychain.load() else { return nil }
        let parts = token.components(separatedBy: Self.tokenSeparator)
        guard parts.count == 2 else { return nil }
        let model = parts[0]
        let requestId = parts[1]

        let subject = PassthroughSubject<BackendGenerationJob?, Never>()
        let task = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    if let job = try await poll(model: model, requestId: requestId, key: key) {
                        subject.send(job)
                        if job.status == .succeeded || job.status == .failed {
                            subject.send(completion: .finished)
                            return
                        }
                    }
                } catch {
                    subject.send(BackendGenerationJob(
                        _id: requestId, status: .failed, resultUrls: nil,
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

    private func poll(model: String, requestId: String, key: String) async throws -> BackendGenerationJob? {
        let statusURL = Self.base
            .appendingPathComponent(model)
            .appendingPathComponent("requests/\(requestId)/status")
        let data = try await send(url: statusURL, method: "GET", key: key, jsonBody: nil)
        let status = try decode(FalStatusResponse.self, from: data)

        switch status.normalized {
        case .running:
            return BackendGenerationJob(
                _id: requestId, status: .running, resultUrls: nil,
                errorMessage: nil, costCredits: nil, completedAt: nil
            )
        case .completed:
            let urls = try await fetchResultURLs(model: model, requestId: requestId, key: key)
            guard !urls.isEmpty else { throw FalError.noResult }
            return BackendGenerationJob(
                _id: requestId, status: .succeeded, resultUrls: urls,
                errorMessage: nil, costCredits: nil, completedAt: nil
            )
        }
    }

    /// fal result payloads vary per model family; collect any media URL shape it returns.
    /// The hosted URLs (v3.fal.media/...) are public, so GenerationService downloads them as-is.
    private func fetchResultURLs(model: String, requestId: String, key: String) async throws -> [String] {
        let resultURL = Self.base
            .appendingPathComponent(model)
            .appendingPathComponent("requests/\(requestId)")
        let data = try await send(url: resultURL, method: "GET", key: key, jsonBody: nil)
        let result = try decode(FalResult.self, from: data)
        var urls: [String] = []
        if let u = result.video?.url { urls.append(u) }
        if let u = result.audio?.url { urls.append(u) }
        if let u = result.image?.url { urls.append(u) }
        if let imgs = result.images { urls += imgs.compactMap(\.url) }
        if let u = result.url { urls.append(u) }
        return urls
    }

    // MARK: - Request body

    private static func requestBody(for params: BackendGenerationParams) throws -> [String: Any] {
        switch params {
        case .video(let v):
            var body: [String: Any] = ["prompt": v.prompt]
            if v.duration > 0 { body["duration"] = String(v.duration) }
            if !v.aspectRatio.isEmpty { body["aspect_ratio"] = v.aspectRatio }
            if let img = v.startFrameURL { body["image_url"] = img }
            if let tail = v.endFrameURL { body["tail_image_url"] = tail }
            return body
        case .image(let i):
            var body: [String: Any] = ["prompt": i.prompt]
            if !i.aspectRatio.isEmpty { body["aspect_ratio"] = i.aspectRatio }
            if i.numImages > 0 { body["num_images"] = i.numImages }
            if let first = i.imageURLs.first { body["image_url"] = first }
            return body
        case .upscale(let u):
            return ["video_url": u.sourceURL]
        case .audio(let a):
            var body: [String: Any] = ["prompt": a.prompt]
            if let d = a.durationSeconds, d > 0 { body["duration"] = d }
            if let lyrics = a.lyrics { body["lyrics"] = lyrics }
            return body
        }
    }

    // MARK: - HTTP

    private func send(url: URL, method: String, key: String, jsonBody: [String: Any]?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FalError.http(status: http.statusCode, body: body)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FalError.decode(String(data: data, encoding: .utf8)?.prefix(300).description ?? "\(error)")
        }
    }
}

private struct FalSubmitResponse: Decodable {
    let request_id: String
}

private struct FalStatusResponse: Decodable {
    enum Normalized { case running, completed }
    let status: String?

    var normalized: Normalized {
        switch (status ?? "").uppercased() {
        case "COMPLETED": return .completed
        default: return .running
        }
    }
}

private struct FalResult: Decodable {
    struct Media: Decodable { let url: String? }
    let video: Media?
    let audio: Media?
    let image: Media?
    let images: [Media]?
    let url: String?
}
