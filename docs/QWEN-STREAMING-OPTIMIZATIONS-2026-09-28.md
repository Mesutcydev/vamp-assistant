# SSD streaming: prompt state and reusable expert slots

Mac build: 0.10.49 (128). The iOS companion remains 0.10.48 (127); the
streaming backend runs on the Mac and the remote protocol is unchanged.

The restored `mlx-community/Qwen3.5-35B-A3B-4bit` checkpoint at revision
`1e20fd8d42056f870933bf98ca6211024744f7ec` is used directly. No model files,
quantization, K=8 routing, shared expert, tokenizer, four-token prefill groups,
read concurrency (four), or explicit attention arithmetic are changed.

## Implementation

- Retain one in-memory prefill checkpoint before the assistant-generation
  suffix, aligned to the existing prefill group. Reuse requires an exact
  token-prefix match, the same thinking/attention settings and the same group
  size. Both attention state and GatedDeltaNet convolution/recurrent state
  are copied. Later template rewriting of thinking content therefore cannot
  silently substitute the wrong state. The previous assistant answer is
  still processed in its canonical history form; this does not reuse an
  arbitrary generated-token cache or rewind recurrent state.
- Publish a replacement checkpoint only after a successful reply. Replay,
  reset, cancellation, unload, attention-strategy changes, and transient
  memory trimming invalidate it. Reserve another 256 MiB in admission for
  the saved state. Nothing is persisted to disk.
- Store experts in nine contiguous MLX/Metal arrays with stable slot IDs.
  CPU commits only overwrite unleased slots between fully evaluated GPU
  forwards. Allocation verifies the Metal buffer aliases the MLX storage.
  The gather receives slot indices instead of rebuilding weight, scale and
  bias stacks each layer/token. Read buffers are released after evaluation.
  No packed sidecar or second checkpoint copy is needed.
- Add an explicitly selectable 3 GiB pool ceiling for controlled experiments;
  admission still falls back through 2 GiB, 1 GiB and 512 MiB. A full 3 GiB
  ceiling holds 1,820 bundles; the earlier offline estimate used 1,819.
  Keep the stacked path as an explicit diagnostic control.

## Validation and measurements

Target: Mac mini M4, 16 GiB, macOS 27; pinned Swift MLX dependencies. These
are local measurements, not cross-device performance guarantees.

- Before changes: 1,059 Mac tests passed, 47 opt-in skips, no failures.
- Reusable slots: all 64 generated IDs matched the independent Q2.16
  explicit-attention fixture, with no failures in compared K=8 router sets.
  Golden JSON SHA-256:
  `36d28854abfb78114b46a53b55607cfb4216b2ebd65d3aafb7618cc1d03d82f0`.
- Follow-up comparison: 112 of 150 prompt tokens reused; identical generated
  answer. First token 6.028 s with reuse versus 16.321 s for full replay.
  Reset and transient-trim invalidation passed. This is one controlled
  conversation, not a general 2.7x speed claim.
- Cache/slot comparison: eight trials, 128 output tokens per trial, greedy,
  thinking off, cold application pool after each reload. Four configurations
  are run in forward then reverse order. Input token hash
  `5132a77d9d001e0a6c612618`. OS file cache is not forcibly purged. Requested
  bytes are application range reads, not measured physical SSD traffic.

Eight trials completed with identical generated output in every run. Medians:

| Expert storage | Pool | Decode tok/s | First token | Total time | Requested bytes | Peak process |
| --- | --- | --- | --- | --- | --- | --- |
| Stacked control | 2 GiB | 3.440 | 9.967 s | 46.892 s | 40.800 GB | 4.329 GB |
| Stacked control | 3 GiB | 3.511 | 10.427 s | 46.597 s | 32.045 GB | 5.615 GB |
| Reusable slots | 2 GiB | 4.531 | 8.640 s | 36.669 s | 40.800 GB | 4.537 GB |
| Reusable slots | 3 GiB | 4.730 | 8.399 s | 35.253 s | 32.045 GB | 5.612 GB |

Decision: enable prompt-state reuse and reusable slots with the **2 GiB**
default. Slot reuse improved decode throughput by 31.7% and reduced complete
request time by 21.8% against the stacked 2 GiB control. Increasing the bank
to 3 GiB saved 21.5% requested bytes, but improved decode only another 4.4%
while adding about 1.08 GB process memory. The explicitly selectable 3 GiB
experiment remains available without becoming the 16 GiB default.

The [raw trial data](QWEN-STREAMING-SSD-BENCHMARK-2026-09-28.json) records
per-run values. These trials use the Debug test host. System swap was already
in use and grew about 56 MiB during the complete comparison; other apps were
running, so that delta is not attributed solely to this engine. Physical
SSD traffic and thermal deltas were not instrumented.

Final regression gates:

- Mac suite: **1,064 passed, 50 opt-in skips, zero failures**.
- iOS companion suite: **43 passed, zero skips/failures**.
- Optimized Release validation (`ENABLE_TESTABILITY=YES` only for the test
  invocation): **8 passed, one intentional skip** (the eight-run performance
  experiment had already run separately). This covers checkpoint isolation,
  budget/slot bounds, exact 64-token golden output and sampled router sets,
  follow-up replay equality, reset/trim, and cancellation/recovery.
- Release follow-up: 112/150 prompt tokens reused, identical answer;
  first token **4.923 s versus 12.964 s** with full replay.
- Explicit lifecycle matrix: cancellation during prefill, expert acquisition,
  and cached decoding drained reads and leases; each recovered its expected
  eight-token prefix, followed by a complete 64-token golden recovery.
- The initial Release test attempt lacked `ENABLE_TESTABILITY=YES` and failed
  to import the internal app module; the corrected invocation passed. A
  normal Release build is produced separately for delivery.

The iCloud IPA was independently checked: ZIP CRC, published SHA-256,
`Payload` structure, iPhoneOS arm64 executable, executable permission and
iOS 18 minimum deployment target. A new copy named
`Vamp-Assistant-iOS-0.10.48-build-127-recopied-unsigned.ipa` and its checksum
were uploaded to `iCloud Drive/OnDevice Builds`; Foundation reports fully
uploaded with no error. Its executable is identical to build 126. This is
archive/sync verification, not a physical-phone signing/install test; the
reported phone failure has not been specified.

Delivery completed: the normal Release build **0.10.49 (128)** is installed
at `/Applications/Vamp Assistant.app`. Strict deep signature verification
passes with the previous designated requirement preserved; no `.xctest`
bundle is included. The app opened successfully, its composer is ready, and
the restored SSD-streaming Qwen remains available in the local model picker.
The previous app is retained at
`dist/rollback/Vamp Assistant-0.10.48-build127-before-0.10.49.app`.

Local preview package: `dist/Vamp-Assistant-0.10.49-build-128-preview.dmg`,
verified with `hdiutil verify`, SHA-256
`5386508b58c882c26c62d6b054f82e0688a204a3bfbc6084fc800a1e5b53883d`.
This local build has not been published as a GitHub release or website update.
Temporary simulator build products were removed after validation; test result
bundles and benchmark evidence are retained.

## Research references

- [SSDMoE](https://github.com/RasoulNik/ssdmoe): conversation prefix reuse
  and template mismatch handling. Its default reduced-K throughput is not
  used as an equivalent full-K=8 benchmark.
- [ANEMLL Flash MLX](https://github.com/Anemll/anemll-flash-mlx): stable expert
  banks with indices, separating cache-hit execution from miss preparation.
- [Apple, LLM in a Flash](https://machinelearning.apple.com/research/efficient-large-language):
  minimizing transferred bytes and improving storage access locality.

Router lookahead, changed precision, and fused attention remain separate
experiments. None is required for these changes.
