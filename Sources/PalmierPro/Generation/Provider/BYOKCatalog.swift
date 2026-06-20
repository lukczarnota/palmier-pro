import Foundation

/// Synthesizes catalog entries for BYOK providers so their models appear in the picker
/// and the agent tools even with no Convex connection. Only emits a provider's models
/// when that provider's key is present.
///
/// The OpenRouter list is curated (slugs verified against the OpenRouter video models
/// endpoint as of 2026-06); refresh it from `GET /api/v1/videos/models` when models change.
@MainActor
enum BYOKCatalog {
    static func entries() -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        if OpenRouterKeychain.load() != nil {
            out += openRouterVideoModels.map { Self.videoEntry($0, provider: .openrouter) }
        }
        if FalKeychain.load() != nil {
            out += falVideoModels.map { Self.videoEntry($0, provider: .fal) }
        }
        if ReplicateKeychain.load() != nil {
            out += replicateVideoModels.map { Self.videoEntry($0, provider: .replicate) }
            out += replicateImageModels.map { Self.imageEntry($0, provider: .replicate) }
            out += replicateAudioModels.map { Self.audioEntry($0, provider: .replicate) }
            out += replicateUpscaleModels.map { Self.upscaleEntry($0, provider: .replicate) }
        }
        return out
    }

    private struct VideoSpec {
        let id: String
        let name: String
        let aspectRatios: [String]
        var requiresImage: Bool = false
    }

    private static let openRouterVideoModels: [VideoSpec] = [
        VideoSpec(id: "google/veo-3.1", name: "Veo 3.1 (OpenRouter)", aspectRatios: ["16:9", "9:16"]),
        VideoSpec(id: "google/veo-3.1-fast", name: "Veo 3.1 Fast (OpenRouter)", aspectRatios: ["16:9", "9:16"]),
        VideoSpec(id: "alibaba/wan-2.7", name: "Wan 2.7 (OpenRouter)", aspectRatios: ["16:9", "9:16", "1:1"]),
        VideoSpec(id: "bytedance/seedance-2.0", name: "Seedance 2.0 (OpenRouter)", aspectRatios: ["16:9", "9:16", "1:1"]),
        VideoSpec(id: "openai/sora-2-pro", name: "Sora 2 Pro (OpenRouter)", aspectRatios: ["16:9", "9:16"]),
    ]

    /// fal endpoint paths double as model ids. The slug already encodes the t2v / i2v variant.
    /// Verified against the fal.ai Kling model pages as of 2026-06; refresh when fal revs versions.
    private static let falVideoModels: [VideoSpec] = [
        VideoSpec(id: "fal-ai/kling-video/v2.1/master/text-to-video", name: "Kling 2.1 Master · text→video (fal)", aspectRatios: ["16:9", "9:16", "1:1"]),
        VideoSpec(id: "fal-ai/kling-video/v2.1/master/image-to-video", name: "Kling 2.1 Master · image→video (fal)", aspectRatios: ["16:9", "9:16", "1:1"], requiresImage: true),
    ]

    /// Replicate official-model slugs (`owner/name`, stable API, no version pinning).
    /// Curated as of 2026-06; refresh from replicate.com/collections/official when slugs rev.
    private static let replicateVideoModels: [VideoSpec] = [
        VideoSpec(id: "google/veo-3.1", name: "Veo 3.1 (Replicate)", aspectRatios: ["16:9", "9:16"]),
        VideoSpec(id: "google/veo-3.1-fast", name: "Veo 3.1 Fast (Replicate)", aspectRatios: ["16:9", "9:16"]),
        VideoSpec(id: "kwaivgi/kling-v3-video", name: "Kling 3.0 (Replicate)", aspectRatios: ["16:9", "9:16", "1:1"]),
        VideoSpec(id: "bytedance/seedance-2.0", name: "Seedance 2.0 (Replicate)", aspectRatios: ["16:9", "9:16", "1:1"]),
        VideoSpec(id: "wan-video/wan-2.7-t2v", name: "Wan 2.7 (Replicate)", aspectRatios: ["16:9", "9:16", "1:1"]),
    ]

    private struct ImageSpec {
        let id: String
        let name: String
        let aspectRatios: [String]
    }

    private static let replicateImageModels: [ImageSpec] = [
        ImageSpec(id: "google/nano-banana-pro", name: "Nano Banana Pro (Replicate)", aspectRatios: ["1:1", "16:9", "9:16"]),
        ImageSpec(id: "openai/gpt-image-2", name: "GPT-image-2 (Replicate)", aspectRatios: ["1:1", "16:9", "9:16"]),
        ImageSpec(id: "black-forest-labs/flux-2-pro", name: "FLUX.2 Pro (Replicate)", aspectRatios: ["1:1", "16:9", "9:16"]),
        ImageSpec(id: "ideogram-ai/ideogram-v4-quality", name: "Ideogram v4 (Replicate)", aspectRatios: ["1:1", "16:9", "9:16"]),
    ]

    private static func imageEntry(_ spec: ImageSpec, provider: GenerationProviderKind) -> CatalogEntry {
        CatalogEntry(
            id: spec.id,
            kind: .image,
            displayName: spec.name,
            allowedEndpoints: [],
            responseShape: .images,
            uiCapabilities: .image(ImageCaps(
                resolutions: nil,
                aspectRatios: spec.aspectRatios,
                qualities: nil,
                supportsImageReference: false,
                maxImages: 1
            )),
            creditsPerSecond: nil,
            audioDiscountRate: nil,
            creditsPerImage: nil,
            qualities: nil,
            audioPricing: nil,
            creditsPerSecondUpscale: nil,
            provider: provider
        )
    }

    private struct SimpleSpec {
        let id: String
        let name: String
    }

    /// Music models (prompt-driven) — chosen so the generic `prompt` input mapping is valid.
    /// TTS models on Replicate take a `text` key instead, so they are intentionally excluded.
    private static let replicateAudioModels: [SimpleSpec] = [
        SimpleSpec(id: "minimax/music-2.6", name: "MiniMax Music 2.6 (Replicate)"),
        SimpleSpec(id: "google/lyria-3", name: "Lyria 3 music (Replicate)"),
    ]

    private static let replicateUpscaleModels: [SimpleSpec] = [
        SimpleSpec(id: "bytedance/video-upscaler", name: "Video upscaler 4K (Replicate)"),
    ]

    private static func audioEntry(_ spec: SimpleSpec, provider: GenerationProviderKind) -> CatalogEntry {
        CatalogEntry(
            id: spec.id,
            kind: .audio,
            displayName: spec.name,
            allowedEndpoints: [],
            responseShape: .audio,
            uiCapabilities: .audio(AudioCaps(
                category: "music",
                voices: nil,
                defaultVoice: nil,
                supportsLyrics: true,
                supportsInstrumental: true,
                supportsStyleInstructions: false,
                durations: nil,
                minPromptLength: 0,
                inputs: nil,
                promptLabel: nil,
                minSeconds: nil,
                maxSeconds: nil
            )),
            creditsPerSecond: nil,
            audioDiscountRate: nil,
            creditsPerImage: nil,
            qualities: nil,
            audioPricing: nil,
            creditsPerSecondUpscale: nil,
            provider: provider
        )
    }

    private static func upscaleEntry(_ spec: SimpleSpec, provider: GenerationProviderKind) -> CatalogEntry {
        CatalogEntry(
            id: spec.id,
            kind: .upscale,
            displayName: spec.name,
            allowedEndpoints: [],
            responseShape: .upscaledImage,
            uiCapabilities: .upscale(UpscaleCaps(
                speed: "Medium",
                p75DurationSeconds: 60,
                supportedTypes: ["video"]
            )),
            creditsPerSecond: nil,
            audioDiscountRate: nil,
            creditsPerImage: nil,
            qualities: nil,
            audioPricing: nil,
            creditsPerSecondUpscale: nil,
            provider: provider
        )
    }

    private static func videoEntry(_ spec: VideoSpec, provider: GenerationProviderKind) -> CatalogEntry {
        CatalogEntry(
            id: spec.id,
            kind: .video,
            displayName: spec.name,
            allowedEndpoints: [],
            responseShape: .video,
            uiCapabilities: .video(permissiveVideoCaps(aspectRatios: spec.aspectRatios, requiresImage: spec.requiresImage)),
            creditsPerSecond: nil,
            audioDiscountRate: nil,
            creditsPerImage: nil,
            qualities: nil,
            audioPricing: nil,
            creditsPerSecondUpscale: nil,
            provider: provider
        )
    }

    /// Empty `durations`/`nil resolutions` mean VideoModelConfig.validate() skips those
    /// checks, so the provider's own defaults apply unless the caller passes explicit values.
    private static func permissiveVideoCaps(aspectRatios: [String], requiresImage: Bool) -> VideoCaps {
        VideoCaps(
            durations: [],
            resolutions: nil,
            aspectRatios: aspectRatios,
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: requiresImage ? 1 : 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "reference",
            requiresSourceVideo: false,
            requiresReferenceImage: requiresImage
        )
    }
}
