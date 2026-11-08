# macOS runtime compatibility — 2026-11-08

Both macOS projects use these pinned versions:

| Runtime | Version | Purpose |
| --- | --- | --- |
| MLX Swift | 0.32.3 | In-process MLX ABI required by MLX Swift LM 3.32.3 |
| MLX Swift LM | 3.32.3 | Latest tagged LM release; its new rejected-tool-call and throwing-cache APIs are handled |
| Upstream llama.cpp | v0.9.0 / b12110 | LFM2/3, Llama, and upstream Qwen GGUF architectures |
| Prism llama.cpp | prism-b12128-d7b2896 | Bonsai PQ2_0 / PTQ1_0 packed weights |

MLX Swift 0.33.0 is newer, but the tagged LM release requires the 0.32.x ABI.
Do not mix those versions. Newer architectures absent from the tagged MLX
library can use their supported GGUF variant. An architecture being supported
by a runtime does not guarantee that every model/quantization fits the Mac.
Existing memory admission and context limits still apply.

## Install the current GGUF runtimes

```sh
python3 scripts/install-inference-runtimes.py --runtime compatible
```

This downloads checksum-pinned official arm64 archives into this app's own
Application Support runtime directory. It preserves previous runtime entries,
model weights, user preferences, Homebrew, and the other app's storage. The
source-based oMLX, MLXFast, and llamaMetal experiments remain independently
opt-in. `--runtime all` includes them; they are not required for GGUF Omni or
Bonsai support.

The compatibility runtime is chosen automatically from GGUF metadata:

- Llama: `llama`, `llama4`.
- Qwen: `qwen`, `qwen2`, `qwen2moe`, `qwen2vl`, `qwen3`, `qwen3moe`,
  `qwen3next`, `qwen3vl`, `qwen3vlmoe`, `qwen35`, `qwen35moe`, `qwen4exp`,
  `qwen3tts`, and `rwkv6qwen2`. Qwen3.8 GGUF uses the upstream Qwen3.5 graph.
- Liquid: `lfm2`, `lfm2moe`, `lfm3` (including LFM3 Omni).
- Prism file types 141, 142, and 143 override ordinary architecture/model-ID
  rules. A renamed Bonsai import cannot accidentally select upstream Qwen.
  A failed packed Prism load does not retry an incompatible generic runtime.

Bonsai Q2_0 uses upstream llama.cpp with its Hadamard/sign-flip integration;
PQ2_0/PTQ1_0 require Prism. Deprecated pre-v7 group-128 Q2_0 files should be
replaced with a current published packing. Keep the matching projector beside
weights for models that accept images/audio. Imported checkpoints are supported;
a catalog ID is not required.

## Audio, video, and speech

Load LFM3 Omni GGUF with its matching vision/audio `mmproj` file. The child
server runs on loopback, with reasoning disabled for LFM3 multimodal models.
The session tools now provide:

- `analyze_media`: transcribe/translate audio, ask about images, or analyze
  video frames together with their soundtrack. Supply a file path inside the
  open workspace and a question. Audio supports WAV/MP3/FLAC; video supports
  MP4/MOV/MKV/WebM with ffmpeg installed and available in PATH.
- `generate_speech`: supply text, a new `.wav` workspace path, and optionally
  a language code (`en`, `tr`, etc.) and `female`/`male` voice. The runtime's
  native `/tts` endpoint generates the WAV. The normal write-approval policy
  applies. Existing files are never overwritten.

Example requests: “Transcribe recordings/meeting.wav in Turkish,” “Analyze
clips/demo.mp4 and describe both the video and its soundtrack,” or “Generate
female Turkish speech saying Merhaba and save greeting.wav.”

These tools use the active local model and inspect its reported input/output
modalities before inference. Unsupported models fail explicitly; media is not
forwarded to an API provider. Input files are bounded to 64 MB, prompts to
16 KB, generated audio to 32 MB, and requests to 180 seconds. Stop and unload
cancel in-flight media work. The chat transcript is preserved.

This adds file-based model capabilities. Live microphone/camera capture and
continuous duplex voice/video UI are not implemented by this update. Existing
text/image chat and the iOS protocol remain unchanged.

## Validation

- Both official binary archives passed their pinned SHA-256 checks and ran on
  this Apple Silicon Mac. Independent runtime manifests were installed for
  Assistant and Companion.
- LFM3 Omni Q4_K_M + Q4_K_M projector: correctly transcribed “The code word
  is violet. The number is forty two,” then identified a red video screen and
  the spoken code word together.
- Native speech produced PCM16 mono 24 kHz WAV; feeding that WAV back into
  Omni transcribed “Hello from VAMP.”
- Bonsai 2 2B PTQ1_0 generated the correct answer `4.` with Prism/Metal.
- The 27B/large MoE checkpoints and every family/quantization combination were
  not exhaustively loaded. Hardware memory limits still determine eligibility.
- Hermetic tests cover packed-format routing, typed audio/video payloads,
  capability checks, speech request fields, malformed WAV responses, archive
  traversal, checksum/tamper rejection, and preservation of existing manifests.

- Final macOS `build-for-testing` succeeded for both projects, including their
  unit-test bundles. 14 headless Swift core tests and 5 installer tests passed.
- App-hosted XCTest execution stalled before any tests ran, both before and
  after the update; that suite is not reported as passing. Companion's frozen
  iOS verification passed (76 unchanged files and unchanged targets/scheme).
- Website DMG preview 0.10.55 (134) includes both signed compatibility
  runtimes inside the app. Apple notarization and Sparkle promotion are deferred
  at the user’s request. Existing installed app bundles were not replaced.


Sources: [llama.cpp v0.9.0](https://github.com/ggml-org/llama.cpp/releases/tag/v0.9.0),
[Prism release](https://github.com/PrismML-Eng/llama.cpp/releases/tag/prism-b12128-d7b2896),
[Bonsai formats](https://github.com/PrismML-Eng/Bonsai-demo/blob/main/MODEL-FORMATS.md),
[Liquid Omni GGUF](https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF),
[server API at b12110](https://github.com/ggml-org/llama.cpp/blob/b12110/tools/server/README.md),
[MLX LM release](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3).
