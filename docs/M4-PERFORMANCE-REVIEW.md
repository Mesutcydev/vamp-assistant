# Performance integrations for this Mac

Reviewed 2026-09-27. Target: Mac mini, base Apple M4, 16 GiB unified memory. The iPhone is a remote client; inference speed is determined by the Mac host. This is a compatibility review, not a claim of measured speedups from a new integration.

## Recommended order

| Priority | Integration | Expected benefit to test | Fit and limits |
|---|---|---|---|
| 1 | [oMLX](https://github.com/jundot/omlx) through Vamp’s custom OpenAI-compatible provider | Lower time to first token in repeated chats and coding sessions, using memory/SSD prefix caching | Supports M4, MLX text and vision models. Use a checkpoint that fits 16 GiB. It does not load the current Huihui GGUF. Continuous batching improves aggregate throughput, not necessarily one chat’s decode rate. |
| 2 | [Upstream llama.cpp Metal changes](https://github.com/ggml-org/llama.cpp) | Improve existing GGUF execution without changing model weights | Best architectural fit for Huihui. Benchmark the exact Q2_K model and projector before changing the runtime. [PR 28301](https://github.com/ggml-org/llama.cpp/pull/28301) targets routed MoE tiles and IQ2/IQ3 codebooks; it is not evidence of a Huihui dense Q2_K speedup. |
| 3 | [MLXFast Bonsai 2 engine](https://github.com/Layr-Labs/mlxfast-bonsai2-27b-engine) as an optional native backend | Specialized Swift/Metal kernels and speculative decoding | Target pack is about 8.61 GB plus a 0.24 GB MTP head, or a separate 3.85 GB DFlash drafter. The MTP configuration warrants a memory-budgeted M4 prototype; weights alone do not prove runtime fit. Requires Bonsai MLX weights and a forked MLX stack, not a flag for Huihui GGUF. Official leaderboard results are on M5. Preserve vision and tools before adopting. |
| 4 | [MLX Swift cache compression](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/Documentation.docc/kv-cache-quantization.md) | Reduce long-context memory pressure and swapping | Vamp already offers experimental 8-bit KV and prompt caching. New TurboQuant schemes need dependency/API integration plus model-specific accuracy and latency tests. Lower memory does not guarantee faster decoding. |
| Conditional | [TensorFold](https://github.com/ashhart/TensorFold) | Speculative decoding with model-specific kernels | Current code supports M1–M4 as well as M5. Tested Qwen target + drafter is 16.1 + 3.8 GB, before KV, OS and app memory; documented recommendation is 32 GB+. Its supported MLX quantization does not read Huihui Q2_K GGUF. API connection is easy; the tested configuration is a poor fit for this 16 GiB machine. |

TensorFold source checked at `bb4b4a35863af562fc4ccb2586300d8f94b5d6de` (0.3.4.1). The site’s older M5-only wording is less complete than the current repository. No external runtime was installed, no weights were substituted, and no performance improvement is claimed from these candidates.

## Already in Vamp

- GGUF: full GPU offload, one inference slot, exact-prefix prompt reuse, and a measured base-M4/16-GB batch profile of 1024/256.
- Experimental n-gram speculation without a separate draft model.
- Experimental DFlash limited to the trained Qwen3.5 9B pairing and admitted only when target plus draft fit the safe memory budget. It must not be enabled for an unrelated 27B checkpoint.
- Experimental MLX prompt reuse and 8-bit KV caching, with fallback on unsupported engines.
- Metal MTP is not enabled automatically: [upstream measurements](https://github.com/ggml-org/llama.cpp/issues/23752) report regressions on some Apple Silicon workloads. Any new implementation needs its own local comparison.

The installed `llama-server` reports build 10685 / `7dffb158d` and resolves to the existing `/Users/m/llama-prism/llama-server` custom runtime. Avoid replacing it globally based only on a benchmark headline; compare a separately installed candidate and preserve a fallback.

## Lower-priority option

[ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) is not the first choice here. Its maintainers explicitly limit fully functional, performant backends to CPU and CUDA and do not commit to resolving Metal issues. NVIDIA/CUDA integrations do not accelerate this M4 GPU.

## Acceptance before enabling an integration

Compare cold and warm first-token latency, prompt tokens/s, generated tokens/s, peak memory, swap growth, and output correctness on this Mac. Use the same checkpoint, prompt, context, temperature, output length and thermals; include short chat, a long follow-up, tool use, and an image. For speculation, measure accepted output tokens over elapsed decode time and include drafter memory. Never reuse the live user transcript as benchmark input.

Recommendation: retain the current GGUF vision backend for Huihui; trial oMLX with a fitting MLX checkpoint for repeated-session latency, and treat the Bonsai MLXFast backend as a separate native experiment. There is no verified drop-in 5× speed switch for the current Huihui model on this machine.
