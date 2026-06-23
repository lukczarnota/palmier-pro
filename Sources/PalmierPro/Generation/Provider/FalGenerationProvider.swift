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
    /// Synchronous endpoint for "inference"-kind models (e.g. ElevenLabs) that reject queue.fal.run with 405.
    private static let syncBase = URL(string: "https://fal.run/")!
    private static let pollInterval: UInt64 = 5_000_000_000
    /// `subscribe` only receives the job id, but fal polling needs the model path too,
    /// so submit packs both into an opaque token GenerationService passes straight back.
    private static let tokenSeparator = "~|~"
    private static let syncPrefix = "sync~|~"

    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        // fal `image_url` fields accept inline data URIs, so no storage round-trip is needed.
        let data = try Data(contentsOf: fileURL)
        return "data:\(contentType);base64,\(data.base64EncodedString())"
    }

    func submit(model: String, params: BackendGenerationParams, projectId: String?) async throws -> String {
        guard let key = FalKeychain.load() else { throw FalError.missingKey }
        let body = try Self.requestBody(for: params, model: model)

        // Audio and image models on fal are "inference" kind — they use fal.run (sync), because
        // queue.fal.run returns 405 for them. Video/upscale stay on the async queue.
        let usesSyncEndpoint: Bool
        switch params {
        case .audio, .image: usesSyncEndpoint = true
        case .video, .upscale: usesSyncEndpoint = false
        }
        if usesSyncEndpoint {
            let url = Self.syncBase.appendingPathComponent(model)
            let data = try await send(url: url, method: "POST", key: key, jsonBody: body, timeout: 300)
            let result = try decode(FalResult.self, from: data)
            var urls: [String] = []
            if let u = result.audio?.url { urls.append(u) }
            if let u = result.video?.url { urls.append(u) }
            if let u = result.image?.url { urls.append(u) }
            if let imgs = result.images { urls += imgs.compactMap(\.url) }
            guard !urls.isEmpty else { throw FalError.noResult }
            return "\(Self.syncPrefix)\(urls.joined(separator: ","))"
        }

        let data = try await send(url: Self.base.appendingPathComponent(model), method: "POST", key: key, jsonBody: body)
        let decoded = try decode(FalSubmitResponse.self, from: data)
        return "\(model)\(Self.tokenSeparator)\(decoded.request_id)"
    }

    func subscribe(jobId token: String) -> AnyPublisher<BackendGenerationJob?, Never>? {
        // Sync-path audio: result already in the token, no polling needed.
        if token.hasPrefix(Self.syncPrefix) {
            let urlList = String(token.dropFirst(Self.syncPrefix.count))
            let urls = urlList.components(separatedBy: ",").filter { !$0.isEmpty }
            let job = BackendGenerationJob(
                _id: "sync", status: .succeeded, resultUrls: urls,
                errorMessage: nil, costCredits: nil, completedAt: nil
            )
            return Just(job).eraseToAnyPublisher()
        }

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

    private static func requestBody(for params: BackendGenerationParams, model: String) throws -> [String: Any] {
        switch params {
        case .video(let v):
            var body: [String: Any] = ["prompt": v.prompt]
            if v.duration > 0 { body["duration"] = String(v.duration) }
            if !v.aspectRatio.isEmpty { body["aspect_ratio"] = v.aspectRatio }
            if let img = v.startFrameURL { body["image_url"] = img }
            if let tail = v.endFrameURL { body["tail_image_url"] = tail }
            return body
        case .image(let i):
            return imageBody(i, model: model)
        case .upscale(let u):
            return ["video_url": u.sourceURL]
        case .audio(let a):
            return audioBody(a, model: model)
        }
    }

    /// fal audio endpoints use per-family input keys, so map our params to the model's schema.
    private static func audioBody(_ a: AudioGenerationParams, model: String) -> [String: Any] {
        if model.contains("elevenlabs/music") {
            var body: [String: Any] = ["prompt": a.prompt]
            if let d = a.durationSeconds, d > 0 { body["music_length_ms"] = Int(d * 1000) }
            if a.instrumental { body["force_instrumental"] = true }
            return body
        }
        if model.contains("elevenlabs/tts") {
            var body: [String: Any] = ["text": a.prompt]
            if let v = a.voice, !v.isEmpty { body["voice"] = v }
            return body
        }
        if model.contains("elevenlabs/sound-effects") {
            var body: [String: Any] = ["text": a.prompt]
            if let d = a.durationSeconds, d > 0 { body["duration_seconds"] = d }
            return body
        }
        // Generic music models (e.g. Lyria, MiniMax) take prompt + duration + optional lyrics.
        var body: [String: Any] = ["prompt": a.prompt]
        if let d = a.durationSeconds, d > 0 { body["duration"] = d }
        if let lyrics = a.lyrics { body["lyrics"] = lyrics }
        return body
    }

    /// fal image endpoints diverge on input keys: nano-banana/edit takes `image_urls` (array),
    /// flux-pro/kontext takes `image_url` (single) and both edit families size via `aspect_ratio`,
    /// while text→image FLUX sizes via `image_size`. Wrong key is a silent 422, so branch per family.
    private static func imageBody(_ i: ImageGenerationParams, model: String) -> [String: Any] {
        if model.contains("nano-banana") {
            var body: [String: Any] = ["prompt": i.prompt]
            if !i.imageURLs.isEmpty { body["image_urls"] = i.imageURLs }
            if !i.aspectRatio.isEmpty { body["aspect_ratio"] = i.aspectRatio }
            if i.numImages > 0 { body["num_images"] = i.numImages }
            return body
        }
        if model.contains("kontext") {
            var body: [String: Any] = ["prompt": i.prompt]
            if let first = i.imageURLs.first { body["image_url"] = first }
            if !i.aspectRatio.isEmpty { body["aspect_ratio"] = i.aspectRatio }
            if i.numImages > 0 { body["num_images"] = i.numImages }
            return body
        }
        // Generic FLUX text→image: sizes via image_size enum, not aspect_ratio.
        var body: [String: Any] = ["prompt": i.prompt]
        if !i.aspectRatio.isEmpty { body["image_size"] = fluxImageSize(for: i.aspectRatio) }
        if i.numImages > 0 { body["num_images"] = i.numImages }
        return body
    }

    private static func fluxImageSize(for aspectRatio: String) -> String {
        switch aspectRatio {
        case "16:9": return "landscape_16_9"
        case "9:16": return "portrait_16_9"
        case "4:3": return "landscape_4_3"
        case "3:4": return "portrait_4_3"
        default: return "square_hd"
        }
    }

    // MARK: - HTTP

    private func send(url: URL, method: String, key: String, jsonBody: [String: Any]?, timeout: TimeInterval = 60) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
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
