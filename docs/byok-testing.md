# BYOK Providers — Test Guide

How to exercise the OpenRouter / fal.ai / Replicate BYOK generation feature. Each provider
key is independent and optional. Models appear in the catalog only when their provider's key
is present; routing is per-model via the catalog `provider` tag.

## 1. Keys

DEBUG builds read keys from env first, then the Keychain. Easiest for testing:

```bash
export OPENROUTER_API_KEY=sk-or-...
export FAL_KEY=fal-...
export REPLICATE_API_TOKEN=r8_...
scripts/dev.sh           # build + launch + stream OSLog (subsystem io.palmier.pro)
```

Or enter them in the app: Settings → Agent → OpenRouter / fal.ai / Replicate key fields.
Removing a key live-removes its models from the catalog (key-change observers rebuild it).

No Palmier login or subscription is needed for BYOK models. Palmier models still require sign-in.

## 2. Model ids by provider

### OpenRouter (video) — `POST /api/v1/videos`
- `google/veo-3.1`, `google/veo-3.1-fast`
- `alibaba/wan-2.7`
- `bytedance/seedance-2.0`
- `openai/sora-2-pro`  (note: Sora native API is deprecated; OpenRouter still serves it)

### fal.ai (video) — `queue.fal.run/{model}`
- `fal-ai/kling-video/v2.1/master/text-to-video`
- `fal-ai/kling-video/v2.1/master/image-to-video`  (needs a reference image)

### Replicate — `POST /v1/models/{owner}/{name}/predictions`
- Video: `google/veo-3.1`, `google/veo-3.1-fast`, `kwaivgi/kling-v3-video`, `bytedance/seedance-2.0`, `wan-video/wan-2.7-t2v`
- Image: `google/nano-banana-pro`, `openai/gpt-image-2`, `black-forest-labs/flux-2-pro`, `ideogram-ai/ideogram-v4-quality`
- Audio (music): `minimax/music-2.6`, `google/lyria-3`
- Upscale (video): `bytedance/video-upscaler`

## 3. In-app test
1. Open a project, open the generation UI.
2. Pick a BYOK model from the picker (e.g. "Kling 3.0 (Replicate)", "Nano Banana Pro (Replicate)").
3. Enter a prompt, generate. Watch placeholder -> generating -> downloading -> done.
4. Check OSLog (`Log.generation`) for submit/poll/download lines on failure.

## 4. MCP test (Claude Code / Cursor / Codex)
```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```
Then in the client:
- `list_models` -> should list BYOK models for whichever keys are present.
- `generate_video` with `model: google/veo-3.1` (OpenRouter) or `model: kwaivgi/kling-v3-video` (Replicate).
- `generate_image` with `model: google/nano-banana-pro` (Replicate).
- `generate_audio` with `model: minimax/music-2.6` (Replicate).
- `upscale_media` with a video asset + `model: bytedance/video-upscaler` (Replicate).

## 5. Known-risky / first-test checklist
- **Replicate input keys vary per model** and Replicate rejects unknown keys with HTTP 422.
  We send `prompt` + `aspect_ratio` (+ `duration` for video, `start_image` for i2v, `video` for
  upscale). If a model 422s, the error body names the bad/missing key — adjust the mapper in
  `ReplicateGenerationProvider.input(for:)`.
- **Model slugs rotate.** If a slug 404s, refresh it from `replicate.com/collections/official`
  (or the OpenRouter / fal model pages) and update `BYOKCatalog`.
- **Reference uploads** are sent as base64 data URIs. Large frames (>256KB on Replicate) may be
  rejected — switch to the provider's file-upload API if needed.
- **Result URLs:** OpenRouter content URLs need the API key, so we pre-download them with auth and
  hand a local file URL to the finalizer; fal/Replicate URLs are public and download directly.

## 6. Verify build/tests
```bash
swift build -c debug     # must be green
swift test               # 606 tests should pass
```
