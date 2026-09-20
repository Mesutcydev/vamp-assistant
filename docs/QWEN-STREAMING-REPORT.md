# Qwen3.5 SSD streaming implementation report

**CORRECTNESS BASELINE VALIDATED — EXPLICIT ATTENTION PATH MATCHES INDEPENDENT REFERENCE.** Q2.16 established the independent 64-token K=8 explicit baseline and Q2.17 closed the app lifecycle gates. This qualification applies only to the developer-only `referenceCompatibleExplicit` strategy. The user-facing fused production path remains experimental/unvalidated; no default, pool, or performance change was made.

## 1. Workspace and integration

Implementation is in the current Downloads `beetcode/BeetCode` macOS workspace. The older Desktop checkout was mistakenly used for the first baseline test launch; that process was stopped. No inference implementation was added there, and its temporary build directory was removed.

The existing `LLMEngine` / `EngineRouter` / `EnginePool` path now has an experimental `qwenStreaming` format. Existing backend entries, bundle identity, app name, signing configuration, UI design, sessions, and settings remain in place. The original full-resident Qwen entry remains unchanged. The new entry has ID `qwen3.5-35b-a3b-streaming-4bit`.

## 2. Immutable references and licenses

- Official model: `Qwen/Qwen3.5-35B-A3B`, revision `59d61f3ce65a6d9863b86d2e96597125219dc754`.
- Community conversion: `mlx-community/Qwen3.5-35B-A3B-4bit`, revision `1e20fd8d42056f870933bf98ca6211024744f7ec`, Apache-2.0 per its model card.
- Existing dependency retained: mlx-swift 0.31.6, `0bb916c67f4b9e5c682cbe02a42c701c93ab5021`, MIT.
- Existing dependency retained: mlx-swift-lm 3.31.4, `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`, MIT. The native text-model implementation is adapted from this source with an asynchronous routed-MoE seam; the full routed module is never instantiated.
- Independent Python reference: mlx-lm 0.31.1 from the pinned compatible implementation, MLX 0.32.2, CPU/lazy safetensors against the installed artifact. The checked-in fixture records `mlx-lm 0.31.1+mamba_ssm_dtype=float32`, the config-declared FP32 recurrent state, and the artifact revision. This is an independent quantized logit oracle; it is not a second invocation of the Swift streaming implementation.
- Inspected Flash-MoE reference: `089cb24b88f6b60c1d99842ec7052fa0a0146009`. Its M4/16 GB 11.5 tok/s entry uses K=6; it is not an acceptance figure for this implementation.
- Generic range storage and generic storage tests were adapted from the identified ios-local-llm source. Its MIT notice and the MLX source notice are retained in `QWEN-STREAMING-NOTICES.md`. No Edge0 model math, LoRA, prerouter, or model-output fixture was adopted.

References: https://huggingface.co/mlx-community/Qwen3.5-35B-A3B-4bit/tree/1e20fd8d42056f870933bf98ca6211024744f7ec ; https://github.com/ml-explore/mlx-swift-lm/tree/bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57 ; https://github.com/tayoun/flash-moe/blob/089cb24b88f6b60c1d99842ec7052fa0a0146009/README.md

## 3. Semantics

Pinned configuration read from the installed `config.json`: 40 layers, hidden size 2048, vocabulary 248320, 256 routed experts, K=8 plus one shared expert; 30 `linear_attention` (GatedDeltaNet) and 10 `full_attention` layers. Linear attention uses 16 key heads and 32 value heads with dimension 128 and convolution kernel 4. Full attention uses 16 query heads, two KV heads, dimension 256, query/key normalization, output gating, RoPE theta 10,000,000, and partial rotary factor 0.25. The config declares float32 recurrent state and a 262,144-token architectural context; admission still caps this Mac at a practical 4096-token window. Quantization is affine, four bits, group size 64. No K=4/K=6 option, Recover-LoRA, predictor, MTP, vision loading, or prefix reuse exists in this backend.

The exact path retains upstream router selection/order, gathered quantized expert math, common quantized modules, attention and recurrent primitives, and explicit evaluation before selected expert payloads can be evicted. The independent five-fixture gate checks full final logits and greedy top-1 IDs against the same quantized artifact. Q2.16/Q2.17 then supplied the accepted 64-token generated-ID, router, state/cache, and lifecycle evidence for the developer-only explicit strategy; the user-facing fused strategy remains outside that qualification.

## 4. Inventory

The complete pinned payload is installed at `/Users/m/Library/Application Support/BeetCode/Models/qwen3.5-35b-a3b-streaming-4bit`. Header geometry and hashes, config/index hashes, and published payload SHA-256 values are pinned in `QwenStreamArtifact`; all ten installed files match the pinned sizes and SHA-256 values.

| Item | Exact bytes |
| --- | ---: |
| model-00001-of-00004.safetensors | 5,285,828,971 |
| model-00002-of-00004.safetensors | 5,366,101,807 |
| model-00003-of-00004.safetensors | 5,364,643,286 |
| model-00004-of-00004.safetensors | 4,375,105,375 |
| Required installation, including tokenizer/template/config/index | 20,411,897,485 |
| Common text tensor payload | 1,378,869,376 |
| Routed expert tensor payload | 18,119,393,280 |
| Unused vision tensor payload | 893,142,496 |
| One complete expert bundle | 1,769,472 |

These are checkpoint byte counts, not measured live physical-memory footprints. Selected real payload comparisons against an independent reader are now exercised by the opt-in reference audit. The developer-only explicit path has since passed the accepted full-model fixture; the user-facing fused path remains unvalidated.

The measured 128-token post-instrumentation request had 42,657 expert misses. The exact accounting is `42,657 × 1,769,472 = 75,480,367,104` requested expert-payload bytes (75.480 GB decimal), which matches the reported 75.48 GB. This rules out an unexplained whole-shard read for that request; requested bytes are still not physical SSD traffic.

## 5. Storage and downloads

Downloads use the existing managed Application Support model directory and downloader. The streaming entry requests only its pinned inventory at the immutable revision, checks space, uses existing resumable per-file staging, verifies hashes, and validates all shard headers before completion. The complete 20,411,897,485-byte checkpoint is now installed and registered as `qwen3.5-35b-a3b-streaming-4bit`.

Qwen imports validate the original folder and register a security-scoped bookmark without copying 20 GB. Access is balanced through import/load/unload; stale bookmarks are renewed. External registrations survive a disconnected volume, and removal forgets their records without deleting their files. The existing sandbox/signing settings are unchanged. External-volume and sandbox behavior still require live validation.

## 6. Memory and context

Admission uses existing app memory/thermal policy, actual headroom, and Metal’s recommended working-set ceiling. The pool chooses 512 MiB, 1 GiB, or at most 2 GiB. Budget includes the pinned common payload, 64,389,120 bytes of fixed native state, 20,480 KV bytes/token, temporary allocations, and safety headroom.

Initial total context is at most 4096 tokens and may be reduced or refused by admission. Ordinary chat reserves up to 512 output tokens, respecting a lower user setting. Pool slot and byte capacities independently require room for eight experts. Physical tensor reads remain capped at four. Prefill now uses groups of at most four tokens, but each token is routed independently through the official K=8 router and the pool builds an order-preserving union of those actual bundles; there is no predicted route, reduced-K path, or predictive staged/g4 optimization.

## 7. Executed validation

- Current-workspace macOS Debug build-for-testing: passed. The focused Qwen/foundation bundle reports **65 executed, four intentional opt-in skips, zero failures** when the opt-in fixture gates are not requested. The historical target-host Q2.4 fixture comparison was run separately and failed at the first demonstrated fused-path semantic divergence; Q2.17 subsequently closed the explicit-path lifecycle gates. The normal Xcode test runner still stalls while materializing workers on this host, so these focused counts come from the same built test bundle invoked directly with `xctest`.
- Q2.3 target-side importer test: passed through the normal Xcode runner (`QwenStreamOracleFixtureTests.testPortableFixturePathRejectsTraversal`, one executed, zero failures). Debug build-for-testing and the Release build both compile the importer and diagnostic checkpoint fields. The Q2.4 live fixture comparison was then run directly with the generated target-host archive and failed the native semantic gate as described below.
- The most recent broad macOS suite remains **993 executed, 10 skipped, one failure**. The failure is the existing `SettingsStoreTests.testLegacyBeetAppearanceMigratesToDarkOnce` assertion: the current app includes `.oled`, while the test expects only system/light/dark. No appearance code or that assertion was changed for this task.
- The new bounded reference audit reads real layer-0/expert-0 gate, up, and down projections from the pinned shards and compares native quantized matmul with a dequantized dense calculation. It passed with frozen tolerances `relL2 < 0.01`, `maxAbs < 0.25`: gate `0.0014437 / 0.0009589`, up `0.0012759 / 0.0009236`, down `0.0014463 / 0.0004600`. This is a component/kernel audit, not full-model numerical parity.
- Independent short logit checks against the CPU reference passed for factual, arithmetic, English, Turkish, and code fixtures. Relative L2 values were `0.00725–0.01087`, maximum absolute drift `0.189–0.367`, and greedy top-1 IDs matched. One English top-8 tail differed only within the observed near-tied cutoff. The historical target-host Q2.4 fixture supplied the required 64-token, router, recurrent/KV, and cached-decode comparison for the fused path; that comparison failed at the first native/reference divergence. Q2.16/Q2.17 supplied the accepted independent explicit-path fixture and lifecycle evidence.
- The first-layer diagnostic isolated a reference-runtime state-precision difference rather than changing the app: Python CPU q-state output drift was `relL2 0.04909 / maxAbs 0.01172`; regenerating the independent fixture with the config-declared FP32 recurrent state reduced it to `0.02584 / 0.00507`. The Swift runtime was not changed to make this pass. The remaining cross-runtime/kernel drift is retained as a limitation.
- Release arm64 build: passed. `codesign --verify --deep --strict` passed with system trust-service access. The sandboxed check initially could not establish certificate trust; the unrestricted verification succeeded.
- The exact Downloads Release app (not the older `/Applications/Vamp Assistant.app`) passed model auto-discovery, bounded load, official K=8 activation, a 512-token fixed-prompt production run, unload, lightweight-model load, switch back to Qwen, cancellation during active generation, immediate regeneration, and relaunch with the installed Qwen model active. The UI run displayed `512 tokens · 4.6 tok/s · 2m 20s`; it is a production smoke measurement with the app's default 512-token budget, not the scored 128-token comparison. The independent Q2.4 lifecycle matrix also passed load/generate/unload, reload, and quiescence checks; numerical acceptance remains separate and failed. The earlier 32.5 s and 3.7 s turns remain single-token end-to-end observations; they are not decode tok/s.
- Unit coverage also exercises double unload/reset/cancel after a failed load, ownership cleanup, pool minimum K=8 capacity, queued cancellation, late-completion guards, and stale-path rejection. Q2.17 additionally covered cancellation during prefill, expert acquisition, and cached decode, immediate recovery, model switching, and fresh-process rediscovery. Real external-volume disappearance remains target-validation work.
- Q2.1's independent CPU long-generation attempt was interrupted by a host reboot after a macOS kernel watchdog panic. The supplied panic log reports `watchdogd` missing check-ins for 91 seconds, 28 swapfiles, and low swap space; its backtrace is in Apple's watchdog/interrupt-controller path and does not name Vampire Assistant. No long-generation fixture was written, so this run is not a parity result. The smaller independent router/state attempt was stopped with it before producing a fixture. The validation procedure now treats host reboot/low-swap conditions as an interrupted run and does not promote a partial output to an oracle.
- Q2.2 adds `scripts/qwen35-bounded-oracle.py`, a development-only one-helper-at-a-time reference path. Each stage loads the pinned `mlx-lm==0.31.1` / `mlx==0.32.2` implementation in a short-lived child, writes only a safetensors continuation cache plus bounded JSON summaries, and exits before the next stage. The parent samples child RSS, memory free percentage, swap delta, fixture bytes, free disk, and elapsed time once per second. Defaults are a 2.5 GiB child-RSS ceiling, 512 MiB per-stage swap-delta ceiling, 2 GiB fixture quota, 10 GiB disk floor, 180-second stage timeout, and one concurrent helper. The native test harness can compare the emitted prefill/decode checkpoints, K=8 IDs/scores, selected recurrent/KV state summaries, and greedy token IDs when a guarded fixture is available.
- The first guarded Q2.2 attempt used the installed artifact, one prefill plus one cached-decode budget, a stricter 2 GiB RSS ceiling, and a 120-second stage timeout. It stopped after 17.4 seconds with `RESOURCE_GUARD_ABORT`: peak child RSS was 741,900,288 bytes, system free memory was 33%, swap grew by 306,771,394 bytes from a zero baseline, free disk was 33,402,888,192 bytes, and the fixture directory was 862 bytes. No stage result or parity fixture was accepted. This demonstrates the guard is stopping the unsafe condition before a watchdog event; it does not validate or reject native model semantics.
- Q2.3 now provides `Tools/QwenOracle/qwen35_k8_oracle.py`, `requirements.lock`, and a README for an explicitly off-host independent oracle. It verifies every pinned artifact file by streaming SHA-256, renders synthetic prompts with the pinned Qwen template and Thinking Off, uses mlx-lm 0.31.1 / MLX 0.32.2 with FP32 recurrent state, runs each primary/secondary fixture twice, and refuses publication if token IDs, router IDs, positions, or stop behavior differ. The package contains only a manifest and bounded JSON snapshots for the primary 64-token fixture plus English, Turkish, arithmetic, and code fixtures; no model shards are included. The manifest records the artifact inventory identity, config/tokenizer/template hashes, oracle versions, router K=8/shared-expert contract, selected recurrent/KV layers, top-N logits, router K/K+1 margins, and Oracle Host resource observations.
- Q2.4 replaces the off-host requirement with `Tools/QwenOracle/qwen35_k8_layer_oracle.py`, a genuinely one-layer-at-a-time reference for this 16 GB M4. Its workers read only the selected layer's Safetensors ranges, exit before the next layer starts, restore full-attention offsets from sidecars, and carry the upstream recurrent state through the app's four-token prefill groups and one-token cached decode. The corrected run produced the retained compact fixture [dist/Qwen35-K8-Layer-Isolated-v3.zip](/Users/m/Downloads/beetcode/BeetCode/dist/Qwen35-K8-Layer-Isolated-v3.zip), 145,711 bytes, SHA-256 `9665fb696d78eb18a4696fe0305f88fa55f56e336948c9331a6270fc96db5650`, with a 39-token rendered prompt, 64 generated tokens, output-limit stop, and checkpoints `-1, 1, 2, 4, 8, 16, 32, 64`. The archive contains only `fixtures/primary.json`, `manifest.json`, and `README.md`; no model payloads.
- The target-side native fixture test executed against that archive and completed ten four-token prefill calls plus 64 cached decode calls, but failed the required equality gate. Native and oracle token IDs first diverged at generated-token index 5 (`native 8806`, `oracle 1870`). Router IDs/order and sampled layer/cache summaries already differed at the prefill boundary; the native layer-0/19/39 hidden summary relative L2 values were approximately `0.0066 / 0.0808 / 0.1807` there. The separate native lifecycle matrix passed load, generate, unload, reload, and quiescence checks. These results disprove full-model parity on the current native/runtime combination; they do not justify changing K, enlarging the pool, or loosening tolerances.
- `Tests/QwenStreamOracleFixtureTests.swift` is the target-side consumer. It accepts an extracted directory or ZIP through `BEETCODE_QWEN35_ORACLE_FIXTURE`, rejects traversal/symlink entries, validates the fixture identity and per-file checksum, compares exact prompt/generated IDs and stop position, checks router K=8 IDs/scores and K/K+1 margins, compares selected GatedDeltaNet/full-attention cache summaries, and asserts one bounded prefill group per four prompt tokens followed by one cached step per emitted token. The live target comparison executed against the Q2.4 archive and failed at generated-token index 5.
- The prior Q2.3 off-host handoff is retained as history. The shipped artifact remains **UNVALIDATED** because its user-facing fused strategy is not qualified; Q2.16/Q2.17 completed those semantic and lifecycle gates for the developer-only explicit strategy.
- After reboot, the direct Debug test bundle completed **1006 tests, 17 skipped, six failures**. The six are unrelated existing/host-sensitive failures: two BotComputerService persistence assertions, two Composer/CoreData-dependent assertions, the existing EndToEnd approval assertion, and the existing OLED appearance expectation. The Qwen opt-in long comparison was run separately with the target-host archive and failed at the documented first divergence; the lifecycle matrix passed. This run is reported separately from the earlier 65-test focused Qwen count and does not convert skipped parity gates into passes.
- Long-generation benchmark: fixed prompt from the implementation brief, new chat per run, Thinking Off, temperature 0 (greedy), max output 128, official K=8, one unscored warm-up followed by two scored runs. Each scored run produced 128 tokens and stopped at the output limit.

| Run | Prompt / output | Prefill | TTFT | Decode window | Decode tok/s | End-to-end tok/s | Stop |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Warm-up | 186 / 128 | 52.65 s | 53.20 s | 56.41 s | 2.25 | 1.17 | output limit |
| Scored 1 | 186 / 128 | 68.12 s | 68.13 s | 52.25 s | 2.43 | 1.06 | output limit |
| Scored 2 | 186 / 128 | 68.96 s | 68.98 s | 54.15 s | 2.35 | 1.04 | output limit |
| Scored median | 186 / 128 | 68.54 s | 68.56 s | 53.20 s | **2.39** | 1.05 | output limit |

Decode tok/s is `(128 - 1) / decode window`; prefill and TTFT are excluded. The first two scored summaries predated the total-seconds field, so their UI elapsed times were approximately 120 s and 123 s. A post-instrumentation validation run on the same prompt recorded 123.25 s end-to-end, 2.34 tok/s over 54.27 s, 68.92 s prefill, and 68.98 s TTFT.

That post-instrumentation run also recorded 75.48 GB of requested expert-range bytes, 191.20 s of aggregate range-read time across the four-read limit, 39,071 hits, 42,657 misses, 41,444 evictions, and four peak concurrent reads. Aggregate read seconds can exceed wall time because reads overlap; they are not physical SSD traffic. Its process footprint was 106.4 MB before load, 1.61 GB after load, and 4.08 GB at the end sample; MLX reported 3.53 GB active, 136.1 MB cache, and 3.65 GB peak. Thermal state, swap delta, and physical SSD traffic were unavailable.

The latest opt-in real-artifact test (`BEETCODE_QWEN35_BENCHMARK=1 BEETCODE_QWEN35_TRACE=1`) uses the same user text and Qwen K=8 but the native lean text-only envelope rendered 117 prompt tokens, so it is recorded separately from the historical 186-token app request. It produced 128 tokens at the output limit in 58.93 s total: load 2.711 s, render/tokenize 0.014 s, prefill 23.605 s, first generated token 23.608 s from request start, first visible answer 23.623 s, decode 35.311 s over 127 intervals (3.60 tok/s), finalization 0.0004 s, and unclassified remainder 0.0008 s. Its privacy-safe input hash was `e0cbcb5270cacb3081e8998d`.

For that latest instrumented run, requested/completed bytes were 58,358,956,032 / 58,358,956,032. Prefill accounted for 28,814,082,048 bytes and decode 29,544,873,984 bytes. The 32,981 misses exactly account for the completed payload (`32,981 × 1,769,472 = 58,358,956,032`); hits were 33,229, evictions 31,768, completed bundles 32,981, and peak read concurrency 4/4. Aggregate read time was 87.790 s, split 44.535 s prefill and 43.255 s decode; this is overlapping wait time, not wall time or measured physical SSD bandwidth.

The historical 186-token request is the scored baseline and remains the only basis for the 2.39 tok/s median. Its older telemetry did not retain phase-specific byte counters, so the current phase-split run is an accounting demonstration with a different rendered prompt envelope rather than a replacement for that baseline.

The separate traced run is deliberately not used to explain away the scored result. It used a different 117-token native text-only envelope and reached 3.61 tok/s decode (the earlier comparable lean run was about 3.49 tok/s), while the scored app request used 186 rendered prompt tokens and 2.39 tok/s. The trace shows substantial application-pool churn, but the prompt envelope and filesystem-cache state were not frozen across those runs, so causality is not established. The next cache experiment must reset only the application pool and use one identical rendered prompt for every cold or warm trial.

Memory for the latest run was 38.6 MB before load, 1.54 GB after load, 4.05 GB sampled process peak, and 3.99 GB end sample. MLX reported 3.53 GB active, 136.0 MB cache, and 3.65 GB peak. A separate idle post-relaunch sample showed 1.53 GB RSS. System-wide memory-pressure output showed 64% free pages at that idle point; swap was already 8.08 GB used, so a run-specific delta is unavailable and is not attributed to Qwen.

The historical fused-path comparison still failed at generated-token index 5 and remains unvalidated. Q2.16/Q2.17 closed the corresponding explicit-path generated-ID, router, state/cache, and lifecycle gates. Remaining limitations are external-volume removal, physical SSD traffic, thermal/swap deltas during scored runs, and parity-proven scheduled/g4 performance comparisons. Generic storage tests and the bounded projection audit are not full model-output parity tests. The current 1,213-slot pool and production fused path remain unchanged.

The traced 117-token run captured 66,210 `(layer, expertID)` keys across 6,280 groups with no dropped keys. Offline exact global-LRU simulation using the actual 1,769,472-byte bundle predicted:

| Pool slots | Pool payload | Simulated hit rate | Simulated misses | Simulated requested bytes |
| ---: | ---: | ---: | ---: | ---: |
| 1,213 (control) | 2,146,369,536 B / 1.999 GiB | 50.2% | 32,981 | 58,358,956,032 B |
| 1,516 (+25%) | 2,682,519,552 B / 2.498 GiB | 56.8% | 28,622 | 50,645,827,584 B |
| 1,819 (+50%) | 3,218,669,568 B / 2.998 GiB | 62.0% | 25,158 | 44,516,376,576 B |
| 2,122 (+75%) | 3,754,819,584 B / 3.497 GiB | 68.7% | 20,749 | 36,714,774,528 B |

The trace report is the source of truth for the exact simulated miss and byte totals; the abbreviated table above records the measured hit-rate decision points without claiming that a larger pool has been allocated. No larger pool, A/B block, or promotion has run because the required full-model generated-token and lifecycle gates are still open. The current approximately 2.15 GB pool therefore remains fixed.

## 8. UI and production path

> **Superseded by §9 (Q2.18).** The catalog entry is no longer labelled
> "(Experimental)" and the production attention path is now the validated
> explicit strategy, not the fused one.

The existing model library has one experimental SSD-streaming entry. Thinking is an actual template option under Settings → Agent → Experimental inference, off by default. Existing reasoning presentation consumes the emitted markers. Diagnostics report configuration, pool/read information, timing, and memory snapshots; unavailable physical SSD traffic and swap measurements are explicitly unavailable.

Because this backend is text-only and advertises no tools or project access, constrained local sessions use the existing chat-only path with a compact no-tools system prompt. This reduces prompt work without changing the selected Qwen template or the user's visible chat behavior.

The production session controller disables tool registration and rejects attachments for this entry. Ordinary text uses the same chat/session path; replay does not alter the parent transcript. A public one-button validation action has **not** been delivered; Q2.17 instead uses a developer-only explicit fixture probe and opt-in lifecycle tests against the accepted independent reference.

## 9. Host and limitations

> **Partly superseded by §9 (Q2.18).** The scored decode median below is the
> pre-Q2.18 fused-path figure; the production default is now explicit at
> 3.2469 decode tok/s median, and quantized numerical parity is no longer
> unverified for that path.

Actual host: Apple M4, Mac16,10, 17,179,869,184 bytes unified memory (16 GiB). Only the internal system volume was available. The required checkpoint is installed in the app’s managed model directory; the final post-build filesystem check reports 31,748,030,464 free bytes (about 29.6 GiB) after the current Debug/Release build and q2.3 validation ZIP. No second checkpoint, BF16 original, or repack was created. The UI admitted the model with a projected peak of 5.29 GB.

The measured scored decode median is 2.39 tok/s for this exact K=8 streamed path. It is a host observation, not a promise for other M4 systems or storage conditions. The Flash-MoE ~11.5 tok/s figure remains a separate K=6 result and is not comparable. Quantized numerical parity, thermal behavior over longer workloads, and swap delta remain unverified.

## 10. Deferred work

> **Superseded by §9 (Q2.18).** Exact-path parity has since been established
> for the explicit attention path, the lifecycle/resource matrix was rerun
> against it, and the remaining deferred item is the pool-capacity experiment
> plus a performant correctness-compatible attention kernel.

The next gate is to isolate the first native/CPU semantic mismatch using the retained Q2.4 archive and native debug trace. Required follow-up: restore exact long token/router/state/cached-decode equality, then rerun the lifecycle/resource matrix and only afterward consider the already-simulated pool-capacity experiment. Multilingual templates, thermal/resource deltas, external storage, expert-acquisition cancellation proof, complete validation action, and parity-proven scheduled/g4 comparisons remain deferred. Expert-cache capacity remains an analysis-only candidate; no larger tier has been admitted.

Staging/g4 remains deferred until exact-path parity passes. No reduced routing, pruning, predictor training, speculative decoding, or vision extension was introduced.

## 11. Build artifact

> **Superseded by §9.10 (Q2.18).** The current artifact is
> `dist/Vamp-Assistant-Qwen-Streaming-VALIDATED-build93-q2.18.zip`, SHA-256
> `1a07a7c3e316fc040404c5fbf30667a83c869b5d892cabad89cc96e82fde5af6`. The
> UNVALIDATED q2.3 ZIP below was preserved, not overwritten.

Release app: `.derived/Build/Products/Release/Vamp Assistant.app`, arm64, bundle `com.beetcode.app`, version 0.10.35/build 93. The executable is 65,090,672 bytes; the app bundle is 74,342,400 bytes on disk.

Current validation ZIP: `dist/Vamp-Assistant-Qwen-Streaming-UNVALIDATED-build93-q2.3.zip`, **20,718,580 bytes**.

Executable SHA-256: `938e8e88b4e0a529c7e27693bbbe7f0651e4c8bcf31d482d45f067b56b71c520`.

Current validation ZIP SHA-256: `8ce35c16a693a3a61913e0b116319ba4a5a0e4431755495a06b133822b8c9a45`. The sidecar is `dist/Vamp-Assistant-Qwen-Streaming-UNVALIDATED-build93-q2.3.zip.sha256`.

Signed with the existing Apple Development identity, team `438VSM6P5L`; hardened runtime retained. Not notarized. This is an explicitly unvalidated development artifact. The existing version/build DMG and prior ZIP were preserved rather than overwritten or changing release metadata.

## 12. Next user test path

> **Superseded by §9.7 (Q2.18).** The library entry is now named
> **Qwen3.5 35B A3B — SSD Streaming** and is validated against the pinned
> MLX 0.31.1 Metal explicit-attention reference rather than pending parity.

Open `.derived/Build/Products/Release/Vamp Assistant.app` → Settings → Models & Providers → Library → select **Qwen3.5 35B A3B — SSD Streaming (Experimental)** → Load → start a new text-only chat. Use Stop, then a follow-up; Thinking is under Agent settings. This exact path has been smoke-tested with the installed weights; the card remains experimental and unvalidated pending full numerical parity.

No existing BeetCode model folders or personal files were deleted. The old temporary Edge0 checkpoints were removed to make room for this pinned model; an APFS local snapshot was thinned so the reclaimed space became usable.

## Q2.5 localization update (2026-09-15)

The supplied crash report identifies the old Debug build as build 93 of
`com.beetcode.app`. Its failing stack enters MLX `mlx_multiply` through the
temporary `streamGatedDeltaOpsDiagnostic` probe at `QwenStreamModel.swift:1071`,
after the package error handler converts an MLX shape error into
`EXC_BREAKPOINT`. That function is no longer present in the current source. A
fresh build-for-testing in `.derived-q25-current-v1` contains neither that
symbol nor `Q25_USE_OPS`; the same opt-in boundary test completed the model run
and reported assertion failures instead of crashing. The report is retained as
a stale-build diagnosis and is not counted as a current runtime failure.

The corrected layer-isolated oracle fixture was regenerated with the pinned
artifact, `mlx-lm 0.31.1`, MLX 0.32.2, CPU execution, config-declared FP32
recurrent state, and the learned `linear_attn.norm.weight`. It now carries
complete bounded layer-0 `routerInput` and `routerLogits` arrays for all 39
prompt positions. The new development-only
`Tools/QwenOracle/qwen35_router_replay.py` reads those arrays and replays MLX's
own precise softmax plus `argpartition` selector; it does not read checkpoint
payloads or alter inference.

The replay result is diagnostic evidence, not a parity pass:

| Check | Result |
| --- | ---: |
| Router positions compared | 39 |
| Reference selectors matching their recorded K=8 sets | 39/39 |
| Native selectors matching their recorded K=8 sets | 39/39 |
| Cross-runtime selected-set mismatches | 2 |
| Same-set order-only differences | 6 |

The two set mismatches are both layer-0 K/K+1 boundary cases. At position 2,
the reference selects expert 72 while native selects 86; the reference logits
are `72=-3.125`, `86=-3.140625`, while native logits are `86=-3.140625`,
`72=-3.15625`. Both captured K/K+1 gaps are 0.015625. At position 7, the
reference selects 163 while native selects 30; the reference gap is 0.03125
and the native gap is 0.015625. The selector replay reproduces each side's
record exactly, so this is not a pool key, cache ordering, or selector-replay
defect. It is a small cross-runtime router-logit difference that changes an
official K=8 decision and therefore remains a correctness failure until
explained or fixed.

The fresh native boundary run completed 10 whole-model prefill calls for the
39-token prompt (nine groups of four and one group of three). A 64-token debug
run's accounting remains 10 prefill calls, 64 cached decode feeds, 63
subsequent-token emission intervals, one final-state probe, and final consumed
position 103. The native test exits with the documented parity assertions and
no crash. No larger expert pool, K change, dependency update, custom kernel,
or scheduling optimization was introduced. The backend and artifact remain
**UNVALIDATED**; the 3 GiB pool A/B is still blocked on full-model parity and
lifecycle acceptance.

### Q2.5 continuation: saved-input and first-divergence evidence

The fresh build completed the bounded raw-BF16 router replay. Its six-vector
fixture includes a control row and layer-0 positions 2 and 7 from both the
independent reference and native boundary capture. The Python replay uses the
same precise MLX softmax and `argpartition` contract, while the native test
uses Metal. Across all 39 captured prompt positions, each side reproduces its
own recorded K=8 set. A separate same-input replay agrees on selected sets and
orders, and the native quantized gate projection agrees when fed the exact
reference inputs:

| Replay check | Result |
| --- | ---: |
| Captured positions | 39 |
| Reference self-set matches | 39/39 |
| Native self-set matches | 39/39 |
| Same-input selector set/order matches | 6/6 |
| Native gate relL2 (control, p2, p7) | 0.00249 / 0.00218 / 0.00240 |
| Cross-runtime membership changes | 2 |
| Same-set order-only differences | 6 |

The two membership changes are genuine non-tied K/K+1 cases. At zero-based
layer-0 prefill position 2, reference selects expert 72 (`-3.125`) and native
selects 86 (`-3.140625`); both sides' captured boundary gap is `0.015625`.
At position 7, reference selects 163 while native selects 30; the reference
gap is `0.03125` and the native gap is `0.015625`. This localizes the saved
case to a small upstream router-input/logit difference and does not show a
selector, cache-key, or gate-projection defect. The boundary test still fails
the required set assertion at position 2 and reports layer-0 MoE output relL2
`0.1810959158`.

The independent 64-token fixture was then used in a same-prefix,
teacher-forced decode. At generated-token index 5, after prefix
`[16, 13, 19137, 344, 56127]`, reference top-1 is `1870` (logit `21.375`)
and native top-1 is `8806` (logit `22.25`). The paired logits are reference
`1870=21.375`, `8806=21.25`, and native `8806=22.25`, `1870=21.625`.
The portable native comparison reached all 64 generated tokens through 64
cached-decode calls and failed at that same first index. This is a reproducible
semantic mismatch; it is not a short-answer or old-crash artifact. No
production fix is claimed because the earliest native/reference state boundary
has not yet been isolated beyond the layer-0 router-input/logit drift.

The current fresh Debug build-for-testing passed, and the old
`streamGatedDeltaOpsDiagnostic` symbol is absent from its app and test
executables. Focused selector, gate-input, and teacher-forced instrumentation
tests executed successfully; the boundary and portable parity tests correctly
remain failing. The existing lifecycle smoke is unchanged and was not used to
promote numerical parity. No 3 GiB pool allocation, dependency change, K
change, kernel change, or second optimization family was started.

## Q2.6 activation localization

The first numerical divergence is now localized before expert selection. A
fresh independent two-group boundary was generated from the pinned artifact
with `mlx-lm 0.31.1`, MLX 0.32.2, CPU execution, and config-declared FP32
recurrent state. It retained complete BF16 values for eight zero-based prompt
positions. The fresh native diagnostic test exported a complete layer-0
boundary for the same token IDs. The `[1,4,2048]` attention inputs and the
full input-normalization rows match exactly at every position, including p0 in
the first chunk. This rules out an upstream embedding/norm mismatch and a
second-chunk carry as the first cause.

The p0 A-G measurements are:

| Operation | Shape | Reference norm | Native norm | relL2 | maxAbs | Worst coordinate |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| embedding | `[2048]` | 0.5697079 | 0.5697079 | 0 | 0 | `[0]` |
| input normalization | `[2048]` | 46.2400782 | 46.2400782 | 0 | 0 | `[0]` |
| attention output | `[2048]` | 2.1896182 | 2.1904234 | 0.0054941 | 0.0010376 | `[1307]` |
| post-attention residual | `[2048]` | 2.2915094 | 2.2921395 | 0.0054669 | 0.0010376 | `[1307]` |
| post-attention normalization / MoE input | `[2048]` | 35.6826837 | 35.6789196 | 0.0064202 | 0.03125 | `[585]` |
| router logits | `[256]` | 87.7361657 | 87.6107795 | 0.0030692 | 0.03125 | `[1]` |
| selection scores | `[8]` | 0.3618895 | 0.3606495 | 0.0083174 | 0.0019531 | `[3]` |

An offline comparison of the same saved attention input through the complete
linear-attention subpath identifies `in_proj_qkv` as the earliest nonzero
operation. At p0 both summaries are BF16 `[8192]`; reference/native norms are
`111.6734987` / `111.6656249`, relL2 `0.00464215`, maxAbs `0.0625`, and the
worst coordinate is `[5071]`. The p0 follow-on rows are `z` relL2 `0.00547677`,
`b` `0.00360141`, `a` `0.00242367`, convolution `0.00439154`, q normalization
`0.00446059`, k normalization `0.00572439`, value `0.00440104`, gated output
`0.00705106`, normalized output `0.00392334`, and final attention projection
`0.00549409`. At p2 and p7, qkv remains first with relL2 `0.00374423` and
`0.00403113` respectively (maxAbs `0.125` at both positions). The full
per-position metrics, norms, dtypes, and coordinates are produced by the
development-only `Tools/QwenOracle/qwen35_activation_compare.py` script.

The effective checkpoint geometry is verified independently: layer-0 QKV uses
affine 4-bit quantization with group size 64 (`U32 [8192,256]` weight,
BF16 `[8192,32]` scales and biases); the convolution tensor is already BF16
`[8192,4,1]`; and the index contains no MTP tensors. Native sanitization thus
does not move the convolution axis or shift norm weights. The Python
quantized projection reproduces its own boundary exactly. Native is built with
mlx-swift 0.31.6 / revision `0bb916c67f4b9e5c682cbe02a42c701c93ab5021`, while
the independent oracle is MLX 0.32.2; the cross-runtime quantized-matmul drift
is therefore a concrete version/kernel difference still requiring a semantic
decision. It is not being waved away as acceptable: the long fixture still
diverges at token 5 (`1870` versus `8806`), and Qwen remains **UNVALIDATED**.

For reproducibility, the temporary full-value reference boundary is
`69c340f355a1ca5070d8729d471a506725fdd8804bc6b8a8eb3917d269fe0148`, the
native boundary is
`74a683074aa0d0859045bf02f5e462e51fa3c38ac365d1f72939447b50ee0951`, and the
offline comparison report is
`a558c05a27ac937e53d6dbdabe7678b512e098bbec602104d667a813c45202a6`.
All three are bounded `/tmp` diagnostics; no checkpoint copy or large fixture
was committed.

The added native export is opt-in and diagnostic-only. The fresh build-for-
testing and the activation trace each executed one test with zero failures;
the trace retained only eight positions and did not load another checkpoint.
No production math, cache policy, pool size, K value, or scheduling strategy
was changed. The 3 GiB pool experiment remains paused until the long
generation, router, cached-decode, recurrent-state, attention-cache, and
lifecycle gates pass.

## Q2.6 operator replay result

The layer-0 `linear_attn.in_proj_qkv` mismatch was reduced to a compact
operator matrix using the same installed Qwen3.5-35B-A3B 4-bit artifact. The
development-only replay tool reads the indexed QKV weight, scales, and biases
by bounded ranges and stores raw bytes alongside two captured four-token
inputs/outputs. The resulting archive is `/tmp/Qwen35-K8-QKV-Operator-v2.zip`
(8,734,119 bytes, SHA-256
`061e773ac37f3b8bf59fb228d0e1a3a7cc3eaeac4a9116ba173185fe753b2d62`), with
metadata SHA-256
`c372b2cf4de15d6020c930f83f5d2fd7c17c39dabc1e0364aeb7a77ad592bf2d`.

The native XCTest compares A, the production Vampire Assistant wrapper, and
B, direct Swift MLX `quantizedMM`. Both M=4 groups and a subsequent M=1
dispatch match byte-for-byte between A and B. A/B versus the independent
reference has relL2 `0.00344288` and `0.00379739` for the M=4 groups (maxAbs
`0.25` and `0.125`) and `0.00464215` for M=1 (maxAbs `0.0625`). The test
executed one case with zero failures.

The Python legs use the identical fixture and Metal device. Python MLX
0.31.1 (C) produces the exact native hashes
`a67aae3654ef320e9cc55324830681798f2e20271e488fd53638e451775a7abc` and
`bf44c03d35b1f6c8a3096b0f918db9ece277f0f727462aa53cc5db572097bc66`.
Python MLX 0.32.2 (D) produces the exact independent-reference hashes
`8ea1396069664d51c6786c1e9a1b2e62323b2c35a1c9e29c2a020021028800a5` and
`cd3ddef548e656e1c341974be6617cda1e8b607d5d7ec8a851fc6d10e9a6e022`.
The M=1 Metal dispatch in both Python 0.31.1 and 0.32.2 follows the native
output, so the observed difference is a reproducible core/device/shape
dispatch result; assigning it to package version alone would be premature.
CPU-only runs were retained as diagnostics and are not the target runtime.

The native build provenance is verified in the linked artifact: mlx-swift
0.31.6 revision `0bb916c67f4b9e5c682cbe02a42c701c93ab5021`, MLX core commit
`ce45c52505c8158ea48d2a54e8caae05efd86bfe` (`v0.31.1`), and mlx-c commit
`0726ca922fc902c4c61ef9c27d94132be418e945` (`v0.6.0`). This rules out a
Vampire Assistant wrapper or QKV byte-range defect. It does not establish
full-model semantic parity: the independent long fixture still diverges at
generated token 5. No runtime dependency, model math, K value, expert pool,
or scheduling policy was changed, and Qwen remains **UNVALIDATED**.

## Q2.7 matched-core full-model validation

Q2.7 used the same installed `mlx-community/Qwen3.5-35B-A3B-4bit` revision
`1e20fd8d42056f870933bf98ca6211024744f7ec` and inventory identity
`0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592`. The
independent reference was a bounded, one-layer-at-a-time execution of the
upstream `mlx_lm.models.qwen3_5.DecoderLayer`, using `mlx-lm 0.31.1`, MLX
`0.31.1`, Metal, and config-declared FP32 recurrent state. The native app
links MLX core `v0.31.1` through mlx-swift 0.31.6. Both sides used the same
tokenizer/template, Thinking Off, temperature-disabled greedy sampling, K=8,
and the shared expert.

The completed compact reference package retained for native comparison is
`~/Downloads/Qwen35-K8-Matched-Core-v3.zip` (184,367 bytes, SHA-256
`a1ee403e54fdcd496482bd4af972eebef553d20160b8a721bf2f55f299d53777`). It
contains only `fixtures/primary.json`, `manifest.json`, and `README.md`; the
fixture is 1,005,853 bytes with SHA-256
`8dc884ff4e14371000c329c5f209cae4b4183dd48ba9173bbb03fdccb3d2019d` and
records all requested checkpoints. The oracle reported `FULL_GATE_COMPLETE`,
64 generated tokens, and 64 cached decode calls without copying or repacking
the checkpoint.

### Token and cached-state result

The rendered prompt has 39 token IDs. Native and independent reference
outputs are **IDENTICAL for all 64 generated token IDs**, both stop at the
output limit, and both end at consumed position 103. Native accounting is ten
bounded prefill calls, 64 cached-decode calls, 63 subsequent-token emission
intervals, and one final-state probe. Retained checkpoint steps are
`-1, 1, 2, 4, 8, 16, 32, 64`.

At those checkpoints, cache offsets and sampled full-attention KV summaries
match. GatedDeltaNet summaries stay finite and bounded; sampled layer-18
recurrent-state relL2 ranges from approximately 0.021 to 0.059, consistent
with the remaining cross-runtime numeric drift. Final-logit top-1 IDs match
at every retained checkpoint. The largest retained top-logit delta is 0.5625
at checkpoint 1, token 15.

### Routing result and first semantic mismatch

The native router trace is complete and covers 24 sampled layer/position
records. Twenty-three records retain the same K=8 membership. Six of those
have only order permutations in equal or near-equal values and are reported as
order-only diagnostics. One record changes membership:

| Field | Independent reference | Native |
| --- | --- | --- |
| Layer / absolute position | 19 / 46 | 19 / 46 |
| K=8 IDs | `[61, 33, 111, 43, 71, 226, 211, 108]` | `[245, 33, 71, 111, 43, 226, 211, 108]` |
| Boundary values | `61=-4.15625`, K+1=`-4.21875` | `61=-4.1875`, `245=-4.1875` |
| Selection consequence | expert 61 selected | expert 245 selected |

This is a real K/K+1 membership change, even though this fixture's final
greedy vocabulary token remains unchanged. The first native comparison
therefore fails the routing correctness gate; the earlier CPU ops-loop fixture
must not be used to claim parity. The strict XCTest ran the real streamed
production path and reported six failures after separating order-only cases:
one membership failure and five bounded numeric boundary failures. The native
debug dump is `/tmp/qwen35-q27-native-run-v3-classified.json` (347,974 bytes,
SHA-256 `782475871c6820d4dadac83443afea010a36409b41cd3a5c9a29fd26e6bb5758`).

The failure is localized to a near-tie router decision after the model has
accumulated small cross-runtime projection/recurrent differences; no pool key,
whole-shard read, duplicate expert load, or selector-order defect was found.
No tolerance was changed and no production math was modified. The 3 GiB pool
experiment remains blocked.

### Lifecycle and test status

The fixture-based load → generate → unload → double-unload → reload → generate
sequence passed in 26.752 seconds and ended quiescent with no active owner or
busy pool. A second run of the full parity test also printed
`reload=passed` after the first comparison. The pre-existing lifecycle test
could not run until its old Q2.1 reference path was supplied; with a compact
prompt derived from the Q2.7 fixture, its load/generate/unload/double-unload/
reload matrix passed. Cancellation during expert acquisition, cancellation
during cached decode, lightweight-model switching, relaunch discovery, and
secondary multilingual/code fixtures were not promoted by this failed parity
gate and remain follow-up validation work.

The Q2.7 fixture comparison executed one opt-in XCTest with six strict
failures; the classified rerun executed one opt-in XCTest with the same result.
The Q2.7 test build completed successfully. Existing broad results remain
separately reported: 993 tests executed, 10 skipped, and one pre-existing
OLED assertion failure in the earlier full run. No 3 GiB allocation, K change,
dependency update, scheduling optimization, or second checkpoint was made.

**Final Q2.7 status: IMPLEMENTED — FULL-MODEL VALIDATION STILL PENDING.**
The backend and release artifact remain **UNVALIDATED**. It is not the default
model and is not release-ready. The next permitted phase is to resolve the
layer-19 router membership mismatch and rerun the same fixture before any pool
capacity A/B experiment.

## Q2.8 cutoff-tie classification

Q2.8 froze the disputed router record at layer 19 / absolute position 46 using
the same 39-token Q2.7 prompt and teacher-forced generated IDs. The compact
raw fixture is
`/Users/m/Downloads/Qwen35-K8-Q2.8-cutoff-tie.json` (234,566 bytes, SHA-256
`6aee48b0b7516cee63e9447c4257c49f2045f82070bfd39ec9e59767d728d1c6`). It
contains the full BF16 router input, router logits, selector scores, selected
IDs, and raw 16-bit words for both sides; it contains no model data. The
analysis report is
`/Users/m/Downloads/Qwen35-K8-Q2.8-tie-report.json` (file SHA-256
`35534d14736533554c35421e345c1fc0f75f93179572e12b0b692cd68ea22980`; its
embedded canonical-content digest is
`ca06e55282e12ce43cca1d3e51546f0388e653aa1e2e0f82f53dbded108942cb`).

The pinned independent implementation is `mlx-lm 0.31.1`,
`qwen3_next.py` lines 334–343: precise softmax, `argpartition(gates,
kth=-k)[..., -k:]`, `take_along_axis`, and optional score normalization. The
source file SHA-256 is
`997c3aee5cfad64c58a628bf93f5560ec549d2666070439e6db8e06fcb84b838`. The
native app uses MLX core v0.31.1 through mlx-swift 0.31.6; neither dependency
was changed.

The exact selection-dtype results are:

| Side | Expert 61 score / raw word | Expert 245 score / raw word | Difference | Exact cutoff class |
| --- | ---: | ---: | ---: | --- |
| Reference | `0.01531982421875` / `0x3c7b` | `0.01434326171875` / `0x3c6b` | `0.0009765625` | `{61}` |
| Native | `0.0147705078125` / `0x3c72` | `0.0147705078125` / `0x3c72` | `0` | `{61, 245}` |

Around the cutoff, the reference ranks 6–11 as
`111:0.017333984375`, `33:0.0162353515625`, `61:0.01531982421875`,
`3:0.01434326171875`, `245:0.01434326171875`, and
`146:0.0126953125`. The native ranks are
`111:0.0172119140625`, `33:0.0167236328125`, `61:0.0147705078125`,
`245:0.0147705078125`, `3:0.01385498046875`, and
`146:0.01263427734375`. The full 256-element arrays and raw words remain in
the compact fixture.

Both sides have the same seven strictly greater IDs:
`{33, 43, 71, 108, 111, 211, 226}`, leaving one routing slot. The reference
selected 61; the native selector selected 245. The reference gate logits are
`61=-4.15625` (`0xc085`) and `245=-4.21875` (`0xc087`); the native logits are
`61=-4.1875` and `245=-4.1875` (`0xc086` for both). Thus the native side has
an exact BF16 tie, but the reference side is non-tied at the same authoritative
selector boundary. This fails the required exact-tie equivalence conditions;
it is not justified to relax the router harness or add a tie breaker.

The Python MLX selector replay and the direct Swift MLX replay each ran 16
times. Each was deterministic for this input (one unique order and one unique
set) and reproduced its captured side. That demonstrates the observed
`argpartition` behavior without treating its partition order as a portable
contract. The native XCTest is
`QwenStreamQ28TieTests.testOptInQ28CutoffTieSelectorReplay`; it executed one
case with zero failures and logged the same classes and raw words.

The raw router inputs themselves differ by relL2 `0.0514780581` and maxAbs
`0.18359375`; the resulting router-logit relL2 is `0.004495983` with maxAbs
`0.0625`. This localizes the difference to accumulated upstream
cross-runtime numeric drift reaching the router, rather than a pool key,
expert-load, or selector-index defect. A bounded layer-19 expert probe on the
same native MoE input measured expert 61 norm `0.8881150`, expert 245 norm
`1.5147320`, relL2 `1.9368071`, and maxAbs `0.1450195`. Using each side's
actual eight normalized scores, the reference-style versus native-style routed
aggregates differ by relL2 `0.2043427` / maxAbs `0.0141349`; including the
identical shared branch gives MoE relL2 `0.2002655` / maxAbs `0.0141349`.
With a common post-attention residual, that MoE delta would also be the layer
residual delta. No full downstream rerun was started after the non-tie was
proven, and no production route was changed.

The Q2.7 long fixture remains 64/64 greedy token IDs identical, with identical
stop reason, final position 103, cached-decode accounting, and sampled
attention-cache offsets. Those results do not override the Q2.8 router gate:
the one sampled membership mismatch is a true semantic failure under the
current cross-runtime contract. The larger expert pool, K changes, tie
epsilon/sorting, dependency updates, and other performance work remain
deferred.

**Final Q2.8 status: IMPLEMENTED — TRUE ROUTER PARITY FAILURE REMAINS: layer 19 / position 46.** The backend and artifact remain **UNVALIDATED** and are not the default or release-ready model.

## Q2.9 first-operation localization

Q2.9 preserved the Q2.8 cutoff fixture and added the compact teacher-forced
router-input fixture
`/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json` (471,091 bytes,
SHA-256 `0386926d2fa71a3880d577244bc1d59f5ba45a851911ad516de96bf108c39cfd`).
Both executions use the same prompt token IDs, generated prefix, absolute
position 46, and cached-decode boundary. The all-layer capture and independent
MLX boundary run show that the first material prefill drift is earlier than
the layer-19 router: layer 7, prefill group 6, positions 24–27.

The focused layer-7 capture has bit-identical attention input, Q/K/V
projections, query gate, normalized/rotated queries, current K/V values, and
incoming full-attention cache. The first differing operation is the attention
primitive itself:

| Layer 7 group 6 component | relL2 | maxAbs |
| --- | ---: | ---: |
| `attentionValues` | `7.56919188708802e-05` | `0.00390625` |
| `gatedValues` | `1.904881484449258e-05` | `0.000030517578125` |
| `attentionOutput` | `0.00031510645094774795` | `0.0001220703125` |

The native and reference K/V cache inputs agree at that boundary. Replaying
with an explicit causal mask gives the same numbers as the symbolic causal
mask, ruling out mask representation. The production call is
`attentionWithCacheUpdate` in
`Core/Inference/QwenStreaming/QwenStreamModel.swift:547`; the diagnostic
decomposition follows it at line 500.

The opt-in XCTest replay used compact focused captures: reference
3,119,722 bytes, SHA-256
`b98d5e2a3cec016a7d7543187c9b14a5d387ccf85bc4e2f375d5d013ed62abf2`; native
2,959,704 bytes, SHA-256
`947ce573bddf853c3022f17a13a9fc73074b9c1400430a4f84ebe1daedf65902`.
For `Q=[1,16,4,256]`, `K/V=[1,2,28,256]`, head dimension 256, and GQA
factor 8, the native Swift `MLXFast.scaledDotProductAttention` output is
byte-identical to the production capture (`fastVsNativeRelL2=0`) but differs
from the independent Python MLX result by relL2
`7.569186011012955e-05`, maxAbs `0.00390625`. Python MLX's fast attention
reproduces the independent oracle exactly. The ordinary Swift MLX expression
matches the independent regular-operation calculation at relL2
`7.584503077329163e-05`, maxAbs `0.00390625`, and is close to the fused output
(`unfusedVsNativeRelL2=4.817775060418114e-06`), but it is not an exact oracle
replacement.

The checked-out MLX core selects its Metal vector SDPA path for this shape:
query length 4, key length 28, head dimension 256, and
`queryLength × GQA = 4 × 8 = 32`. This is the compiled-kernel boundary in
`backend/metal/scaled_dot_product_attention.cpp`. The evidence therefore
classifies the first discrepancy as native fused SDPA kernel/runtime numerical
drift. It is not a router-selector defect, an input/cache mismatch, a mask
bug, an expert-pool problem, or a changed Qwen model contract.

No production attention implementation, dependency, K value, pool size, or
scheduling policy was changed. The regular-operation sequence was not promoted
as a fix because it still differs from the independent oracle and its
downstream routing effect has not been demonstrated. The focused diagnostic
XCTest executed one case with zero failures and the test build passed. The
64-token free-running parity result, router membership gate, lifecycle status,
and release qualification are unchanged: the backend remains **UNVALIDATED**,
and the 3 GiB pool experiment remains paused.

**Final Q2.9 status: IMPLEMENTED — FIRST SEMANTIC DIVERGENCE REMAINS: layer 7 / prefill group 6 / native fused SDPA vector kernel.**

## Q2.10 SDPA contract replay (2026-09-16)

Q2.10 froze the Q2.9 layer-7/group-6 boundary and recorded the actual native
SDPA call without changing production attention. The installed artifact is
`mlx-community/Qwen3.5-35B-A3B-4bit`, revision
`1e20fd8d42056f870933bf98ca6211024744f7ec`, inventory SHA-256
`0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592`.
The independent reference remains Python `mlx-lm 0.31.1` / MLX `0.31.1`,
Metal, with the config-declared FP32 recurrent state. Native uses mlx-swift
0.31.6 (revision `0bb916c67f4b9e5c682cbe02a42c701c93ab5021`) and MLX core
v0.31.1 (revision `ce45c52505c8158ea48d2a54e8caae05efd86bfe`). Both sides
use the same quantized files, tokenizer/template, shared expert, and official
K=8 contract.

The compact raw fixtures are retained outside the repository:

* `/Users/m/Downloads/Qwen35-K8-Q2.10-SDPA-native-focused.json`, 593,245
  bytes, SHA-256
  `20806a9c169d33a49d4ab2136f7f829dd824ab35de60f7a277d3b707e9155348`.
* `/Users/m/Downloads/Qwen35-K8-Q2.10-SDPA-reference-focused.json`, 394,375
  bytes, SHA-256
  `8373c3158c8cbeb23774a49a343a3a6e99bde195f963caedd9314c12a8895aa8`.
* `/Users/m/Downloads/Qwen35-K8-Q2.10-SDPA-replay-report.json`, 10,060
  bytes, SHA-256
  `37c6533a0f0a594e3c341c7e0158160c09062a2324dfb76d0a4d415c9e877ee8`.

The captured boundary is Q `[1,16,4,256]`, current K/V `[1,2,4,256]`,
cached K/V `[1,2,28,256]`, and raw output `[1,16,4,256]`, all BF16 with
two-byte elements. Native metadata records Q strides
`[16384,1024,256,1]` and current-K strides `[2048,1024,256,1]` as
contiguous; current-V is the strided view `[2048,256,512,1]`. The cache
views use `[131072,65536,256,1]` for both K and V. The call uses scale
`0.0625`, exact Float32 bits `0x3d800000`, and symbolic `causal` masking on
the GPU stream. A native explicit Boolean mask has shape `[4,28]`.
Swift's public MLX API does not expose a byte offset, so the fixture records
that field as unavailable rather than inferring it. Python's public MLX API
does not expose strides/device/stream metadata; its cache-slice construction
was tested separately.

The independent replay matrix is:

| Leg | Result at the frozen boundary |
| --- | --- |
| A. production native fused vs direct Swift fused replay | exact BF16 equality; relL2 0, maxAbs 0 |
| B. Python `mx.fast` with symbolic causal mask vs independent reference | exact BF16 equality; relL2 0, maxAbs 0 |
| C. Python `mx.fast` with explicit Boolean causal mask vs reference | exact BF16 equality; relL2 0, maxAbs 0 |
| Native symbolic vs native explicit mask | exact BF16 equality; output SHA `52ee0c82dd91af169be3a1f3aa2f5bd2c8fcbea75ff42b6aaf534dc68d35902e` |
| D. contiguous Q/K/V, native-V-view reconstruction, and KVCache slice views | all equal to Python fast output; no change in relL2 or maxAbs |
| E. explicit Float32 QK / precise softmax / BF16 output | relL2 `7.584503077329163e-05`, maxAbs `0.00390625` vs oracle; relL2 `4.817775060418114e-06` vs native fused |

The exact Float32 scale and the ordinary Python scalar spelling also produce
identical BF16 output. The explicit native mask capture reports an empty mode
plus a `[4,28]` Boolean mask, while the symbolic capture reports `causal`;
their output hashes are identical.

The native fused output differs from the independent Python/oracle output by
relL2 `7.56919188708802e-05` and maxAbs `0.00390625`. A Float64 CPU
diagnostic over the first two heads differs from the BF16 GPU result by relL2
`0.0016148066711777229`, maxAbs `0.00507321812123207`; this is a rounding
diagnostic and does not identify a different model input. The pinned MLX
source selects the Metal vector SDPA path here because query length is 4,
key length is 28, head dimension is 256, and `4 × 8 = 32` satisfies the
vector limit (`scaled_dot_product_attention.cpp:631–636`). This explains why
the same quantized inputs can follow different compiled-kernel paths.

The production call remains `attentionWithCacheUpdate` at
`Core/Inference/QwenStreaming/QwenStreamModel.swift:576`; the diagnostic call
that records this contract is at line 515.

The new opt-in metadata XCTest and the existing native replay XCTest each
executed one case with zero failures; the explicit-mask capture also executed
one case with zero failures. The build-for-testing completed successfully.
No router, K value, dependency, cache size, scheduling policy, or production
attention path was changed. No 3 GiB pool allocation or A/B run was started.
The first semantic divergence therefore remains layer 7, prefill group 6,
native fused SDPA vector execution. Long-generation/router/state/lifecycle
gates remain open and Qwen remains **UNVALIDATED**.

**Q2.10 result: IMPLEMENTED — FIRST SEMANTIC DIVERGENCE REMAINS: layer 7 / prefill group 6 / native fused SDPA vector kernel.**

## Q2.11 explicit SDPA candidate (2026-09-16)

The Q2.11 diagnostic seam adds exactly one non-production strategy:
`referenceCompatibleExplicit`. It is selectable only by the opt-in XCTest;
the normal Qwen call continues to use the existing fused attention path.
The candidate is ordinary MLX code and follows the pinned Python expression:
GQA `repeat` on axis 1, Float32 Q/K/V, scale Q before QK matmul, Boolean
`[4,28]` mask aligned to absolute positions 24–27, finite-minimum masked
values, precise Float32 softmax, Float32 P×V, and BF16 output.

Independent fixture: `/Users/m/Downloads/Qwen35-K8-Q2.11-Python-explicit-intermediates.json`
(1,738,727 bytes, SHA-256
`7738f43288eb1f44d87a05c4c31f41c2915a9c96e0609bdc44c7d70634f2f8a2`). Swift
export: `/Users/m/Downloads/Qwen35-K8-Q2.11-Swift-explicit-intermediates.json`
(6,123,435 bytes, SHA-256
`472603f7de40eef47a3523fdef728b181ca278db1d094e357d67c6b4713d99b6`). The
fixtures are compact and reference the existing Q2.10 raw tensors; no model
or repack was created.

All eight candidate stages were bit-identical to Python: expanded K, expanded
V, raw QK, scaled scores, masked scores, probabilities, Float32 P×V, and the
BF16 primitive output. This localizes no mismatch within the explicit
ordinary-MLX sequence. Compared in the production presentation layout, the
candidate still differs from the independent fused/oracle output:

| Comparison | relL2 | maxAbs | candidate SHA | oracle SHA |
| --- | ---: | ---: | --- | --- |
| explicit candidate vs independent attention output | `7.584503077329163e-05` | `0.00390625` | `4d539b2844e99f029b1bd3caa18201d081293ba99fcee7ccf049712c449b14e6` | `8793209f20f95348940a167621467d34ec05ac3804e2ac4544fa9e0635d4e904` |

Because the explicit candidate does not match the independent oracle output,
the conditional full layer-7 candidate and downstream layer-19 router run was
not performed. This preserves the requirement to avoid promoting a known
different computation. The opt-in XCTest executed one case with zero
failures, and the updated build-for-testing passed; the earlier environment-
free invocation was skipped before the fixture was supplied. No production
attention, routing, pool, dependency, or benchmark setting changed. Qwen
remains **UNVALIDATED**, and no 3 GiB pool experiment was started.

**Q2.11 result: IMPLEMENTED — PRIMITIVE DIVERGENCE REMAINS: native fused SDPA versus the exact ordinary-MLX explicit candidate at layer 7 / prefill group 6.**

## Q2.12 model-level SDPA provenance (2026-09-16)

Q2.12 answered the remaining provenance question before any new scheduling or
cache experiment. The explicit ordinary-MLX candidate is now reachable only
through the diagnostic model seam. The normal Qwen `callAsFunction` remains
on fused `attentionWithCacheUpdate`; no user-selectable alternate attention
strategy was added. In the opt-in run the candidate was selected exactly once
for layer 7, prefill group 6, while 13 other full-attention diagnostic calls
used the fused path. The same real `KVCache` was updated once before explicit
attention. No layer-19/64-token run or pool/performance experiment was run.

The retained compact report is
`Tests/Fixtures/Qwen35-K8-Q2.12-boundary-report.json` and
`/Users/m/Downloads/Qwen35-K8-Q2.12-boundary-report.json` (6,993 bytes).
Its provenance is:

* Q2.11 Python explicit-intermediate fixture SHA-256
  `7738f43288eb1f44d87a05c4c31f41c2915a9c96e0609bdc44c7d70634f2f8a2`.
* Q2.10 focused independent boundary SHA-256
  `b98d5e2a3cec016a7d7543187c9b14a5d387ccf85bc4e2f375d5d013ed62abf2`.
* Q2.9 history/input fixture SHA-256
  `0386926d2fa71a3880d577244bc1d59f5ba45a851911ad516de96bf108c39cfd`.

The diagnostic reports the actual attention order as T0 through T14:

| Boundary | Value at this model seam |
| --- | --- |
| T0 | Q after q-norm and RoPE |
| T1 | current K after k-norm and RoPE |
| T2 | current V entering attention |
| T3 | QKᵀ |
| T4 | scaled scores, with scale applied before matmul |
| T5 | Boolean-masked scores |
| T6 | precise softmax probabilities |
| T7 | P×V weighted output and BF16 helper result |
| T8 | raw SDPA result returned by the attention helper |
| T9 | transpose/reshape/head merge (`attentionValues`) |
| T10 | output-gate input/result (`gate` and `gatedValues`) |
| T11 | `o_proj` input (`gatedValues`) |
| T12 | `o_proj` output (`attentionOutput`) |
| T13 | residual-added attention result (`postAttentionResidual`) |
| T14 | post-attention normalization/MoE input (`postAttentionInput`) |

All eight Q2.11 candidate intermediates matched their independent Python
ordinary-operation fixture exactly: expanded K, expanded V, raw QK, scaled
scores, masked scores, probabilities, Float32 P×V, and BF16 output. In the
real model call, T0/T1/T2 and the complete cached K/V operands were also
bit-identical to the independent Q2.10 boundary. The explicit Boolean mask
was `[4,28]`, aligned to positions 24–27.

The old Q2.11 number was not a comparison of the Python intermediate package
with itself. It compared
`trace.output.transposed(0,2,1,3).reshaped([1,4,4096])` in
`Tests/QwenStreamQ29LocalizationTests.swift` against
`fullAttention.attentionValues` from the independent focused source
`/tmp/qwen35-k8-q29-sdpa-reference-focused.json`. The candidate checksum was
`4d539b2844e99f029b1bd3caa18201d081293ba99fcee7ccf049712c449b14e6`; the
source checksum was
`8793209f20f95348940a167621467d34ec05ac3804e2ac4544fa9e0635d4e904`.
Q2.12 inverse-transformed the same source T9 tensor to compare raw T7 and
found the first full-model comparable mismatch at T7: relL2
`7.584503077329163e-05`, maxAbs `0.00390625`. T8–T14 are intentionally not
promoted past that first mismatch.

The model-level sentinel pass supplied `1.0` only to the DEBUG diagnostic
seam. The helper trace remained unchanged, and the downstream model
`attentionValues` matched the expected sentinelled tensor bit-for-bit. This
is the data-flow proof that the explicit candidate reaches the actual model
path; production generation never supplies the sentinel.

`testOptInQ212ExplicitModelDataflowAndBoundaryProvenance` executed one case
with zero failures through the application-hosted manifest. Build-for-testing
passed, and `git diff --check` reported no whitespace errors in the changed
Qwen files. The backend remains **UNVALIDATED**, with long-token,
router/state, and lifecycle validation still pending. The 3 GiB pool remains
unallocated and the current 1,213-slot pool is unchanged.

**Q2.12 result: IMPLEMENTED — FIRST REMAINING DIVERGENCE: T7 P×V/SDPA boundary.**

## Q2.13 reference provenance reconciliation (2026-09-16)

This phase reconciled the existing Q2.11 explicit-intermediate package with
the Q2.10 focused model-boundary package. It read compact fixtures and the raw
boundary source only; no checkpoint copy or repack was made. REFERENCE-A was
produced by `/tmp/qwen35_q211_generate_intermediates.py` with ordinary MLX
operations. REFERENCE-B was produced by
`Tools/QwenOracle/qwen35_k8_layer_oracle.py::_layer_call_components`, whose
full-attention branch calls the pinned
`mlx_lm.models.base.scaled_dot_product_attention` helper and captures
`attentionValues` after transpose/reshape.

The two lineages have exact byte identity for Q, current K, current V, cached
K, and cached V. The compact B fixture is also exact against its raw boundary
source. Metadata agrees: artifact revision
`1e20fd8d42056f870933bf98ca6211024744f7ec`, layer 7, prefill group 6,
absolute query positions 24–27, cache 24→28, GQA repeat 8, scale 0.0625
(`0x3d800000`), and the same `[4,28]` Boolean mask. This rules out a shard,
slice, state, position, or input-provenance mismatch.

The saved-output difference is an operation-boundary difference. A saves
ordinary explicit P×V (T7) and the BF16 helper result; B saves the fused SDPA
result at the wrapper's T8/T9 presentation boundary. In one fresh pinned MLX
0.31.1 process, both input sets recompute to the same explicit T7 BF16 and T9
words. The historical saved T9 comparison remains recorded at relL2
`7.584503077329163e-05`, maxAbs `0.00390625`; it is a valid
explicit-versus-fused kernel comparison, not a reference-input disagreement.

The provenance report is
`Tests/Fixtures/Qwen35-K8-Q2.13-reference-provenance-report.json` (15,660
bytes; SHA-256
`b478112ce799d34cf79bcf53050218e1f910fad3e0771788deb608dfe5da6a6b`). The
authoritative explicit fixture used by the native test is
`Tests/Fixtures/Qwen35-K8-Q2.13-authoritative-explicit-reference.json` (479,384
bytes; SHA-256
`2538cb6b64da12e89af7873538b8c86bc51789c72dd8b09fc44246a8899f8899`). The
report records inventory SHA
`0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592`, Python
3.12.14, MLX 0.31.1, Metal, and the full input/producer lineage.

`testOptInQ213ReferenceProvenanceReconciliation` ran through the
application-hosted test manifest: 1 executed, 0 failures, 16.864 seconds.
The real native seam used explicit attention once for layer 7/group 6 and
left 13 diagnostic calls fused; native T7-F32, T7, T8, and T9 all matched the
corrected fixture exactly. The optional native report is
`/Users/m/Downloads/Qwen35-K8-Q2.13-native-comparison.json` (2,074 bytes; SHA
`fa3a4985d8be2df43958e1cbc84500b518bba4fee5e8534837c8a4e11e57238f`).
Build-for-testing passed. One compile-only issue was fixed by using Swift's
`String(describing:)` for the token-ID hash, matching the Python producer's
privacy-safe identity.

Q2.13 does not establish full-model token parity, cached-decode/state parity,
or the lifecycle matrix. No layer-19/64-token run, pool experiment,
performance run, or release build was started. Production attention remains
fused, the current pool and model files are unchanged, and Vampire Assistant
remains **UNVALIDATED**.

**Q2.13 result: REFERENCE PROVENANCE FIXED — EXPLICIT SWIFT MATCHES AUTHORITATIVE REFERENCE.**

## 5. Q2.14 explicit full-attention candidate (2026-09-16)

Q2.14 adds a developer-only `referenceCompatibleExplicit` strategy to the
real native Qwen model path. The production default remains fused attention;
the candidate is reachable only from the opt-in diagnostic coverage test. It
uses the Q2.13 ordinary-MLX-compatible operation order and leaves all
GatedDeltaNet layers unchanged.

The full-attention indices are derived from the installed configuration:
`[3, 7, 11, 15, 19, 23, 27, 31, 35, 39]`. The native coverage run made
seven four-token prefill calls and one cached decode call. It recorded 80
explicit full-attention invocations and zero fused invocations, generated
token `3010`, and ended at consumed position 29. The report is
`/Users/m/Downloads/Qwen35-K8-Q2.14-explicit-candidate-coverage.json` (542
bytes, SHA-256
`3795f81e4913944cb83b95b289eae3ab4616f78af50eaaa3444637f543e83696`). The
opt-in XCTest executed one case with zero failures in 12.701 seconds.
Build-for-testing passed.

The independent Python layer oracle accepts `--attention-strategy explicit`
and writes the explicit contract, actual full-attention indices, and decode
semantics into its plan/fixture metadata. Real Metal workers for layers 3 and
7 completed independently under the one-layer resource guard at about 724 MB
peak RSS. A guarded full explicit one-token attempt did not publish a fixture:
it stopped at the configured free-disk floor of 3.75 GiB when the last sample
was 3.72 GiB. That worker peaked at 689 MB RSS, memory free was 44%, and swap
delta was zero. The partial scratch output was removed. This is a resource
guard boundary, not a parity result.

Therefore Q2.14 does not yet establish full-model token parity, router
selection/order, recurrent or KV-state progression, qLen-1/qLen-4 behavior,
layer-19/39 snapshots, cached decode, cancellation, or the lifecycle matrix.
No production attention change, pool allocation, dependency change, model
copy, performance run, or release build was made. The official K=8 contract,
shared expert, installed artifact, current 1,213-slot pool, and fused
production path remain unchanged. Vampire Assistant remains **UNVALIDATED**;
the 3 GiB pool experiment remains paused.

**Q2.14 result: IMPLEMENTED — EXPLICIT FULL-ATTENTION CANDIDATE WIRED; FULL-MODEL VALIDATION STILL PENDING.**

## 5. Q2.15 rolling disk-bounded explicit oracle (2026-09-16)

Q2.14's `3,758,096,384`-byte value was an explicit free-disk admission
floor. There was no component ledger, so it is not evidence of cumulative
bytes written or simultaneous occupancy. Q2.15 preserves that value as
historical context and adds a config-derived peak estimator with these
separate categories: committed continuation, one whole-boundary replacement,
compact diagnostics, temporary worker output, atomic-write duplicate,
fixture/metadata, build-log overhead, and safety reserve.

The coordinator uses exactly one committed `state-current` continuation and
one `state-next` replacement. Every Safetensors/JSON write is completed at a
temporary path and atomically renamed. Layer workers leave the committed
directory untouched; after all 40 layer caches and the final hidden tensor are
ready, the coordinator swaps the replacement directory at one boundary and
then clears the old directory. After a worker result is committed its stage
directory is removed, so historical stage outputs do not accumulate. Only
bounded layer-result/checkpoint/run metadata remains. A fresh invocation
refuses to overwrite existing state; `--resume` is explicit and accepts only a
matching continuation at `prefill-boundary`, `prefill-head`, or
`decode-ready`, with all 40 layer caches and the current hidden state present.
A mid-layer interruption is rejected rather than silently treating a partial
state as committed.

For the installed revision `1e20fd8d42056f870933bf98ca6211024744f7ec`, the
39-token synthetic prompt, and a 64-token output reservation, the corrected
whole-boundary rolling estimator reported:

| Plan item | Bytes |
| --- | ---: |
| Estimated simultaneous working output | 153,280,512 |
| Safety reserve | 536,870,912 |
| Required free disk | 690,151,424 |
| Free disk at preflight | 4,872,507,392 |

Admission was true at the historical preflight check. The earlier
`626,688,512`-byte figure used a single-layer replacement estimate; the
corrected plan accounts for the full replacement continuation held during the
directory swap. A pre-fix one-token rolling smoke completed with a
`67,371,347`-byte observed additional-output peak. It is retained only as
storage evidence because a later dispatch audit found that its
non-diagnostic worker used the fused default. Its output was `FULL_GATE_SHORT`
(one generated token), so the 48,325-byte archive and 65.6 MB rolling state
directory were classified as disposable smoke artifacts and deleted after
saving the compact record
`/Users/m/Downloads/Qwen35-K8-Q2.15-rolling-storage-smoke.json`. No model,
user file, or checkpoint copy was touched. A post-fix rolling attempt was
stopped at the committed prefill boundary `group=9, layer=9, position=39`
while correcting the output-limit decode boundary; no post-fix fixture was
published. A separate short synthetic post-fix rolling smoke reached the
explicit head and finalization with one generated token and zero cached decode
calls (`FULL_GATE_SHORT`), confirming the corrected N-versus-N−1 boundary;
its 25,403-byte archive was discarded after recording the result. It is not a
full parity fixture. After the transactional whole-boundary change, a real
explicit coordinator smoke was stopped after committing prefill group 1 at
position 8 while the next group was partial: `state-current` held 64,727,697
bytes and `state-next` held 6,472,637 bytes. No head or archive was published;
the temporary state was deleted after being recorded in the compact storage
record (format-v2 SHA-256
`e9e14dea3a82d89af5ef7149b7d7a76c06f218bc7a374672c4859a8afa6d9b07`).

The primary explicit rolling run passed its preflight and advanced through the
39-token prompt and 40 cached decode-state boundaries. The next decode reached
layer 39 before its head/coordinator boundary, so it was stopped to avoid an
unattended hours-long isolated-worker run. The captured run-state contained 41
generated IDs and 40 completed cached decode calls; the system free-memory
sample remained 54% and no resource-guard abort occurred. No archive was
published. Its 67,075,040-byte rolling state was classified as task-generated
disposable output and removed after the bounded progress was recorded. This
demonstrates bounded execution and resumable metadata, but it does not satisfy
the required 64-token independent reference gate.

The worker dispatch was corrected so `--attention-strategy explicit` reaches
the ordinary `_layer_call` path even when component capture is disabled. A
focused direct non-component Metal run of full-attention layer 3 reported
`explicit ordinary MLX attention`. The rolling-only
estimate mode also no longer inherits the legacy 10 GiB non-full-mode default;
only an explicitly supplied floor is honored.

Validation evidence in this phase is limited to five dependency-free storage/
resume tests, Python compilation, the oracle self-test, the 64-token disk
preflight, and the pre-fix one-token rolling storage smoke. The coordinator
now stops cached decode at `len(generated) == max_output`, so an output budget
of N uses at most N-1 subsequent decode calls; this boundary fix has been
compile- and unit-tested but not yet exercised by a completed post-fix full
multi-token run. The independent full explicit
multi-token fixture and native comparison have not run, so full-model parity,
cached-decode/state parity, lifecycle promotion, and release qualification
remain open. The model, official K=8 contract, current 1,213-slot pool, and
production fused attention path are unchanged. Vampire Assistant remains
**UNVALIDATED**; no 3 GiB pool experiment or performance optimization was
started.

**Q2.15 result: IMPLEMENTED — ROLLING DISK-BOUNDED ORACLE WIRED; FULL EXPLICIT VALIDATION STILL PENDING.**

## 6. Q2.16 resume verification (2026-09-16)

Q2.16 requires resuming the committed 41-ID/40-call independent state. That
state is absent: Q2.15 classified and deleted the partial
`/tmp/qwen35-k8-q215-primary-explicit-v5` directory after saving compact
evidence. There is no `state-current/continuation-manifest.json`, hidden
tensor, or complete set of 40 committed layer caches to validate. The compact
ID list and summaries are diagnostic evidence only and cannot reconstruct the
stateful continuation.

The rolling coordinator now fails closed when `--resume` is requested without
a committed continuation, with the error
`--resume requested but state-current/continuation-manifest.json is missing`.
The five-test storage/resume suite covers this guard. No new oracle work,
native comparison, fixture publication, lifecycle run, release build, or pool
experiment was started. The compact record is
`/Users/m/Downloads/Qwen35-K8-Q2.15-rolling-storage-smoke.json` (SHA-256
`5c2245d65362fd89d5acffa78143246058d31773483f2972ccea98712dbbb2f8`).

**Q2.16 result: BLOCKED — MISSING COMMITTED EXPLICIT ORACLE CONTINUATION STATE.**

## 7. Q2.16 fresh explicit reference and native comparison (2026-09-16)

The committed Q2.15 continuation was absent, so the fail-closed resume guard
was preserved and a fresh reference was generated. The independent oracle ran
the installed quantized artifact with `mlx-lm 0.31.1`, MLX `0.31.1`, Metal,
and FP32 recurrent state. Artifact revision and inventory identity matched
the app's pinned manifest.

The published compact fixture is
`/Users/m/Downloads/Qwen35-K8-Explicit-Attention-Reference-v2.zip`, 162,067
bytes, SHA-256
`cfc30f62bfe1352bb1ba5586949c908ae27e55cd0cd12ee518d0d038065eb66a`. It
contains only the manifest, README, and compact primary fixture. The 39-token
prompt produced 64 generated IDs with `output_limit` and 63 ordinary cached
decode calls. The fixture deliberately has no post-final-token probe; its
final position `103` follows the inclusive consumed-position convention, and
the last ordinary cache boundary is `102`.

The rolling plan estimated 153,280,512 bytes of simultaneous working output
and required 690,151,424 bytes including reserve. The run's peak additional
output was 133,973,141 bytes. The bounded retained disk samples reached
6,065,115,136 bytes free; a later instantaneous minimum was not retained by
the 256-entry bounded history. The worker resource guard passed with one
layer worker at a time.

The native fixture test executed against the target Debug app bundle and
passed in 33.727 seconds. The generated token IDs were identical (64/64),
and stop, prompt, position, and 63-call accounting matched. Explicit
attention counters recorded 730 calls and zero fused calls: each of the ten
config-derived full-attention layers received 10 prefill invocations and 63
qLen=1 cached invocations. Every full-attention KV cache was compared at all
retained boundaries, together with early/middle/late GatedDeltaNet cache
sentinels; all predetermined shape, offset, relL2, and maxAbs checks passed.
All compact router records matched with zero true membership failures.

The independent layer-19/position-46 raw router capture also matched the
native raw diagnostic exactly. Expert 61 was `-4.125`, expert 245 was
`-4.21875`, and the selected K=8 IDs were
`[61, 33, 71, 111, 43, 226, 211, 108]`. The historical fused-reference
cutoff values were not substituted.

The opt-in reload check passed in 67.666 seconds across load, generation,
quiescence, double unload, reload, and a second 64-token generation; the
pool was idle and active reads were zero at the boundary. App-level
cancellation by phase, switching to an installed lightweight model, and
quit/relaunch rediscovery were not run here. These missing lifecycle gates
keep the backend and artifact **UNVALIDATED**.

The focused Q2.15 storage suite executed six tests with zero failures, and the
focused Qwen XCTest classes executed 58 tests with 23 intentional skips and
zero failures; the macOS build-for-testing passed. A normal `xcodebuild test` invocation that
did not receive the opt-in fixture environment was counted as skipped; it is
not parity evidence. No new release archive, production attention switch,
larger pool, or performance optimization was made.

The complete compact evidence record is
`/Users/m/Downloads/Qwen35-K8-Q2.16-explicit-validation-report.json`, 8,856
bytes, SHA-256
`3401b162befdef42e1a72cdfb9755a2decc36c4eaba8cd6942934542dd267037`.

**Q2.16 result: IMPLEMENTED — FULL EXPLICIT VALIDATION STILL PENDING.**

## 8. Q2.17 explicit-path lifecycle closeout (2026-09-16)

Q2.17 reused the accepted Q2.16 independent fixture; no oracle regeneration,
checkpoint copy, attention change, pool change, or dependency change was made.
The fixture is
`/Users/m/Downloads/Qwen35-K8-Explicit-Attention-Reference-v2.zip`, 162,067
bytes, SHA-256
`cfc30f62bfe1352bb1ba5586949c908ae27e55cd0cd12ee518d0d038065eb66a`.

The test-only lifecycle seam is developer-only: the ordinary engine leaves the
phase observer unset, and the queued-read counter is a bounded resource field,
not a hot-path statistics history. The current model contract stayed fixed at
official K=8, one shared expert, the installed 4-bit artifact, Thinking Off,
greedy sampling, and the explicit ordinary-MLX full-attention sequence.

### Cancellation and immediate recovery

`QwenStreamOracleFixtureTests.testOptInQwenQ217LifecycleCloseout` executed one
case with zero failures in 115.288 seconds. It cancelled three generations at
observable boundaries and immediately ran an eight-token prefix from the
accepted fixture after each cancellation:

| Cancellation point | Evidence before cancel | Recovery | Quiescence assertions |
| --- | --- | --- | --- |
| Prefill | `prefill-group-start`; 0 output bytes | 8/8 expected IDs | owner/pool/leases/queued reads/active reads all clear |
| Expert acquisition | `expert-reads-start:prefill`; 0 output bytes | 8/8 expected IDs | same zero-resource boundary |
| Cached decode | 2,906 bounded phase events; 10 output bytes | 8/8 expected IDs | same zero-resource boundary |

The final fresh recovery generated all 64 expected IDs. It recorded 730
explicit full-attention calls and zero fused calls. No stale streamed output or
reused recurrent/KV state reached a recovery request. The direct XCTest process
printed repeated AddressBook/CoreData XPC connection errors from the host test
runner, but the Qwen test itself passed and did not crash.

### Model switching

`QwenStreamOracleFixtureTests.testOptInQwenQ217ModelSwitchLifecycle` executed
one case with zero failures in 68.489 seconds. The real `EngineRouter` and
`EnginePool(maxResident: 1)` path performed:

1. Qwen load and one-token smoke generation;
2. switch to the existing installed `Qwen3.5-9B-abliterated-MLX-4bit` MLX model
   and a smoke generation;
3. switch back, reconstruct Qwen, and run the accepted 64-token explicit
   fixture.

The switch-back fixture was identical (64/64), with explicit calls `730` and
fused calls `0`. Qwen execution leases and active reads were zero at the final
boundary. No Qwen file, registry entry, or expert payload was removed.

### Quit, relaunch, and rediscovery

The built macOS app was launched outside the XCTest host so its normal
`AppState.restoreLaunchState` path ran. For the controlled check, the existing
preferences file was backed up, the already-installed Qwen ID was selected as
the last local model, and the exact original preferences were restored after
the check. The first fresh process opened the four installed Qwen shards; it
was quit through the normal application lifecycle. A second fresh process
rediscovered the existing Application Support model and exposed
`Qwen3.5 35B A3B — SSD Streaming (Experimental)` as ready in the app
accessibility tree. No download or checkpoint copy occurred, and the registry
continued to point at the pinned revision and managed model directory.

The fresh process itself then ran the accepted fixture through the
developer-only explicit probe and passed: 64/64 IDs, `output_limit`, explicit
`730`, fused `0`. The accepted fixture test was rerun after the lifecycle
instrumentation and passed in 41.842 seconds: 64/64 IDs, 63 cached-decode
calls, explicit `730`, fused `0`. The Q2.15 rolling storage/resume suite was
rerun with the bounded Python environment: 6 tests passed, 0 failed. The
macOS build-for-testing passed after the queued-read diagnostic was added,
and `git diff --check` was clean for the changed Qwen files.

Task-generated disposable Q2.9/Q2.10 build directories and old derived test
directories were removed only after the host reached an `ENOSPC` condition;
the installed checkpoint, user model files, preferences, chat history, and
current `.derived-q217` build were preserved. The fixture rerun then completed.

No 3 GiB expert-pool allocation, performance A/B, fused-attention change,
production default change, or public release rebuild was started. The existing
experimental release remains unchanged:
`/Users/m/Downloads/beetcode/BeetCode/dist/Vamp-Assistant-Qwen-Streaming-UNVALIDATED-build93-q2.3.zip`, SHA-256
`8ce35c16a693a3a61913e0b116319ba4a5a0e4431755495a06b133822b8c9a45`;
deep signing had already passed with the existing Apple Development identity,
and notarization remains unavailable/not claimed.

**Q2.17 result: CORRECTNESS BASELINE VALIDATED — EXPLICIT ATTENTION PATH MATCHES INDEPENDENT REFERENCE.**

This status is deliberately scoped to the developer-only explicit strategy
against the pinned quantized Qwen3.5-35B-A3B K=8 Metal reference. The current
user-facing fused strategy remains experimental/unvalidated; selecting or
shipping it is outside this phase.

## 9. Q2.18 production attention strategy (2026-09-16)

Q2.18 used the accepted Q2.16 fixture as immutable golden evidence. Expected
tokens were never regenerated from native execution. Model weights, official
K=8, quantization, the router, the shared expert, the 1,213-slot expert pool,
read concurrency 4, the tokenizer/template, Thinking Off, greedy sampling, the
MLX dependency pins, GatedDeltaNet, and cache semantics were all unchanged.
Only attention-strategy selection varied. The 3 GiB pool experiment was not
run.

The golden is
`/Users/m/Downloads/Qwen35-K8-Explicit-Attention-Reference-v2.zip`, 162,067
bytes, SHA-256
`cfc30f62bfe1352bb1ba5586949c908ae27e55cd0cd12ee518d0d038065eb66a`, archive
hash re-verified before every use.

### 9.1 Strategy surface

Three strategies are now exposed through one enum:
`productionFused`, `referenceCompatibleExplicit`, and `candidateHybrid`.
A single resolution point, `effective(queryLength:)`, converts a request into
the concrete strategy that executes. The hybrid rule is
`queryLength > 1 → explicit, else → fused`, keyed to nothing else: no layer
index, position, prompt, or expert ID, so it cannot encode a whitelist of
known failures.

Every generation reports the requested strategy, the set of effective
strategies, and fused/explicit invocation counts split into prefill
(`queryLength > 1`) and decode (`queryLength == 1`). `QwenStreamingDiagnostics`
publishes all of it, so a hybrid run can never be mistaken for a pure one and
a silent fallback is visible rather than hidden. Ordinary generation resolves
one strategy *before* computing attention; dual execution exists only inside
the diagnostic `sdpaCompatibilityProbe`.

### 9.2 SDPA compatibility matrix

`debugSDPACompatibilityMatrix` runs the model once on the explicit capture
strategy — the authoritative native correctness reference — with every
SDPA-executing layer decomposed under it, so the trajectory is pure rather
than mixed. Each captured post-RoPE query, post-update cached K/V, scale, and
mask is then replayed through the fused kernel and the explicit reference from
byte-identical inputs. Three outputs are compared so kernel numerics can be
separated from mask semantics: fused with the production mask mode, fused with
the materialized mask the explicit path uses, and explicit.

Shapes are the real production shapes of the validation fixture, not invented
contexts: head dim 256, 16 query heads, 2 KV heads, prefill `qLen ∈ {3, 4}`
over `kvLen` 4…39, and decode `qLen = 1` over `kvLen` 40…102, across all ten
full-attention layers `[3, 7, 11, 15, 19, 23, 27, 31, 35, 39]`. 190 entries
were measured; the report is byte-reproducible (identical SHA-256 across two
independent runs).

| Phase | Entries | BF16 byte-identical | max relL2 | max maxAbs |
| --- | --- | --- | --- | --- |
| Prefill (qLen 3, 4) | 100 | **0** | 3.4551e-04 | 0.031250 |
| Decode (qLen 1) | 90 | **33** | 1.9333e-04 | 0.00390625 |

Mask semantics agreed on every entry: fused with `.causal`/`.none` was
byte-identical to fused with the materialized mask. The entire difference is
therefore kernel numerics, not mask handling — the comparison is
apples-to-apples.

Worst overall coordinate: prefill layer 31, `qLen=4`, `kvLen=8`,
`[0,1,1,109]`, fused `5.375` versus explicit `5.34375`. Worst decode
coordinate: layer 3, `kvLen=40`, `[0,13,0,12]`, fused `-0.57421875` versus
explicit `-0.5703125` — a single BF16 ULP at that magnitude. The historical
Q2.10 case reproduced: layer 7, `qLen=4`, `kvLen=28` measured
relL2 5.88e-05, maxAbs 0.001953.

Final-token equality was not used as the compatibility test.

### 9.3 qLen=1 fused decode — hypothesis rejected

The hypothesis was that only multi-token prefill is unsafe, so explicit
prefill plus fused qLen=1 decode would be admissible. It is not.

`debugTeacherForcedStrategyReplay` ran the golden prompt plus all 64 golden
generated tokens twice on the same engine: once explicit everywhere, once
hybrid. Both runs consumed identical tokens, so any difference is a true
semantic divergence rather than an artifact of feeding different histories.
The router was traced on all 40 layers at all 63 decode positions.

Before being used as the reference, the explicit baseline was anchored to the
independent golden: 18 router comparisons, **0** membership failures. Its
accounting was complete and pure — 740 explicit invocations
(10 layers × 10 prefill groups + 10 layers × 64 decode calls), 0 fused.

The hybrid candidate resolved exactly as defined: 100 explicit prefill calls
(10 × 10 groups), 0 fused prefill calls, 640 fused decode calls (10 × 64),
0 explicit decode calls.

| Gate | Requirement | Measured |
| --- | --- | --- |
| True K=8 membership differences | 0 | **450 of 2,560** |
| Order-only differences | informational | 781 |
| Predicted-token differences (teacher-forced) | 0 | **2**, first at index 20 |
| Max router score relL2 | — | 9.808e-02 |
| Min K/K+1 gap | — | 0.015625 |
| Layer-19 block outputs byte-identical | 9 of 9 | **0 of 9** |
| Layer-19 SDPA outputs byte-identical | 9 of 9 | **0 of 9** |

The block comparison followed the full signal chain the phase brief names —
SDPA output, head merge, gate, `o_proj`, block output — at decode indices
0, 1, 2, 4, 8, 16, 32, 45, 62. Divergence compounds rather than staying at
one ULP: block relL2 reaches 5.903e-02 with maxAbs 0.014404. A 1-ULP
attention difference feeds the recurrent GatedDeltaNet state and the KV cache
and accumulates across 40 layers and 63 steps.

Q2.6's M=1 quantized-matmul agreement does not transfer: SDPA is a different
primitive, and at head dim 256 the qLen=1 path dispatches to MLX's fused
vector kernel while qLen>1 falls back to ordinary ops with BF16 score
rounding. Both differ from the explicit float32 replay.

Per section 10, no complicated hybrid was built. No per-layer whitelist, no
per-position whitelist, no epsilon fallback, and no router-aware rerun.

### 9.4 Hybrid A against the independent golden

Hybrid A was still run against the accepted 64-token fixture, as a rejected
candidate measured for the record.

| Candidate | Greedy stream | First differing index | Router comparisons | True membership failures | Fused / explicit calls |
| --- | --- | --- | --- | --- | --- |
| `referenceCompatibleExplicit` | **64/64 identical** | none | 21 | **0** | 0 / 730 |
| `candidateHybrid` | diverged | **21** | 21 | **4** | 630 / 100 |

Both stopped at `output_limit` with final consumed position 103 and 63 cached
decode calls, so the divergence is semantic, not accounting. Hybrid failures
included layer 39 position 46 (golden expert 242 replaced by 203) and
wholesale set changes at position 70 on layers 0, 19, and 39.

Hybrid A is **REJECTED**. No exceptions were added to make it pass, and
greedy-stream equality was never treated as a waiver — here it did not even
occur.

### 9.5 Native explicit control extension (128 tokens)

Beyond the independently validated 64-token horizon this is labelled a
**NATIVE EXPLICIT CONTROL EXTENSION**, not independent-oracle validation. A
63-token prompt (the golden prompt plus its own first 24 generated tokens, so
the context stays in distribution) was run for 128 tokens under explicit and
under the strategy that actually ships.

| Arm | Generated | Fused calls | Explicit calls |
| --- | --- | --- | --- |
| explicit (control) | 128 | 0 | 1,560 |
| `productionFused` (shipping) | 128 | 1,430 | 0 |

The shipping fused path differed from the validated baseline in **52 of 128
generated tokens**, first divergence at index 76, with 11 of 93 sampled router
memberships wrong on layers 0, 19, and 39. Both arms reached position 191 with
127 cached decode calls.

This is the concrete cost of the pre-Q2.18 state: the user-facing path was not
merely "unvalidated", it was demonstrably divergent from the reference on its
own output.

### 9.6 Performance

The frozen 128-token benchmark profile ran once per strategy with everything
else held: same installed checkpoint, K=8, 1,213-slot / 2,146,369,536-byte
pool, reads 4, Thinking Off, greedy, same prompt token IDs
(`inputHash cd728cad5d47b96188783df6`, 116 prompt tokens), same 128-token
output limit, same application-pool starting-state policy. Nothing was tuned
during measurement.

| Metric | Explicit baseline | Fused control |
| --- | --- | --- |
| Prefill | 24.758 s | 25.351 s |
| TTFT / first visible | 24.783 s | 25.379 s |
| Decode | 39.539 s | 36.509 s |
| Decode throughput | 3.212 tok/s | 3.478 tok/s |
| End-to-end | 64.324 s (1.990 tok/s) | 61.890 s (2.068 tok/s) |
| Expert hits / misses / evictions | 33,060 / 32,862 / 31,649 | 32,981 / 32,960 / 31,747 |
| Requested = completed bytes | 58,148,388,864 | 58,321,797,120 |
| Completed application reads | 32,862 | 32,960 |
| Process sampled peak | 4,031,614,624 | 4,033,793,672 |
| MLX active / cache / peak | 3.525 / 0.136 / 3.655 GB | 3.525 / 0.135 / 3.655 GB |
| Attention calls | 1,560 explicit (290 prefill / 1,270 decode) | 1,560 fused (290 / 1,270) |

Expert traffic differs slightly because the two arms generate different tokens
and therefore demand different experts. Memory pressure did not trip any guard;
peak process footprint was a bounded 250 ms sampler observation, not a kernel
high-water mark.

The counterbalanced A/B then ran explicit → fused → fused → explicit with
unload, expert-pool reset, and reload between every scored trial, one session,
two trials per arm, no threshold chasing.

| Median | Explicit | Fused | Fused delta |
| --- | --- | --- | --- |
| Decode throughput | 3.2469 tok/s | 3.4154 tok/s | **+5.19%** |
| Decode seconds | 39.118 s | 37.185 s | −4.94% |
| Prefill seconds | 25.276 s | 24.795 s | −1.90% |
| End-to-end seconds | 64.414 s | 61.998 s | **+3.90% faster** |
| Process peak bytes | 4,236,808,032 | 4,477,038,600 | **+5.67%** |

Within-arm spread was 3.216–3.278 tok/s for explicit and 3.401–3.430 tok/s for
fused, so the 5.19% gap sits outside the noise. Fused meets the suggested
benefit gate but **is not eligible for promotion**: it failed correctness.
The gate can only choose between strategies that already passed.

**Cost of correctness:** +2.416 s end-to-end (+3.90%) and −0.168 decode tok/s
(−5.19%) on a 128-token generation, with 5.67% *lower* peak process memory and
a prefill that is not slower in the frozen single-run benchmark.

### 9.7 Production decision — outcome C

Fused qLen=1 decode failed, so `referenceCompatibleExplicit` is now the Qwen
production default. Outcome D does not apply: explicit performance is not
unacceptable. A 3.90% end-to-end cost moves the user-facing path from
demonstrably divergent (52 of 128 tokens) to matching the independent MLX
0.31.1 Metal reference on 64/64 IDs with zero true router membership failures,
while reducing peak memory. The unvalidated fused path was **not** restored
merely because it is faster.

Changes made:

- `StreamQwen35AttentionStrategy.productionDefault` is the single source of
  truth. All 16 `attentionStrategy`/`strategy` default arguments in the Qwen
  streaming stack, `StreamQwen35Attention.callAsFunction`, the engine's stored
  property, and both non-diagnostic-layer ternaries resolve through it, so no
  diagnostic or production entry point can silently execute a strategy that
  production does not.
- `testProductionDefaultIsTheValidatedExplicitPath` locks the decision;
  changing it requires new correctness evidence.
- `QwenStreamingDiagnostics` publishes the requested strategy, the effective
  strategies, and the fused/explicit prefill/decode split. Its summary no
  longer claims "Full generated-token parity pending".
- Catalog entry renamed from `Qwen3.5 35B A3B — SSD Streaming (Experimental)`
  to `Qwen3.5 35B A3B — SSD Streaming`, with notes stating the precise
  validation scope and explicitly disclaiming official Qwen certification,
  BF16 equivalence, cross-version equality, and universal hardware validation.
- The relaunch probe now exercises `productionDefault` and fails closed if the
  shipping default is not the validated path.
- The fused path is retained as a developer/diagnostic strategy and a
  performance control. It is not user-facing.

### 9.8 Lifecycle regression on the winning strategy

All cancellation phases drive `engine.stream()`, so they now exercise the
shipping production default; the test asserts this rather than assuming it.

| Gate | Result |
| --- | --- |
| Cancel prefill (`prefill-group-start`) | 0 output bytes; 8/8 recovery prefix matched golden |
| Cancel expert acquisition (`expert-reads-start:prefill`) | 0 output bytes; 8/8 recovery matched |
| Cancel cached decode (4th `decode-call-start`) | 2,906 events, 10 output bytes; 8/8 recovery matched |
| Regenerate after each cancellation | 64/64 golden IDs, explicit 730, fused 0 |
| Unload / double unload / reload | passed in 63.964 s; pool quiescent, 0 active reads |
| Qwen → lightweight → Qwen (`EnginePool(maxResident: 1)`) | passed in 42.160 s; switch-back 64/64, explicit 730, fused 0 |
| Quit / relaunch / rediscover | fresh process opened the existing shards, normal quit in 1 s, second fresh process rediscovered the same install, no download |
| Generate after relaunch (Debug) | 64/64, `output_limit`, explicit 730, fused 0 |
| Generate after relaunch (**Release binary**) | 64/64, `output_limit`, explicit 730, fused 0 |

Generation owner inactive, pool idle, execution leases 0, queued reads 0,
active reads 0 at every boundary. Preferences were restored byte-for-byte
(SHA-256 `035944e6fe7e7b435a51cfa0852bc778e51f99796aea038a4ff64bcd418be2e8`
before and after); the model directory kept its 2026-09-13 mtime and 19 GB
size, and `config.json` still hashes to the golden `configSHA256`.

### 9.9 Focused regressions

- Q2.18 unit tests: 6 executed, 0 failed (selection rule, counter phase
  breakdown and single-source counting, mask materialization, explicit replay
  determinism, production-default lock).
- Q2.18 opt-in model tests: 5 executed, 0 failed.
- Accepted Q2.16 golden parity rerun after the default change: 64/64 IDs,
  63 cached calls, explicit 730, fused 0, 33.265 s.
- Focused Qwen XCTest classes: `QwenStreamExpertTraceTests` 2,
  `QwenStreamSafetensorsTests` 14, `QwenStreamTensorStoreTests` 7,
  `QwenStreamingPolicyTests` 11, `QwenStreamReferenceAuditTests` 1,
  `QwenStreamFullParityTests` 1, `QwenStreamLongParityTests` 3,
  `QwenStreamLayerParityDiagnosticTests` 1, `QwenStreamQ25LocalizationTests` 6,
  `QwenStreamQ28TieTests` 1, `QwenStreamQ29LocalizationTests` 12,
  `QwenStreamOracleFixtureTests` 4 — all with 0 failures.
- Q2.15 rolling storage/resume suite: 6 tests, 0 failures. Bounded-oracle
  self-test passed; Python compilation passed.
- Broad suite: 1,041 executed, 44 skipped, 2 failed — both pre-existing and
  unrelated to attention. `SettingsStoreTests.testLegacyBeetAppearanceMigratesToDarkOnce`
  is the same OLED appearance assertion Q2.17 recorded.
  `ComposerStoreTests.testChatOnlySendHasNoWorkspaceOrToolPromptAndPersists`
  reproduces in isolation at its 6-second `waitUntil` timeout: `PromptBuilder`'s
  `leanPrompt` branch, added by earlier uncommitted work, no longer emits
  "project-free assistant mode" while `IntentTests` still asserts it. Its
  production files were last modified 2026-09-09 and 2026-09-13, before this
  phase, and the test uses `FakeLLMEngine` with `ModelCatalog.all.first`
  (`qwen3-1.7b-4bit`), so it cannot reach any path this phase touched.
  Attention-related failures: 0.

### 9.10 Release

Release build succeeded. `codesign --verify --deep --strict --verbose=2`
passed on the built app and again on the app extracted from the ZIP; both
report `valid on disk` and `satisfies its Designated Requirement`, with
`flags=0x10000(runtime)`.

- App: `/Users/m/Downloads/beetcode/BeetCode/.derived-q218-release/Build/Products/Release/Vamp Assistant.app`
- ZIP: `/Users/m/Downloads/beetcode/BeetCode/dist/Vamp-Assistant-Qwen-Streaming-VALIDATED-build93-q2.18.zip`
- ZIP size: 20,772,039 bytes
- ZIP SHA-256: `1a07a7c3e316fc040404c5fbf30667a83c869b5d892cabad89cc96e82fde5af6`
- Binary SHA-256: `9f1ef9047830c32ad19e0237a15171100ab46ea46ee0b5dd58834c6054640b22`
  (identical before and after the ZIP round trip)
- Identity: `Apple Development: mesutcy2@gmail.com (5L35U7C726)`, TeamID
  `438VSM6P5L`, `com.beetcode.app`, 0.10.35 (93)
- Notarization: **not performed** — an Apple Development identity, not
  Developer ID Application. `scripts/validate-macos-distribution.sh` was not
  run because it requires a Developer ID signature and a stapled ticket.

No model file was deleted or redownloaded and no user data was altered;
preferences were restored to SHA-256
`035944e6fe7e7b435a51cfa0852bc778e51f99796aea038a4ff64bcd418be2e8` and the
model directory kept its 2026-09-13 mtime, 19 GB size, and golden
`configSHA256`.

The compact evidence record for this phase is
`/Users/m/Downloads/Qwen35-K8-Q2.18-attention-strategy-report.json`, 25,886
bytes, SHA-256
`0bfdaaeb5efb6dab3c11e8820ae69f4df41d05c2e79d5a605f6c9d570aacf158`. It
references the per-test artifacts: the compatibility matrix
(`fcaddc70cf03d536f3bbd6c90747f831965afb5160d89924a03b94abc5b8487a`), the
qLen=1 verdict and its 1.58 MB routing record, the golden classification, the
128-token control extension, the A/B trials, and both relaunch probes.

### 9.11 Validation wording

User-facing Qwen may be described as:

**VALIDATED AGAINST PINNED QUANTIZED QWEN3.5-35B-A3B K=8 MLX 0.31.1 METAL
EXPLICIT-ATTENTION REFERENCE**

Scope: 64 generated token IDs, 63 cached-decode calls, 730 explicit attention
invocations, zero fused invocations, and zero true K=8 router membership
failures on Apple M4 mini / macOS 26.6.2 / 16 GB unified memory with the
1,213-slot pool, plus the cancellation, model-switch, and quit/relaunch
lifecycle gates above.

Not claimed: official Qwen certification, BF16 equivalence, cross-version
equality, or universal hardware validation. Independent coverage ends at 64
generated tokens from the 39-token golden prompt; the 128-token run is a native
explicit control extension.

### 9.12 Next approved optimization target

Attention correctness is settled, so Q2.19 may resume the expert-cache
capacity experiment: 1,213 slots / ~2.15 GB versus 1,819 slots / ~3.0 GiB,
where offline simulation predicted hit rate 50.2% → 62.0%, misses
32,981 → 25,158, and requested expert bytes 58.359 GB → 44.516 GB. It was not
run in this phase.

A second requirement is now evidenced: a performant correctness-compatible
attention kernel. Fused SDPA is 5.19% faster on decode but demonstrably
divergent, so recovering that margin needs a kernel that matches the explicit
reference — not a routing whitelist, which this phase explicitly ruled out.

**Q2.18 result: PRODUCTION VALIDATED — EXPLICIT ATTENTION.**
