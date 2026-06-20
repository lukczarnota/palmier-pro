import Foundation

extension Notification.Name {
    static let openRouterAPIKeyChanged = Notification.Name("openRouterAPIKeyChanged")
    static let falAPIKeyChanged = Notification.Name("falAPIKeyChanged")
    static let replicateAPIKeyChanged = Notification.Name("replicateAPIKeyChanged")
}

/// User's OpenRouter API key (BYOK video/image generation). Stored in the macOS Keychain.
enum OpenRouterKeychain {
    private static let account = "openrouter-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .openRouterAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .openRouterAPIKeyChanged, object: nil)
    }
}

/// User's fal.ai API key (BYOK Kling / audio / upscale generation). Stored in the macOS Keychain.
enum FalKeychain {
    private static let account = "fal-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .falAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["FAL_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .falAPIKeyChanged, object: nil)
    }
}

/// User's Replicate API token (BYOK; broadest catalog — Kling, Veo, Seedance, Wan, Flux,
/// Nano Banana, GPT-image, audio, upscale). Stored in the macOS Keychain.
enum ReplicateKeychain {
    private static let account = "replicate-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .replicateAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["REPLICATE_API_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .replicateAPIKeyChanged, object: nil)
    }
}
