# Performance integrations for this Mac

Tested 2026-09-27–28 on a Mac mini with base Apple M4 and 16 GiB unified memory. The iPhone is a remote client: these integrations run on the Mac host. They do not change or replace the selected model.

## Implemented paths

| Integration | Result on this Mac | Activation |
|---|---|---|
| [oMLX](https://github.com/jundot/omlx) | Qwen3 0.6B text, structured tool calls, repeated prompt caching, SmolVLM2 image reading, and app-managed unload passed. | Settings → Agent → Experimental inference → oMLX prompt caching. Only the verified Qwen3 0.6B and SmolVLM2 IDs are eligible. |
| [llama.cpp Metal](https://github.com/ggml-org/llama.cpp) | Short Huihui Q2_K text and BF16 projector checks passed. Longer 128-token requests later failed with Metal out-of-memory errors. | Disabled below 24 GiB after longer tests failed on this 16 GiB Mac. Exact Huihui ID only; an enabled candidate that fails to load retries the existing runtime. |
| [MLXFast Bonsai](https://github.com/Layr-Labs/mlxfast-bonsai2-27b-engine) | Native Swift server and optimized CBv2 adapter compiled. A live reply did not complete within this Mac's safe memory budget. | Disabled below 24 GiB. This floor is a conservative admission policy, not a successful benchmark on a 24 GiB Mac. Requires separate Bonsai MLX weights. |

All optional runtimes run as child processes, separate from the app's MLX ABI. They listen on loopback, join pool memory accounting, stop on unload/eviction, and have a parent-exit watchdog. Managed MLX children also have a physical-footprint guard. oMLX disables LAN discovery, uses a per-launch API key, and receives a dedicated model directory. Its per-model caches are bounded to 1 GB on SSD and 256 MB in memory. Failure to start oMLX falls back to the built-in MLX engine. The incompatible Bonsai ternary pack never falls through to ordinary MLX.

The Prism runtime at `/Users/m/llama-prism/llama-server` remains installed. Bonsai PQ2_0 GGUF continues to use it; stock llama.cpp does not replace Prism globally.

## Measurements and limits

The oMLX Qwen3 0.6B test repeated a synthetic 982-token prompt and generated an eight-token answer. Total request time was 1.515 s initially, then 0.248 s and 0.165 s, with 768 cached prompt tokens. The first request includes first-use costs. This is evidence of reusable prefix caching for that small model, not a general speed multiplier or a speedup for Huihui GGUF. A structured weather-tool request passed. The separate SmolVLM2 fixture returned `Bonsai 42.`; its plain-chat/tool behavior was inadequate, so it remains a vision sidecar.

For Huihui Q2_K, both runtimes used the same weights, projector, 4096-token context, 1024/256 batch profile, one slot, temperature zero, and prompt caching. A 467-token synthetic prompt took 9.473 s with the existing runtime and 10.092 s with the candidate on the first request. Repeated requests took 1.034/1.117 s versus 0.995/0.962 s. The image request took 10.437 s versus 9.931 s, with both returning `BONSAI 42`. Short output makes decode-rate estimates noisy. These short samples showed a small warm-response improvement, but they did not establish reliable operation. Subsequent 128-token response tests failed with GPU out-of-memory errors, first during concurrent testing and then in a separate run. Reducing the candidate to batch 256/microbatch 64, a 256 MiB RAM prompt cache and four context checkpoints did not resolve it. The candidate stays disabled on this 16 GiB Mac; the existing Prism runtime is retained. No usable speedup is claimed from the new Metal build on this device.

The MLXFast experiment downloaded the pinned 8.61 GB Bonsai pack. Both the stock ModelContainer route and the optimized CBv2 route exceeded the 16 GiB machine's safe process budget. The guarded optimized attempt reached about 11.27 GiB before termination. Metal kernel self-tests ran, but no full generation correctness or speed claim is warranted. The unsuccessful experiment's weights, unused MTP head, and temporary build products were removed. The compiled helper and source patch remain available for further testing on suitable hardware. Vision and speculation are not enabled in this adapter.

Deleting the separate SSD-streaming Qwen model was a disk-cleanup action, not a prerequisite for any integration. Its restoration uses the existing pinned artifact manifest and verifies every file's size and SHA-256. None of these paths changes that model's streaming engine.

## Pinned runtimes

- oMLX: `f0d8428acd3220c364177d1ea9593e4e15f94107`, isolated Python 3.13 environment; vision dependencies torch 2.14.0 and torchvision 0.29.0.
- llama.cpp v0.5.0: `7fe450e19305b828c199d602c23a8337aaa1f03b`, Release Metal with embedded library.
- MLXFast: `831fae740de35a106e85768d8b0534b4af422b13` plus `scripts/runtime-patches/mlxfast-vamp.patch` and `scripts/runtime-sources/VampBonsaiServerEngine.swift`.
- Qwen3 0.6B test checkpoint: `mlx-community/Qwen3-0.6B-4bit`, revision `73e3e38d981303bc594367cd910ea6eb48349da8`.
- Bonsai MLX experiment: `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`, revision `3f926b415992eaa2ae9dd7b573706494d6bbf787`.

Run `python3 scripts/install-inference-runtimes.py --runtime all` on an Apple Silicon Mac with Xcode, git, cmake and uv. The installer preserves existing runtime entries, does not enable settings or select models, and does not download Bonsai weights unless explicitly requested with `--bonsai-weights`. It builds locally; runtime binaries are not bundled in the DMG or IPA. Download Qwen3 0.6B from Vamp's model catalog to try the small cached-text path. The separate Bonsai MLXFast catalog entry is explicitly experimental and has a 24 GiB minimum. Neither 27B candidate has been validated on larger hardware. Quit/reload the active model after changing a runtime toggle.

`ManagedInferenceTests` covers manifest confinement, fallback, image forwarding and unload. The opt-in `LiveManagedInferenceTests` gates launch the real managed engines. Forward `TEST_RUNNER_BEETCODE_LIVE_MANAGED_INFERENCE=omlx` or `metal` and `TEST_RUNNER_BEETCODE_LIVE_VISION_IMAGE=/path/to/the/BONSAI-42-fixture.jpg` to `xcodebuild test`; the normal suite skips these tests. Live tests require the pinned installed models.

## Other candidates

[TensorFold](https://github.com/ashhart/TensorFold) supports M1–M4 as well as M5 in the reviewed source (`bb4b4a35863af562fc4ccb2586300d8f94b5d6de`). Its documented Qwen target plus drafter needs 16.1 + 3.8 GB before caches, app and OS memory, with a 32 GB+ recommendation. It does not load Huihui Q2_K GGUF. It was reviewed but not installed.

Vamp already offers experimental n-gram speculation, prompt reuse, KV8 and a narrowly matched Qwen3.5 9B DFlash path. They remain independent settings. [Upstream Metal MTP reports](https://github.com/ggml-org/llama.cpp/issues/23752) include regressions, so MTP is not enabled as a blanket optimization. [llama.cpp PR 28301](https://github.com/ggml-org/llama.cpp/pull/28301) targets MoE/IQ2/IQ3 kernels; it alone is not evidence for a dense Q2_K speedup.
