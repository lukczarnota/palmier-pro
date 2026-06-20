# BYOK Generation Providers — Implementation Plan

Goal: let Palmier Pro generate media (video/image/audio/upscale) using the user's own
**OpenRouter** and/or **fal.ai** API keys, bypassing the Palmier subscription, via both the
in-app path and the MCP `generate_*` tools.

## Hard requirements

- **Each provider key is independently optional.** OpenRouter alone must fully work. fal.ai is
  an optional add-on. Both, either, or neither (neither -> existing Palmier subscription path).
- A model's provider is resolved **per model**, not by a global switch.
- The model catalog shows **only** models from providers whose key is present (+ Palmier catalog
  when signed in).
- Palmier subscription path behavior must remain **unchanged** when no BYOK key is set.

## Provider API contracts

### OpenRouter (video + image)
- Submit: `POST https://openrouter.ai/api/v1/videos`  Auth: `Authorization: Bearer <key>`
  Body: `{model, prompt, duration?, resolution?, aspect_ratio?, frame_images?, input_references?, generate_audio?, seed?}`
- Poll: `GET https://openrouter.ai/api/v1/videos/{id}` -> `{id, status: pending|in_progress|completed|failed, unsigned_urls?[]}`
- Download: `GET https://openrouter.ai/api/v1/videos/{id}/content?index=0`
- Models: `GET https://openrouter.ai/api/v1/videos/models`
- Image gen via OpenRouter images/chat-completions modalities (Nano Banana / GPT-image).
- Reference images: inline base64 data-URL.
- No Kling, no audio, no upscale.

### fal.ai (Kling, audio, upscale, more video/image)
- Submit: `POST https://queue.fal.run/{model_id}`  Auth: `Authorization: Key <key>`
- Poll: `GET https://queue.fal.run/{model_id}/requests/{request_id}/status` -> `IN_QUEUE|IN_PROGRESS|COMPLETED`
- Result: `GET https://queue.fal.run/{model_id}/requests/{request_id}` -> model-specific JSON with media URLs
- Reference upload: fal storage API or data-URL.

## Seams (confirmed in code)

- `GenerationService` calls `GenerationBackend.submit / subscribe / uploadReference` statically
  (lines ~244, ~305, ~320). These are the injection points.
- `BackendGenerationParams` = enum video/image/audio/upscale (the request payloads).
- `BackendGenerationJob { _id, status, resultUrls?, errorMessage?, ... }` = the job shape the
  service consumes. New providers must produce this shape.
- Catalog: `ModelCatalog` subscribes to Convex `models:list` -> `[CatalogEntry]`. `CatalogEntry`
  needs a `provider` tag; BYOK catalogs are merged in.
- Gate: `ToolExecutor+Generate.swift:6-11` checks `isSignedIn && hasCredits` before submit.
  Mirror the `AgentService.canStream` / `hasApiKey` bypass: allow when a relevant BYOK key exists.
- Keychain pattern: `AnthropicKeychain` + `KeychainStore` (`Utilities/KeychainStore.swift`).
- `AccountService.configure()` already no-ops gracefully without Clerk/Convex config
  (`isMisconfigured = true`) — Phase 1.5 is mostly the gate bypass, not crash-proofing.

## Stages (build green after each)

1. **Provider abstraction** — `GenerationProvider` protocol (submit/subscribe/uploadReference,
   producing `BackendGenerationJob`). `PalmierGenerationProvider` wraps existing `GenerationBackend`
   1:1. `GenerationService` resolves a provider from `genInput.model` and calls it instead of the
   static `GenerationBackend`. No behavior change.
2. **Keys** — `OpenRouterKeychain` + `FalKeychain` (account ids `openrouter-api-key`, `fal-api-key`),
   DEBUG env override, change notifications. Settings UI fields (reuse `AgentPane` pattern, AppTheme).
3. **OpenRouter provider** — client + `GenerationProvider` impl (video first, then image). Map
   `VideoGenerationParams`/`ImageGenerationParams` -> OpenRouter body. Polling -> `BackendGenerationJob`.
4. **fal provider** — client + impl. Kling/audio/upscale model routing. Polling -> `BackendGenerationJob`.
5. **Catalog merge** — `CatalogEntry.provider`; `OpenRouterModelCatalog` (from `/videos/models`) +
   curated fal list; union with only-keyed providers; per-model routing in the resolver.
6. **Gate** — allow generation when the chosen model's provider key is present, independent of
   Palmier sign-in. Helpful error when a model's provider key is missing.

## Constraints

- Swift 6 strict concurrency; `@MainActor` where existing code is. Keychain for keys (never UserDefaults).
- UI strictly via `AppTheme.*` (see AGENTS.md). Comments minimal.
- Do NOT touch Info.plist, secrets, signing, or the Convex/Clerk path's behavior.
- `swift build -c debug` must stay green.
