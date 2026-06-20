import Foundation
import Combine

/// Which backend fulfills a generation job. `palmier` is the hosted Convex backend
/// (subscription); the others are the user's own BYOK keys.
enum GenerationProviderKind: String, Sendable, Decodable, CaseIterable {
    case palmier, openrouter, fal, replicate
}

/// Abstraction over the RPC layer that submits a generation job, streams its status,
/// and hosts reference uploads. `PalmierGenerationProvider` wraps the existing Convex
/// `GenerationBackend`; BYOK providers talk to OpenRouter / fal directly.
@MainActor
protocol GenerationProvider: Sendable {
    func uploadReference(fileURL: URL, contentType: String) async throws -> String
    func submit(model: String, params: BackendGenerationParams, projectId: String?) async throws -> String
    func subscribe(jobId: String) -> AnyPublisher<BackendGenerationJob?, Never>?
}

@MainActor
struct PalmierGenerationProvider: GenerationProvider {
    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        try await GenerationBackend.uploadReference(fileURL: fileURL, contentType: contentType)
    }

    func submit(model: String, params: BackendGenerationParams, projectId: String?) async throws -> String {
        try await GenerationBackend.submit(model: model, params: params, projectId: projectId)
    }

    func subscribe(jobId: String) -> AnyPublisher<BackendGenerationJob?, Never>? {
        // Erase Convex's ClientError to Never; a failed subscription completes the stream,
        // matching the prior behavior where GenerationService finished on failure completion.
        GenerationBackend.subscribe(jobId: jobId)?
            .catch { _ in Empty<BackendGenerationJob?, Never>() }
            .eraseToAnyPublisher()
    }
}

/// Resolves the provider for a given model id and answers whether the user currently
/// holds the credential that model's provider needs.
@MainActor
enum GenerationProviders {
    static func kind(forModel id: String) -> GenerationProviderKind {
        ModelCatalog.shared.providerKind(forModel: id) ?? .palmier
    }

    static func provider(forModel id: String) -> any GenerationProvider {
        switch kind(forModel: id) {
        case .palmier: return PalmierGenerationProvider()
        case .openrouter: return OpenRouterGenerationProvider()
        case .fal: return FalGenerationProvider()
        case .replicate: return ReplicateGenerationProvider()
        }
    }

    static func keyPresent(for kind: GenerationProviderKind) -> Bool {
        switch kind {
        case .palmier: return AccountService.shared.isSignedIn && AccountService.shared.hasCredits
        case .openrouter: return OpenRouterKeychain.load() != nil
        case .fal: return FalKeychain.load() != nil
        case .replicate: return ReplicateKeychain.load() != nil
        }
    }

    static var anyBYOKKeyPresent: Bool {
        OpenRouterKeychain.load() != nil || FalKeychain.load() != nil || ReplicateKeychain.load() != nil
    }

    static func canGenerate(modelId: String) -> Bool {
        keyPresent(for: kind(forModel: modelId))
    }
}
