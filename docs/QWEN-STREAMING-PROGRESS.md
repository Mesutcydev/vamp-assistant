# Qwen streaming progress

Status: CORRECTNESS BASELINE VALIDATED — Q2.16 independent explicit 64-token parity and Q2.17 lifecycle closeout passed. This status applies only to the developer-only `referenceCompatibleExplicit` strategy; the user-facing fused production path remains experimental/unvalidated. The current 1,213-slot pool, official K=8 routing, model files, and release artifact remain unchanged. See QWEN-STREAMING-REPORT.md for the exact fixture, cancellation, switch, relaunch, and quiescence evidence.

Current workspace: Downloads/beetcode/BeetCode; Desktop source copy is not the implementation target.

Completed: native exact K8 model seam, bounded range storage/pool, pinned artifact manifest, Mac budget, existing engine/catalog/downloader integration, external bookmarks, text-only restriction, Thinking, cancellation ownership, phase-split/privacy-safe diagnostics, bounded actual-router prefill groups of at most four tokens, independent bounded quantized projection audit, and Debug/Release builds.

Current focused run: 65 Qwen/foundation tests executed, four intentional opt-in skips, zero failures before the live fixture gate; direct `xctest` bypassed the Xcode runner worker-materialization stall. Q2.17 then executed the accepted explicit fixture, phase cancellation/recovery, model-switch, and fresh-process relaunch probes with zero failures. After the host reboot, the direct full bundle completed 1006 tests with 17 skipped and six unrelated failures (two BotComputerService persistence assertions, two Composer/CoreData-dependent assertions, one EndToEnd approval assertion, and the existing OLED expectation). Q2.2 and Q2.3 remain historical tooling milestones; no larger pool or second optimization was started.
Last full macOS run: 993 tests, 10 skipped, one existing OLED expectation mismatch; /tmp/vamp-qwen-final-tests.log.
Release build: current arm64 app is present at `.derived/Build/Products/Release/Vamp Assistant.app`; `codesign --verify --deep --strict` passed. Executable size is 65,090,672 bytes with SHA-256 `938e8e88b4e0a529c7e27693bbbe7f0651e4c8bcf31d482d45f067b56b71c520`. Current validation ZIP is `dist/Vamp-Assistant-Qwen-Streaming-UNVALIDATED-build93-q2.3.zip` (20,718,580 bytes, SHA-256 `8ce35c16a693a3a61913e0b116319ba4a5a0e4431755495a06b133822b8c9a45`); it is signed with the existing Apple Development identity and is not notarized. The q2.1 and q2.2 ZIPs remain preserved.

Installed: revision 1e20fd8d42056f870933bf98ca6211024744f7ec, exact 20,411,897,485-byte inventory, all file sizes and SHA-256 values verified. The current Downloads Release app loaded it, answered an exact-answer smoke with `OK`, answered a normal follow-up with `4`, and returned to `FINISHED` after Stop without appending a canceled answer. The latest observed turns were 32.5 s and 3.7 s on this host; these are single-token end-to-end observations, not decode tok/s.

Benchmark: Thinking Off, temperature 0, greedy, fixed 186-token app prompt, max output 128, official K=8, one warm-up plus two scored fresh chats. Scored decode: 2.43 tok/s over 52.25 s and 2.35 tok/s over 54.15 s; median 2.39 tok/s. A post-instrumentation validation run recorded 123.25 s total, 191.20 s aggregate range-read time, process 106.4 MB before load / 1.61 GB after load / 4.08 GB end sample, and MLX 3.53 GB active / 3.65 GB peak. The exact byte check is `42,657 misses × 1,769,472 bytes = 75,480,367,104` requested expert payload bytes.

Opt-in phase test: same user text with the native 117-token lean text-only envelope (recorded separately from the 186-token app request), 128 output tokens, output-limit stop, 58.93 s total, 23.60 s prefill, 35.31 s decode over 127 intervals (3.60 tok/s), 58,358,956,032 requested/completed bytes, 32,981 misses, 33,229 hits, 31,768 evictions, and peak reads 4/4. Prefill/decode requested bytes were 28,814,082,048 / 29,544,873,984. Sampled process peak was 4.05 GB; MLX peak was 3.65 GB. This confirms phase counters, trace retention, and payload accounting without replacing the scored baseline.

Independent reference state: the target-host fixture was generated with mlx-lm 0.31.1 / MLX 0.32.2 on CPU using the config-declared FP32 recurrent state and the same installed artifact. The five short final-logit fixtures still match greedy top-1 and the frozen drift envelope; one top-k tail is a documented near-tie. The corrected layer-isolated primary fixture contains 64 generated IDs and checkpoints through cached decode step 64. Native comparison first diverges at generated-token index 5; router IDs/order and sampled layer/cache summaries already differ at prefill. The Q2.1 CPU long-generation attempt and the first Q2.2 guarded attempt remain historical interrupted runs, not parity results.

Trace analysis: the lean 117-token diagnostic run recorded 66,210 expert keys and simulated 50.2% hit rate at the current 1,213 slots, 56.8% at 1,516, 62.0% at 1,819, and 68.7% at 2,122. The earlier ~3.49/3.61 tok/s lean run is not directly comparable with the scored 2.39 tok/s 186-token app request; application-pool churn is a hypothesis until the same rendered prompt and cold/warm pool protocol are used. No larger pool has been allocated or promoted.

Cleanup: removed only old generated macOS/iOS/test DerivedData directories, disposable current build caches, and thinned the temporary APFS local snapshot holding their blocks. The installed model and current app remain intact; the final post-build filesystem check reports 31,748,030,464 free bytes (about 29.6 GiB) after the Release rebuild and q2.3 validation ZIP.

Q2.4 target-only gate: `Tools/QwenOracle/qwen35_k8_layer_oracle.py` generated and verified the retained compact fixture [dist/Qwen35-K8-Layer-Isolated-v3.zip](/Users/m/Downloads/beetcode/BeetCode/dist/Qwen35-K8-Layer-Isolated-v3.zip) (64 tokens, checkpoints `-1, 1, 2, 4, 8, 16, 32, 64`, archive SHA-256 `9665fb696d78eb18a4696fe0305f88fa55f56e336948c9331a6270fc96db5650`). The opt-in native comparison executed one real 64-token run with ten four-token prefill calls and 64 cached decode calls, then failed at generated-token index 5; sampled router IDs and hidden/cache summaries also diverged. The lifecycle matrix passed independently. Do not label numerical parity complete, advertise agent tools, enable predictive staging/g4, or run the 3 GiB pool experiment until the first semantic mismatch is resolved. Do not reuse Edge0 K4/LoRA fixtures.

Full app validation action and independent numerical parity remain unfinished because native/reference semantics diverge. The acceptance-level lifecycle matrix passed independently, but it cannot promote the backend while the numerical gate is failing. No model weights or credentials were committed. Existing unrelated edits were preserved.

Q2.5 localization update (2026-09-15): the supplied `EXC_BREAKPOINT` report is
from the earlier Debug binary, build 93, whose backtrace still contains the
temporary `streamGatedDeltaOpsDiagnostic` probe at `QwenStreamModel.swift:1071`.
That probe is absent from the current source and from the fresh
`.derived-q25-current-v1` test binary. A new build-for-testing completed, and
the opt-in boundary test now reaches its assertions without the old MLX shape
trap. The crash was therefore a stale diagnostic-build failure, not evidence
that the current production path still calls that probe.

The corrected one-layer oracle fixture now retains complete bounded layer-0
router inputs and 256-way logits for all 39 prompt positions. The committed
`Tools/QwenOracle/qwen35_router_replay.py` diagnostic replays the pinned MLX
softmax/argpartition selector without reading model weights. On the captured
reference/native pair, all 39 reference and native selectors reproduce their
own recorded K=8 sets; six positions differ only in `argPartition` order. Two
positions are genuine cross-runtime K/K+1 set differences: position 2
(`72` versus `86`, both K-gap 0.015625) and position 7 (`163` versus `30`,
reference gap 0.03125 and native gap 0.015625). The native boundary test
therefore still fails the required parity gate, with the first demonstrated
semantic difference in layer 0 before any later-layer or cache optimization.

The fresh run used 10 prefill calls (nine groups of four tokens and one group
of three), and the diagnostic counters remain explicit: a 64-token debug run
uses 64 cached decode feeds, 63 emitted-token intervals, one final-state probe,
and ends at consumed position 103. No 3 GiB pool allocation, K change, kernel
change, or scheduling optimization was started. Backend and release artifact
remain **UNVALIDATED** pending resolution of the native/reference router and
long-generation mismatch.

Q2.5 continuation (2026-09-15): the raw-input selector replay completed on the
fresh build's six saved vectors (one control plus layer-0 positions 2 and 7
from each side). It preserves complete BF16 bit patterns rather than rounded
decimal summaries. All 39 captured reference rows and all 39 native rows
reproduce their own recorded K=8 selections. The same-input A/B replay agrees
on sets and orders, and a native quantized gate projection fed the exact
reference router inputs with relL2 values `0.00249`, `0.00218`, and `0.00240`
for the control, position 2, and position 7 rows respectively (maxAbs
`0.03125` in each case). This rules out a selector-replay, expert-pool-key, or
quantized-gate defect in the saved cases.

Cross-runtime comparison still has two real membership changes: at layer 0,
zero-based prefill position 2, reference chooses expert 72 and native chooses
86; at position 7, reference chooses 163 and native chooses 30. The captured
logit gaps are nonzero (`0.015625` at position 2 on both sides; `0.03125`
reference and `0.015625` native at position 7), so these are not exact ties.
Six additional rows have equal sets with order-only differences attributable
to `argPartition` ordering. The boundary test therefore still fails at
position 2 and the downstream layer-0 MoE output (relL2 `0.1810959`); no
production math fix is justified yet.

The retained independent 64-token fixture also ran a same-prefix,
teacher-forced native decode. At generated-token index 5, with prefix
`[16, 13, 19137, 344, 56127]`, the independent CPU reference predicts token
`1870` while native predicts `8806`. Reference logits for those IDs are
`21.375` and `21.25`; native logits are `22.25` and `21.625`. The portable
comparison produced 64/64 tokens through 64 cached calls and failed at this
same first index, so the result is a reproducible semantic mismatch rather
than a short-output or prefill-only artifact. The 3 GiB pool experiment remains
paused, and the backend remains **UNVALIDATED**.

Q2.6 activation localization (2026-09-15): a fresh, independent two-group
boundary was generated from the same installed artifact with complete BF16
values for the eight zero-based prompt positions `0...7`. The new native
diagnostic build exported its complete layer-0 boundary for the same token
IDs. Both sides report `[1, 4, 2048]` attention inputs in BF16, and the full
input-normalization rows are identical (`relL2=0`, `maxAbs=0`) at every
position. The first A-G mismatch is therefore layer-0 `attentionOutput` on
position 0, in a fresh first chunk; it is not caused by the second-chunk
recurrent carry or by expert selection.

The saved p0 A-G row is:

| Operation | Shape | Reference norm | Native norm | relL2 | maxAbs | Worst coordinate |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| embedding | `[2048]` | 0.5697079 | 0.5697079 | 0 | 0 | `[0]` |
| input normalization | `[2048]` | 46.2400782 | 46.2400782 | 0 | 0 | `[0]` |
| attention output | `[2048]` | 2.1896182 | 2.1904234 | 0.0054941 | 0.0010376 | `[1307]` |
| post-attention residual | `[2048]` | 2.2915094 | 2.2921395 | 0.0054669 | 0.0010376 | `[1307]` |
| post-attention normalization | `[2048]` | 35.6826837 | 35.6789196 | 0.0064202 | 0.03125 | `[585]` |
| router logits | `[256]` | 87.7361657 | 87.6107795 | 0.0030692 | 0.03125 | `[1]` |
| selection scores | `[8]` | 0.3618895 | 0.3606495 | 0.0083174 | 0.0019531 | `[3]` |

The expanded layer-0 linear-attention comparison uses the same saved attention
input and finds `qkv` as the earliest differing operation. At p0 its shape is
`[8192]`, both sides are BF16, reference/native norms are `111.6734987` /
`111.6656249`, relL2 is `0.00464215`, maxAbs is `0.0625`, and the worst flat
coordinate is `[5071]`. The remaining projection and recurrent subpath rows
are retained in the generated comparison JSON; for p0, `z` relL2 is
`0.00547677`, `b` `0.00360141`, `a` `0.00242367`, convolution `0.00439154`,
q/k normalization `0.00446059` / `0.00572439`, gated output `0.00705106`,
normalized output `0.00392334`, and final attention projection `0.00549409`.
At p2 (first group) and p7 (second group), qkv is also first (`0.00374423` /
`0.00403113` relL2; maxAbs `0.125` for both). Positions p2 and p7 remain
the earlier genuine K/K+1 membership cases, but their selector is no longer
the earliest numerical source.

The pinned shard headers confirm the effective contract: layer-0 QKV is affine
4-bit, group size 64, with `U32 [8192,256]` weights and BF16
`[8192,32]` scales/biases; `conv1d.weight` is already `[8192,4,1]` BF16;
there are no MTP tensors. Native sanitization therefore performs no conv-axis
move and no norm-weight `+1` shift. The independent Python quantized QKV
projection reproduces its boundary exactly, so the saved input/weight path is
consistent. Native uses mlx-swift 0.31.6 (MLX C package revision
`0bb916c...`), while the independent oracle uses MLX 0.32.2; the observed
cross-runtime QMM drift is a concrete version/kernel difference to investigate,
not an accepted parity result. No production math or scheduling fix was
introduced, and no tolerance was changed. The 3 GiB pool experiment remains
paused; Qwen remains **UNVALIDATED**.

The temporary diagnostic artifacts were independently hashed for this run:
reference boundary `69c340f355a1ca5070d8729d471a506725fdd8804bc6b8a8eb3917d269fe0148`,
native boundary `74a683074aa0d0859045bf02f5e462e51fa3c38ac365d1f72939447b50ee0951`,
and comparison report `a558c05a27ac937e53d6dbdabe7678b512e098bbec602104d667a813c45202a6`.
They are compact diagnostic outputs under `/tmp`; no weights or large fixture
was added to the repository.

## Q2.6 operator replay (2026-09-15)

The first differing layer-0 operation was replayed as a compact, independent
operator fixture. `Tools/QwenOracle/qwen35_qkv_operator_replay.py` validates
the installed artifact index, reads only the three layer-0
`linear_attn.in_proj_qkv` ranges, and preserves the raw U32 weight plus BF16
scale/bias bytes. The generated archive
`/tmp/Qwen35-K8-QKV-Operator-v2.zip` is 8,734,119 bytes with SHA-256
`061e773ac37f3b8bf59fb228d0e1a3a7cc3eaeac4a9116ba173185fe753b2d62`; its
metadata SHA-256 is
`c372b2cf4de15d6020c930f83f5d2fd7c17c39dabc1e0364aeb7a77ad592bf2d`.
It contains two `[1,4,2048]` BF16 inputs and their `[1,4,8192]` BF16
reference/native outputs, not model shards.

The opt-in native XCTest ran the real Vampire Assistant boundary (A) and a
direct Swift MLX `quantizedMM` replay over those bytes (B). Both four-token
groups and the follow-up one-token dispatch were byte-identical between A and
B. Their relative L2 against the independent boundary is `0.00344288` /
`0.00379739` for M=4 (maxAbs `0.25` / `0.125`) and `0.00464215` for M=1
(maxAbs `0.0625`). The native test executed one case with zero failures.

The independent Python matrix used the same fixture, weights, quantization
arguments (`transpose=true`, affine, bits 4, group size 64), and Metal device:

| Leg | Runtime | M=4 group 0 | M=4 group 1 |
| --- | --- | --- | --- |
| A | Vampire Assistant / MLX core 0.31.1 | native bytes | native bytes |
| B | Swift direct `quantizedMM` / MLX core 0.31.1 | native bytes | native bytes |
| C | Python MLX 0.31.1 | native bytes | native bytes |
| D | Python MLX 0.32.2 | reference bytes | reference bytes |

The C output hashes are `a67aae3654ef320e9cc55324830681798f2e20271e488fd53638e451775a7abc`
and `bf44c03d35b1f6c8a3096b0f918db9ece277f0f727462aa53cc5db572097bc66`;
the D hashes are `8ea1396069664d51c6786c1e9a1b2e62323b2c35a1c9e29c2a020021028800a5`
and `cd3ddef548e656e1c341974be6617cda1e8b607d5d7ec8a851fc6d10e9a6e022`.
The M=1 Metal replay in both Python 0.31.1 and 0.32.2 follows the native hash,
showing that the dispatch difference is shape/device-specific; this does not
prove that a package version alone explains every path. CPU-only replays were
recorded separately and are not the target execution contract.

The fresh app links mlx-swift 0.31.6 at revision
`0bb916c67f4b9e5c682cbe02a42c701c93ab5021`, with MLX core commit
`ce45c52505c8158ea48d2a54e8caae05efd86bfe` (`v0.31.1`) and mlx-c commit
`0726ca922fc902c4c61ef9c27d94132be418e945` (`v0.6.0`). The matrix therefore
rules out an A/B wrapper or byte-loading defect and localizes the mismatch to
the native-versus-independent quantized operator/runtime contract. No MLX
dependency, model math, K value, pool size, or scheduling policy was changed.
The long token/state parity gate is still open, Qwen remains **UNVALIDATED**,
and the 3 GiB pool experiment remains paused.

## Q2.7 full-model matched-core validation (2026-09-15)

The independent corrected oracle completed on the installed checkpoint under
the guarded one-layer worker pipeline. It used `mlx-lm 0.31.1`, MLX `0.31.1`,
Metal, the config-declared FP32 recurrent state, the same tokenizer/template,
official routed K=8, and the shared expert. The compact archive retained for
native comparison is `~/Downloads/Qwen35-K8-Matched-Core-v3.zip`, 184,367
bytes, SHA-256
`a1ee403e54fdcd496482bd4af972eebef553d20160b8a721bf2f55f299d53777`; its
`fixtures/primary.json` is 1,005,853 bytes with SHA-256
`8dc884ff4e14371000c329c5f209cae4b4183dd48ba9173bbb03fdccb3d2019d`.
The archive contains only the fixture, manifest, and README; no model data.

The 39-token rendered prompt and all 64 greedy generated token IDs match the
native streamed run exactly. Both runs stop at the output limit, finish at
consumed position 103, use ten four-token prefill calls and 64 cached-decode
calls, and retain checkpoints at `-1, 1, 2, 4, 8, 16, 32, 64`. Native
reload after unload and a double-unload boundary also reproduce the same 64
IDs and end quiescent; the fixture-based lifecycle test passed in 26.752 s.

The routing gate remains failed. Of 24 sampled layer/position records, one
actual K=8 membership differs: layer 19, absolute position 46 (the eighth
cached decode input). Reference selects `[61, 33, 111, 43, 71, 226, 211, 108]`
with raw boundary values `61=-4.15625`, `K+1=-4.21875`; native selects
`[245, 33, 71, 111, 43, 226, 211, 108]`, where IDs 61 and 245 both have
`-4.1875` and the selector chooses 245. This is a real K/K+1 membership
change, even though the greedy vocabulary token stays identical. Six other
records (layer 19 positions 42/54/102 and layer 39 positions 38/39/70) have
the same selected set with only `argPartition` ordering changes; they are
logged as order-only diagnostics.

Sampled cache offsets and full-attention KV summaries agree at every retained
checkpoint. Recurrent summaries remain finite and bounded but show expected
cross-runtime numeric drift (for example, sampled layer-18 recurrent-state
relL2 is about 0.021–0.059 across checkpoints). Final-logit top-1 IDs remain
identical; the largest retained top-logit delta is 0.5625 at checkpoint 1,
token 15. The native debug dump is
`/tmp/qwen35-q27-native-run-v3-classified.json` (347,974 bytes, SHA-256
`782475871c6820d4dadac83443afea010a36409b41cd3a5c9a29fd26e6bb5758`). The
focused comparison executed one test and reported six strict diagnostic
failures: one routing-set failure plus five bounded numeric boundary
failures. The earlier 13-failure report included six order-only permutations;
the test now separates those from semantic membership changes.

The corrected oracle required an independent Python Metal gated-delta kernel
with the same MLX 0.31.1 launch contract and FP32 state; the earlier CPU
ops-loop fixture was discarded as an oracle because its reduction order drifted
over long decode. No production model math, dependencies, K value, pool size,
or scheduling policy was changed. The 3 GiB pool A/B remains blocked, and the
backend remains **UNVALIDATED**. Cancellation during expert acquisition,
multilingual secondary fixtures, and lightweight-model switching were not
promoted by this failed parity run and remain explicit follow-up gates.

## Q2.8 selector classification (2026-09-16)

The raw layer-19 / position-46 fixture is
`/Users/m/Downloads/Qwen35-K8-Q2.8-cutoff-tie.json` (234,566 bytes,
SHA-256 `6aee48b0b7516cee63e9447c4257c49f2045f82070bfd39ec9e59767d728d1c6`).
It retains exact BF16 words for the router input, logits, and pre-normalized
selector scores on both sides. The independent MLX 0.31.1 Metal oracle and
the native streamed capture use the same artifact revision and official K=8.

The reference selector has seven strictly greater IDs
`{33,43,71,108,111,211,226}` and exact cutoff class `{61}`. Its score words
are expert 61 `0x3c7b` (`0.01531982421875`) and expert 245 `0x3c6b`
(`0.01434326171875`), so their exact selector difference is
`0.0009765625`. The native selector has the same seven strictly greater IDs,
but exact cutoff class `{61,245}`; both score words are `0x3c72`
(`0.0147705078125`). The corresponding gate logits are reference
`61=-4.15625` / `245=-4.21875` and native `61=245=-4.1875`.

Sixteen repeated Python MLX replays and sixteen repeated direct Swift MLX
replays were deterministic and reproduced their captured side. The native
side is therefore an exact local cutoff tie, but the reference side is
non-tied at the authoritative selector dtype. The mismatch is not
tie-equivalent. The new selector-only XCTest passed its one case; the strict
Q2.7 fixture comparison still reports the original membership failure, as it
should. No tie epsilon, ordering rule, model math, dependency, K, pool, or
scheduling change was made.

The saved native/reference router inputs differ by relL2 `0.0514780581` and
maxAbs `0.18359375`; router logits differ by relL2 `0.004495983` and maxAbs
`0.0625`. A bounded layer-19 probe on the native MoE input found expert 61
norm `0.8881150`, expert 245 norm `1.5147320`, output relL2 `1.9368071`, and
maxAbs `0.1450195`. The reference-style/native-style routed aggregates differ
by relL2 `0.2043427` / maxAbs `0.0141349`; including the identical shared branch
gives MoE relL2 `0.2002655` / maxAbs `0.0141349`. This is diagnostic only and
does not alter production routing.

**Q2.8 result: IMPLEMENTED — TRUE ROUTER PARITY FAILURE REMAINS: layer 19 / position 46.** Keep Qwen **UNVALIDATED**; do not start the 3 GiB pool experiment.

## Q2.9 first-operation localization (2026-09-16)

Q2.9 preserved the Q2.8 cutoff fixture and added the compact teacher-forced
router-input fixture
`/Users/m/Downloads/Qwen35-K8-Q2.9-router-input.json` (471,091 bytes,
SHA-256 `0386926d2fa71a3880d577244bc1d59f5ba45a851911ad516de96bf108c39cfd`).
The same prompt token history, generated prefix, absolute position 46, and
cached-decode boundary are used on both sides. The all-layer native capture
and independent MLX boundary run show that sampled layers 0–7 are equal at
the earlier positions; the first material prefill drift appears at layer 7,
group 6 (positions 24–27), before the later layer-19 router record.

The focused layer-7 full-attention capture then isolated the operation. At
the first failing group, attention input, Q/K/V projections, query gate,
normalized/rotated queries, current K/V values, and the incoming full-attention
cache are bit-identical. Only the attention primitive differs:

| Layer 7 group 6 component | relL2 | maxAbs |
| --- | ---: | ---: |
| `attentionValues` | `7.56919188708802e-05` | `0.00390625` |
| `gatedValues` | `1.904881484449258e-05` | `0.000030517578125` |
| `attentionOutput` | `0.00031510645094774795` | `0.0001220703125` |

Switching the diagnostic from the symbolic causal mask to an explicit causal
mask produced the same result, so the mask representation is not the cause.
The production call is `attentionWithCacheUpdate` in
`Core/Inference/QwenStreaming/QwenStreamModel.swift:547`; its full-attention
diagnostic follows the same path at line 500.

The opt-in native primitive replay used compact focused captures (reference
3,119,722 bytes, SHA-256
`b98d5e2a3cec016a7d7543187c9b14a5d387ccf85bc4e2f375d5d013ed62abf2`; native
2,959,704 bytes, SHA-256
`947ce573bddf853c3022f17a13a9fc73074b9c1400430a4f84ebe1daedf65902`). It
executed Swift `MLXFast.scaledDotProductAttention` with
`Q=[1,16,4,256]`, `K/V=[1,2,28,256]`, head dimension 256, and GQA factor 8.
The native fused result is byte-identical to the production capture
(`fastVsNativeRelL2=0`) but differs from the independent Python MLX result by
`relL2=7.569186011012955e-05`, `maxAbs=0.00390625`. Python MLX's own fast
attention reproduces the oracle exactly. The ordinary Swift MLX operation
sequence is an independent cross-check: it gives
`unfusedVsOracleRelL2=7.584503077329163e-05`,
`maxAbs=0.00390625`, and is close to the native fused output
(`unfusedVsNativeRelL2=4.817775060418114e-06`) but is not an exact oracle
replacement.

The pinned native MLX core selects its Metal vector SDPA path for this shape:
query length 4, key length 28, head dimension 256, and
`queryLength × GQA = 4 × 8 = 32`. The source condition is in the checked-out
MLX core `backend/metal/scaled_dot_product_attention.cpp`; the Python and
Swift builds therefore have different compiled-kernel behavior despite the
same model inputs and core version label. This is a runtime/kernel numerical
drift, not a router selector, score-tie, mask, cache, expert-pool, or model
input defect.

No production attention path, dependency, K value, pool size, or scheduling
policy was changed. Replacing fused SDPA with the ordinary operation sequence
was not accepted as a correctness fix because that sequence still differs
from the independent oracle and its downstream routing effect has not been
demonstrated. The focused diagnostic XCTest executed one case with zero
failures; the build-for-testing also passed. The backend remains **UNVALIDATED**
and the 3 GiB pool experiment remains paused.

**Q2.9 result: IMPLEMENTED — FIRST SEMANTIC DIVERGENCE REMAINS: layer 7 / prefill group 6 / native fused SDPA vector kernel.**

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

Q2.11 added one developer-only attention strategy,
`referenceCompatibleExplicit`, to the native Qwen attention module. It is
reachable only from the diagnostic/test seam; `callAsFunction` and the
production `attentionWithCacheUpdate` path remain unchanged. The candidate
uses ordinary MLX operations in the pinned Python order: `repeat` on axis 1
for the 2-to-16 GQA expansion, Float32 Q/K/V, scale Q before QK matmul,
Boolean `[4,28]` absolute-position masking with Float32's finite minimum,
`softmax(..., precise: true)`, Float32 P×V, and a BF16 output in
`[batch, heads, queryLength, headDim]` layout.

The independent compact Python intermediate package is retained at
`/Users/m/Downloads/Qwen35-K8-Q2.11-Python-explicit-intermediates.json`,
1,738,727 bytes, SHA-256
`7738f43288eb1f44d87a05c4c31f41c2915a9c96e0609bdc44c7d70634f2f8a2`.
The Swift export is
`/Users/m/Downloads/Qwen35-K8-Q2.11-Swift-explicit-intermediates.json`,
6,123,435 bytes, SHA-256
`472603f7de40eef47a3523fdef728b181ca278db1d094e357d67c6b4713d99b6`.
Both packages use the frozen layer-7/group-6 Q2.10 raw fixture and the same
artifact revision/inventory identity.

Every exported candidate stage matched the independent Python stage exactly:

| Stage | Result |
| --- | --- |
| expanded K / expanded V | exact BF16 words |
| raw QK | exact Float32 words |
| scaled scores | exact Float32 words |
| masked scores | exact Float32 words |
| probabilities | exact Float32 words |
| Float32 P×V | exact Float32 words |
| BF16 output | exact BF16 words |

The candidate's output, after the same transpose/reshape used by the
production wrapper, still differs from the independent fused/oracle output:
relL2 `7.584503077329163e-05`, maxAbs `0.00390625`; oracle output SHA
`8793209f20f95348940a167621467d34ec05ac3804e2ac4544fa9e0635d4e904`,
explicit candidate SHA
`4d539b2844e99f029b1bd3caa18201d081293ba99fcee7ccf049712c449b14e6`.
Thus there is no first mismatch inside the ordinary explicit candidate; the
remaining mismatch is between that candidate and the fused/native-oracle
contract. The conditional layer-7 candidate/downstream-router run was not
started because the candidate does not match the independent oracle output.

`testOptInQ211ReferenceCompatibleExplicitIntermediates` executed one case
with zero failures after the opt-in environment was supplied through the
app-host test manifest. The initial environment-free invocation was skipped;
it is not counted as validation. The Q2.11 build-for-testing passed. No model
copy, pool allocation, dependency change, routing change, or performance run
was performed. The backend remains **UNVALIDATED** and the 3 GiB pool
experiment remains paused.

**Q2.11 result: IMPLEMENTED — PRIMITIVE DIVERGENCE REMAINS: native fused SDPA versus the exact ordinary-MLX explicit candidate at layer 7 / prefill group 6.**

## Q2.12 model-level SDPA provenance (2026-09-16)

Q2.12 connected the Q2.11 ordinary-MLX candidate to the actual native model
call without changing production execution. `StreamQwen35Attention.callAsFunction`
and the normal `attentionWithCacheUpdate` path remain fused. The diagnostic
only seam accepts `referenceCompatibleExplicit` for a selected layer/group,
updates the real `KVCache` exactly once, constructs the same Boolean causal
mask, and records the effective strategy and explicit intermediates. The
candidate was invoked once at layer 7, prefill group 6; the other 13 full-
attention diagnostic calls in the pass remained fused. No layer-19/64-token
run, pool experiment, or performance change was started.

The compact report is retained at
`Tests/Fixtures/Qwen35-K8-Q2.12-boundary-report.json` and
`/Users/m/Downloads/Qwen35-K8-Q2.12-boundary-report.json` (6,993 bytes). It
records the Q2.11 Python fixture SHA-256
`7738f43288eb1f44d87a05c4c31f41c2915a9c96e0609bdc44c7d70634f2f8a2`, the
focused Q2.10 source SHA-256
`b98d5e2a3cec016a7d7543187c9b14a5d387ccf85bc4e2f375d5d013ed62abf2`, and
the Q2.9 history SHA-256
`0386926d2fa71a3880d577244bc1d59f5ba45a851911ad516de96bf108c39cfd`.

The boundary names follow the actual model order:

| Boundary | Native data-flow value |
| --- | --- |
| T0 | Q after normalization and RoPE |
| T1 | current K after normalization and RoPE |
| T2 | current V entering attention |
| T3 | QK transpose product |
| T4 | scaled scores, with scale applied before matmul |
| T5 | Boolean-masked scores |
| T6 | precise softmax probabilities |
| T7 | P×V weighted output and BF16 helper result |
| T8 | raw attention result returned to the wrapper |
| T9 | transpose/reshape/head merge (`attentionValues`) |
| T10 | output-gate input/result (`gate` and `gatedValues`) |
| T11 | `o_proj` input (`gatedValues`) |
| T12 | `o_proj` output (`attentionOutput`) |
| T13 | residual-added attention result (`postAttentionResidual`) |
| T14 | post-attention normalization/MoE input (`postAttentionInput`) |

The eight Q2.11 intermediates all remained exact against their independent
ordinary-operation fixture: expanded K, expanded V, raw QK, scaled scores,
masked scores, probabilities, Float32 P×V, and the BF16 helper output. The
model-level T0/T1/T2 operands and the complete cached K/V views were also
bit-identical to the independent Q2.10 boundary.

The prior `7.584503077329163e-05` comparison used the candidate expression
`trace.output.transposed(0,2,1,3).reshaped([1,4,4096])` in
`Tests/QwenStreamQ29LocalizationTests.swift` and compared it with the
independent source `fullAttention.attentionValues` tensor from
`/tmp/qwen35-k8-q29-sdpa-reference-focused.json`. The candidate checksum is
`4d539b2844e99f029b1bd3caa18201d081293ba99fcee7ccf049712c449b14e6`; the
independent checksum is
`8793209f20f95348940a167621467d34ec05ac3804e2ac4544fa9e0635d4e904`.
Q2.12 inverse-transposes the same oracle T9 value to compare at T7. The first
full-model comparable mismatch is therefore T7, relL2
`7.584503077329163e-05`, maxAbs `0.00390625`. T8–T14 remain defined but are
not promoted past this first mismatch.

A second model-level pass applied a DEBUG-only sentinel of `1.0` after the
explicit helper. The explicit trace itself stayed unchanged, while the
model's `attentionValues` matched the expected sentinelled tensor exactly;
this proves the candidate reaches downstream model data flow. The sentinel
is never supplied by production generation and is unavailable in Release
behavior.

The opt-in XCTest
`testOptInQ212ExplicitModelDataflowAndBoundaryProvenance` executed one case
with zero failures after its environment was injected through the
application-hosted test manifest. The first environment-free attempt is not
counted. Build-for-testing also passed, and `git diff --check` is clean for
the Qwen files. The backend remains **UNVALIDATED**; independent long-token,
router/state, and lifecycle gates are still open, and the 3 GiB pool
experiment remains paused.

**Q2.12 result: IMPLEMENTED — FIRST REMAINING DIVERGENCE: T7 P×V/SDPA boundary.**

## Q2.13 reference provenance reconciliation (2026-09-16)

Q2.13 reconciled the two existing layer-7/group-6 references without loading
the checkpoint or changing the production fused attention path. REFERENCE-A is
the Q2.11 Python ordinary-MLX explicit-operation package; REFERENCE-B is the
Q2.10 focused model-boundary capture produced by the pinned layer oracle. Their
Q/K/V and cached K/V inputs are byte-identical, and the compact B extraction is
byte-identical to its raw boundary source. Both references use layer 7,
prefill group 6, positions 24–27, cache lengths 24→28, GQA repeat 8, scale
0.0625 (`0x3d800000`), and the same Boolean causal mask.

The saved outputs differ because the producers end at different operations:
REFERENCE-A saves ordinary explicit P×V (T7) and its BF16 result, while
REFERENCE-B calls `mlx_lm.models.base.scaled_dot_product_attention` and saves
the post-helper transpose/reshape (T9). Replaying both input sets through the
same explicit MLX sequence in one fresh pinned process makes T7 BF16 and T9
bit-exact. The historical saved-output comparison remains valid as an
explicit-versus-fused kernel comparison: relL2
`7.584503077329163e-05`, maxAbs `0.00390625`. It is not evidence that either
reference has different model inputs or routing.

The versioned report is
`Tests/Fixtures/Qwen35-K8-Q2.13-reference-provenance-report.json` (15,660
bytes, SHA-256
`b478112ce799d34cf79bcf53050218e1f910fad3e0771788deb608dfe5da6a6b`). The
corrected authoritative explicit fixture is
`Tests/Fixtures/Qwen35-K8-Q2.13-authoritative-explicit-reference.json` (479,384
bytes, SHA-256
`2538cb6b64da12e89af7873538b8c86bc51789c72dd8b09fc44246a8899f8899`). The
producer is `Tools/QwenOracle/qwen35_q213_reference_provenance.py`; it records
the installed artifact revision `1e20fd8d42056f870933bf98ca6211024744f7ec`,
inventory SHA `0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592`,
and MLX 0.31.1 / Python 3.12.14 / Metal provenance.

The application-hosted opt-in test
`testOptInQ213ReferenceProvenanceReconciliation` executed one case with zero
failures (16.864 seconds). It verified the artifact and fixture metadata,
loaded the installed model, invoked the real diagnostic seam once explicitly
for layer 7/group 6, left 13 other calls fused, and matched native T7-F32, T7,
T8, and T9 exactly. Its optional native comparison report is
`/Users/m/Downloads/Qwen35-K8-Q2.13-native-comparison.json` (2,074 bytes,
SHA-256 `fa3a4985d8be2df43958e1cbc84500b518bba4fee5e8534837c8a4e11e57238f`).
The build-for-testing passed after a compile-only hash-representation fix.

This closes only the Q2.13 provenance contradiction. No layer-19 replay,
64-token/full-model parity run, cached-decode/state validation, lifecycle
matrix, pool experiment, performance run, or release build was started in
this phase. The production path remains fused and the backend remains
**UNVALIDATED**.

**Q2.13 result: REFERENCE PROVENANCE FIXED — EXPLICIT SWIFT MATCHES AUTHORITATIVE REFERENCE.**

## Q2.14 explicit full-attention candidate (2026-09-16)

Q2.14 wires a developer-only `referenceCompatibleExplicit` attention
strategy through the real native Qwen model loop. The production default is
unchanged: all normal generation continues to use the fused attention path.
The explicit candidate uses the existing ordinary-MLX-compatible sequence
from Q2.13 and is selected only by the opt-in diagnostic coverage test.

The full-attention layer list is derived from the installed `config.json` and
is `[3, 7, 11, 15, 19, 23, 27, 31, 35, 39]`. GatedDeltaNet layers are
unchanged. The native coverage run used seven four-token prefill calls and
one cached decode call; all 80 configured full-attention invocations used the
explicit candidate and zero used fused attention. It generated token `3010`
and ended at consumed position 29. The compact report is
`/Users/m/Downloads/Qwen35-K8-Q2.14-explicit-candidate-coverage.json` (542
bytes, SHA-256
`3795f81e4913944cb83b95b289eae3ab4616f78af50eaaa3444637f543e83696`). The
opt-in XCTest executed one case with zero failures in 12.701 seconds, and
the macOS build-for-testing passed.

The independent Python oracle now accepts `--attention-strategy explicit`,
records the explicit contract and config-derived full-attention indices in
its plan and fixture metadata, and has isolated real Metal workers for layers
3 and 7. Both workers completed under the one-layer guard with peak RSS of
about 724 MB. A guarded full explicit one-token attempt was stopped before
publication when free disk fell below the configured 3.75 GiB floor (last
sample 3.72 GiB); worker peak RSS was 689 MB, memory free was 44%, and swap
delta was zero. Its small scratch directory was removed. No independent full
fixture archive was produced, so no full-model token, router, state, cached
decode, qLen-1/qLen-4, layer-19/39, or lifecycle parity claim is made.

The Qwen checkpoint, official K=8 routing, shared expert, current 1,213-slot
pool, read limit, production fused path, model files, and dependencies are
unchanged. The 3 GiB pool experiment and all performance work remain paused.
Vampire Assistant remains **UNVALIDATED** pending an independently generated
explicit full-model fixture and native comparison.

**Q2.14 result: IMPLEMENTED — EXPLICIT FULL-ATTENTION CANDIDATE WIRED; FULL-MODEL VALIDATION STILL PENDING.**

## Q2.15 rolling disk-bounded oracle (2026-09-16)

The old Q2.14 guard value, `3,758,096,384` bytes, was an explicit free-disk
floor. Q2.14 did not capture a component ledger, so it cannot be interpreted
as cumulative bytes written or simultaneous occupancy. Q2.15 records that
classification and adds a derived peak plan with separate committed state,
one replacement state, bounded diagnostics, temporary worker output, atomic
metadata duplication, fixture/metadata, log, and safety-reserve categories.

The continuation is stored as `state-current` and `state-next`. Safetensors
and sidecars are written to temporary paths and atomically renamed; a worker's
stage directory is removed immediately after its result is committed. Layer
workers leave `state-current` untouched and the coordinator publishes a whole
prefill/decode boundary by swapping the replacement directory, so a cancelled
step cannot expose mixed old/new caches. The coordinator retains only one
compact current layer-result record, selected checkpoint summaries, and bounded
run metadata. Fresh runs refuse to overwrite existing continuation state. An
explicit `--resume` is available only for a matching
artifact/config/tokenizer/strategy at `prefill-boundary`, `prefill-head`, or
`decode-ready`, so an interrupted run cannot silently reuse a partial layer.

The rolling-only preflight for the installed artifact, 39-token prompt, and a
64-token output reservation was recalculated after the whole-boundary commit
change. It now reports:

- estimated simultaneous working output: `153,280,512` bytes;
- required free disk including the 512 MiB safety reserve: `690,151,424`
  bytes;
- free disk at the check: `4,872,507,392` bytes;
- admission: `true`.

A pre-fix one-token rolling smoke completed under the same policy and
observed a `67,371,347`-byte additional-output peak. It is retained only as
storage evidence because the later dispatch audit found that its
non-diagnostic worker used the fused default. Its 48,325-byte archive and
65.6 MB state directory were task-generated smoke outputs and were deleted
after the compact accounting record was saved at
`/Users/m/Downloads/Qwen35-K8-Q2.15-rolling-storage-smoke.json`. The smoke is
not a full-model parity fixture. The layer worker's explicit-strategy dispatch
was corrected and a direct non-component full-attention worker reported
`explicit ordinary MLX attention`. A post-fix rolling attempt was stopped at
a committed prefill boundary while correcting the output-limit decode
boundary; it published no fixture. A separate short synthetic post-fix rolling
smoke reached the explicit head and finalization with one generated token and
zero cached decode calls (`FULL_GATE_SHORT`); its compact 25,403-byte archive
was discarded after recording the result, so it is not a parity fixture. After
the transactional whole-boundary change, a real explicit coordinator smoke
was stopped after committing prefill group 1 at position 8 while the next
group was partial: `state-current` held 64,727,697 bytes and `state-next` held
6,472,637 bytes. No head or archive was published; the temporary state was
deleted after being recorded in the compact storage record (format-v2 SHA-256
`e9e14dea3a82d89af5ef7149b7d7a76c06f218bc7a374672c4859a8afa6d9b07`).

The primary explicit rolling run then passed its preflight and completed the
39-token prompt plus 40 cached decode-state boundaries. The next decode
reached layer 39 before its head/coordinator boundary, so the operator stopped
it to avoid an unattended hours-long isolated-worker run. Its last fully
recorded run-state contained 41 token IDs and 40 completed cached decode calls;
the system free-memory sample remained 54%, and no resource-guard abort or
archive publication occurred. The 67,075,040-byte rolling state was classified
as task-generated disposable output and removed after its compact progress was
recorded. This partial run is useful evidence that the rolling guard and state
format remain bounded, but it is not a 64-token correctness fixture.

The compact storage record was updated to format v2 (SHA-256
`2e33ff92d8c53498d7fe24b49ebbed0be1cbc859d2809d119a18f79ffdd0da1b`) and
records that the earlier `626,688,512`-byte preflight was based on a
single-layer replacement estimate. The current estimator includes the full
replacement continuation that coexists during the directory swap.

The dependency-free Q2.15 storage/resume suite executed five tests with zero
failures; Python compilation and the oracle self-test also passed. Full
explicit multi-token generation, native fixture comparison, and the lifecycle
gates have not yet run. The installed model, 1,213-slot pool, production fused
attention path, and app release artifact are unchanged. Vampire Assistant
remains **UNVALIDATED**, and the 3 GiB pool experiment remains paused.

**Q2.15 result: IMPLEMENTED — ROLLING DISK-BOUNDED ORACLE WIRED; FULL EXPLICIT VALIDATION STILL PENDING.**

## Q2.16 resume verification (2026-09-16)

The requested Q2.16 continuation could not be resumed. The Q2.15 partial
`/tmp/qwen35-k8-q215-primary-explicit-v5` state was intentionally classified
and deleted after its compact record was saved; no
`state-current/continuation-manifest.json`, hidden state, or 40 committed
layer caches remain. The compact record still contains the last metadata-only
observation (41 generated IDs and 40 cached-decode calls), but IDs and compact
summaries cannot reconstruct the tensor continuation.

The coordinator is now fail-closed: `--resume` on a missing continuation raises
an explicit error instead of starting at token zero. The check was covered by
the five-test storage/resume suite. No model, user file, native comparison,
fixture publication, lifecycle run, release build, or pool experiment was
started in Q2.16. The updated compact record is
`/Users/m/Downloads/Qwen35-K8-Q2.15-rolling-storage-smoke.json` (SHA-256
`5c2245d65362fd89d5acffa78143246058d31773483f2972ccea98712dbbb2f8`).

**Q2.16 result: BLOCKED — MISSING COMMITTED EXPLICIT ORACLE CONTINUATION STATE.**

## Q2.16 fresh explicit reference and native comparison (2026-09-16)

The Q2.15 continuation was genuinely absent, so the coordinator's fail-closed
resume guard was retained and a fresh run was used. The run was independent of
the Swift implementation, used `mlx-lm 0.31.1`/MLX `0.31.1` on Metal with
FP32 recurrent state, and verified the installed artifact revision
`1e20fd8d42056f870933bf98ca6211024744f7ec` and inventory SHA
`0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592`.

The compact reference is
`/Users/m/Downloads/Qwen35-K8-Explicit-Attention-Reference-v2.zip` (162,067
bytes, SHA-256
`cfc30f62bfe1352bb1ba5586949c908ae27e55cd0cd12ee518d0d038065eb66a`). It
contains no model data. Its 39-token prompt produced 64 IDs with
`output_limit`, 63 ordinary cached-decode calls, and no post-final probe. The
fixture retains sampled boundaries at `-1, 1, 2, 4, 8, 16, 32`; the recorded
final position `103` is the inclusive consumed-position convention, while the
last ordinary cache boundary is `102` after 63 calls.

The rolling guard estimated 153,280,512 bytes of simultaneous working output
and required 690,151,424 bytes including the 512 MiB reserve. Peak additional
output observed was 133,973,141 bytes; the bounded retained sample reached a
minimum free-disk observation of 6,065,115,136 bytes. The resource guard
passed with one layer worker at a time. Full coordinator memory/swap deltas
were not recorded and are not inferred from these disk values.

The real native target test executed directly against the rebuilt Debug app
bundle and passed in 33.727 seconds. It matched all 64 generated token IDs,
stop behavior, prompt IDs, and cached-call accounting. It recorded 730
explicit full-attention invocations and zero fused invocations: 73 per each
of layers `[3, 7, 11, 15, 19, 23, 27, 31, 35, 39]`, including 10 prefill
invocations and 63 qLen=1 cached calls per layer. All ten KV caches were
compared at every retained boundary, with early/middle/late GatedDeltaNet
cache sentinels; the predetermined shape/offset/relL2/maxAbs assertions
passed. The fixture's router records had zero true membership failures.

An independent full router capture at layer 19, position 46 matched the
native raw capture exactly: expert 61 logit `-4.125`, expert 245 logit
`-4.21875`, and selected IDs
`[61, 33, 71, 111, 43, 226, 211, 108]`. The reference raw capture is
`/tmp/Qwen35-K8-Q2.16-router-raw-v1/router-raw.json`; the native diagnostic
dump is `/tmp/q216-native-explicit-raw.json`. The older fused-reference
cutoff values were not used.

The opt-in reload lifecycle check also passed in 67.666 seconds: load,
generate, quiescence, double unload, reload, and the same 64-token fixture
completed with the pool idle and zero active reads. Targeted cancellation by
phase, switching to an installed lightweight model, and quit/relaunch
rediscovery were not executed in this phase, so the artifact remains
**UNVALIDATED**. The focused storage suite now executes six tests with zero
failures, and the focused Qwen XCTest classes executed 58 tests with 23
intentional skips and zero failures; the macOS build-for-testing passed. The
regular `xcodebuild test`
attempt that did not receive the opt-in environment was counted as skipped,
not as parity evidence. No 3 GiB pool experiment or new release archive was
started.

The compact evidence record is
`/Users/m/Downloads/Qwen35-K8-Q2.16-explicit-validation-report.json` (8,856
bytes, SHA-256
`3401b162befdef42e1a72cdfb9755a2decc36c4eaba8cd6942934542dd267037`).

**Q2.16 result: IMPLEMENTED — FULL EXPLICIT VALIDATION STILL PENDING.**

## Q2.17 explicit-path lifecycle closeout (2026-09-16)

Q2.17 used the accepted Q2.16 fixture without regenerating the oracle or
changing model math. The fixture is
`/Users/m/Downloads/Qwen35-K8-Explicit-Attention-Reference-v2.zip`, 162,067
bytes, SHA-256
`cfc30f62bfe1352bb1ba5586949c908ae27e55cd0cd12ee518d0d038065eb66a`.

The real streamed engine now exposes a developer-only lifecycle observer and
bounded queued-read counter. The normal runtime leaves both hooks unset. The
Q2.17 cancellation test executed one case with zero failures in 115.288
seconds and cancelled at deterministic phase boundaries:

- prefill: observed `prefill-group-start`, no streamed output, immediate
  eight-token recovery prefix matched the independent fixture;
- expert acquisition: observed `expert-reads-start:prefill` after resetting
  only the application expert pool, no streamed output, eight-token recovery
  matched;
- cached decode: observed 2,906 bounded lifecycle events after several decode
  calls, 10 output bytes before cancellation, and an eight-token recovery
  prefix that matched.

Each boundary asserted owner inactive, pool idle, execution leases zero,
queued reads zero, and active reads zero. The final recovery generated all 64
fixture IDs with 730 explicit calls and zero fused calls. The CoreData XPC
messages printed by direct `xctest` are host test-runner noise; the test
process exited successfully and no model crash occurred.

The real `EngineRouter`/`EnginePool` switch test executed one case with zero
failures in 68.489 seconds. Qwen loaded and produced a smoke response, the
installed `Qwen3.5-9B-abliterated-MLX-4bit` model loaded and produced a smoke
response, and switching back reconstructed Qwen under a one-resident-model
pool. The accepted 64-token fixture then matched again with 730 explicit and
zero fused calls; execution leases and reads were quiescent. No Qwen files
were removed or redownloaded.

Quit/relaunch was exercised with the built macOS app rather than the XCTest
host. The existing preference was temporarily set to the installed Qwen ID
for this controlled check and restored afterward. A fresh app process opened
the existing Application Support model files, a normal quit completed, and a
second fresh process rediscovered the same installed model and displayed
`Qwen3.5 35B A3B — SSD Streaming (Experimental)` as ready. The same fresh
process then ran the accepted fixture through the developer-only explicit
probe: 64/64 IDs, `output_limit`, 730 explicit calls, and zero fused calls.
The model registry, revision, and storage directory remained unchanged and no
download occurred.

The accepted portable parity test was rerun after the lifecycle instrumentation
and passed: 64/64 IDs, 63 cached calls, explicit 730, fused 0. The six-test
Q2.15 storage suite also passed. No pool enlargement, fused-attention change,
performance run, production switch, or public release rebuild was made.

**Q2.17 result: CORRECTNESS BASELINE VALIDATED — EXPLICIT ATTENTION PATH MATCHES INDEPENDENT REFERENCE.**

This qualification is scoped to the developer-only explicit execution path.
The existing fused user-facing path remains experimental/unvalidated, and the
next phase may compare it against this baseline without changing the current
pool or model contract.

## Q2.18 production attention strategy (2026-09-16)

Q2.18 kept the accepted Q2.16 fixture as immutable golden evidence and never
regenerated expected tokens from native execution. Weights, official K=8,
quantization, the router, the shared expert, the 1,213-slot pool, read
concurrency, the tokenizer/template, Thinking, sampling, the MLX pins,
GatedDeltaNet, and cache semantics were unchanged; only attention-strategy
selection varied. The 3 GiB pool experiment was not run.

Three strategies are now exposed — `productionFused`,
`referenceCompatibleExplicit`, `candidateHybrid` — resolved at one point,
`effective(queryLength:)`. The hybrid rule is `queryLength > 1 → explicit,
else → fused`, keyed to query length alone: no layer, position, prompt, or
expert whitelist. Every generation reports its requested strategy, its
effective strategies, and fused/explicit counts split into prefill and decode,
so a hybrid run cannot be mistaken for a pure one and there is no silent
fallback. Ordinary generation still picks one path before computing attention;
dual execution lives only in the diagnostic compatibility probe.

A bounded SDPA compatibility matrix was built from real production shapes
captured on a pure explicit trajectory across all ten full-attention layers:
head dim 256, 16 query heads, 2 KV heads, prefill `qLen ∈ {3, 4}` over
`kvLen` 4…39, and decode `qLen = 1` over `kvLen` 40…102. 190 entries were
measured for relL2, maxAbs, worst coordinate, and BF16 byte-identity — not
final-token equality. Mask semantics agreed on every entry, so the entire
difference is kernel numerics. Prefill was 0 of 100 byte-identical
(max relL2 3.4551e-04, maxAbs 0.031250). Decode was only 33 of 90
byte-identical (max relL2 1.9333e-04, maxAbs 0.00390625, one BF16 ULP). The
matrix is byte-reproducible across independent runs, and the historical Q2.10
case reproduced at layer 7 / `qLen=4` / `kvLen=28`.

The key hypothesis — that fused qLen=1 decode is clean, making explicit
prefill plus fused decode admissible — was tested directly and **failed**. A
teacher-forced replay of the golden prompt plus all 64 golden tokens ran
explicit-everywhere and hybrid on the same engine, consuming identical tokens.
The baseline was first anchored to the independent golden (18 comparisons, 0
membership failures) and was pure and fully instrumented (740 explicit, 0
fused). The hybrid resolved exactly as defined (100 explicit prefill, 640
fused decode, 0 of each in the wrong phase) and produced **450 true K=8
membership differences out of 2,560 comparisons**, 781 order-only differences,
2 predicted-token differences (first at index 20), and **0 of 9**
byte-identical layer-19 block outputs, with block relL2 compounding to
5.903e-02. Q2.6's M=1 quantized-matmul agreement does not transfer: SDPA is a
different primitive, and at head dim 256 the qLen=1 path dispatches to MLX's
fused vector kernel while qLen>1 falls back to ordinary ops with BF16 score
rounding.

Per section 10 no complicated hybrid was built — no per-layer or per-position
whitelist, no epsilon fallback, no router-aware rerun. Hybrid A was still run
against the golden for the record and diverged at generated index 21 with 4 of
21 sampled router memberships wrong, while the explicit arm reproduced 64/64
IDs with 0 of 21 failures. Greedy-stream equality was never treated as a
waiver, and here it did not even occur.

A 128-token native explicit control extension — labelled as such, not as
independent validation — showed the shipping fused path differing from the
validated baseline in **52 of 128 generated tokens** (first at index 76) with
11 of 93 sampled router memberships wrong. The pre-Q2.18 user-facing path was
therefore not merely unvalidated but demonstrably divergent on its own output.

On the one frozen benchmark (116 prompt tokens, 128 output, same checkpoint,
K=8, pool, reads 4, Thinking Off, greedy, same input hash) the explicit
baseline measured prefill 24.758 s, TTFT 24.783 s, decode 39.539 s at
3.212 tok/s, end-to-end 64.324 s at 1.990 tok/s, 33,060 hits / 32,862 misses
/ 31,649 evictions, 58,148,388,864 requested bytes fully completed over
32,862 application reads, and a 4,031,614,624-byte sampled process peak with
MLX peaking at 3.655 GB. The fused control under identical conditions measured
prefill 25.351 s, decode 36.509 s at 3.478 tok/s, end-to-end 61.890 s, and a
4,033,793,672-byte peak. It stays **UNVALIDATED** and is a performance control
only. A counterbalanced A → B → B → A session with unload, pool reset, and
reload between scored trials gave medians of 3.2469 versus 3.4154 decode tok/s
(fused +5.19%) and 64.414 versus 61.998 end-to-end seconds (fused +3.90%),
with fused using 5.67% *more* peak process memory. Within-arm spread was
smaller than the gap, so the effect is real — and irrelevant to promotion,
because fused failed correctness.

**Outcome C**: `referenceCompatibleExplicit` is now the Qwen production
default. Outcome D does not apply — explicit performance is not unacceptable.
The cost of correctness is +2.416 s end-to-end (+3.90%) and −0.168 decode
tok/s on a 128-token generation, with lower peak memory and a prefill that is
not slower in the frozen single-run benchmark. The unvalidated fused path was
not restored because it is faster. `StreamQwen35AttentionStrategy.productionDefault`
is the single source of truth and all 16 strategy default arguments, the
attention module's `callAsFunction`, the engine's stored property, and both
non-diagnostic-layer ternaries resolve through it, so nothing can silently
execute a strategy production does not. A unit test locks the decision. The
fused path is retained as a developer/diagnostic strategy and control, not
user-facing.

Lifecycle regression ran against the winning strategy and, because every
cancellation phase drives `engine.stream()`, against the shipping default
itself — asserted, not assumed. Prefill, expert-acquisition, and cached-decode
cancellations each recovered an eight-token prefix matching the golden and
then all 64 IDs with 730 explicit and 0 fused calls; unload/reload passed in
63.964 s with the pool quiescent; the `EnginePool(maxResident: 1)` switch to
`Qwen3.5-9B-abliterated-MLX-4bit` and back passed in 42.160 s with 64/64; a
fresh process opened the existing shards, quit normally in 1 s, and a second
fresh process rediscovered the same install with no download. The post-relaunch
fixture passed on both the Debug app and the **Release binary** (64/64,
`output_limit`, explicit 730, fused 0). Owner, leases, pins, queued reads, and
active reads were clean at every boundary. Preferences were restored
byte-for-byte and the model directory, registry, and revision were untouched.

Focused regressions passed: 6 Q2.18 unit tests, 5 opt-in model tests, the
accepted golden parity rerun (64/64, 63 cached calls, explicit 730, fused 0,
33.265 s), twelve Qwen XCTest classes with zero failures, the six-test Q2.15
storage suite, and the bounded-oracle self-test. The broad suite ran 1,041
tests with 44 skips and 2 failures, both pre-existing and unrelated to
attention: the OLED appearance assertion Q2.17 already recorded, and a
chat-only composer prompt assertion broken by earlier uncommitted
`PromptBuilder.leanPrompt` work whose files predate this phase and whose test
uses `FakeLLMEngine` with `ModelCatalog.all.first`. Attention-related
failures: zero.

Release built and packaged. `codesign --verify --deep --strict` passed on the
built app and on the app extracted from the ZIP; hardened runtime is present.
The artifact is
`/Users/m/Downloads/beetcode/BeetCode/dist/Vamp-Assistant-Qwen-Streaming-VALIDATED-build93-q2.18.zip`,
20,772,039 bytes, SHA-256
`1a07a7c3e316fc040404c5fbf30667a83c869b5d892cabad89cc96e82fde5af6`. Signing is
the existing Apple Development identity; notarization was not performed and is
not claimed. The compact evidence record is
`/Users/m/Downloads/Qwen35-K8-Q2.18-attention-strategy-report.json`, 25,886
bytes, SHA-256
`0bfdaaeb5efb6dab3c11e8820ae69f4df41d05c2e79d5a605f6c9d570aacf158`.

User-facing Qwen may now be described as **VALIDATED AGAINST PINNED QUANTIZED
QWEN3.5-35B-A3B K=8 MLX 0.31.1 METAL EXPLICIT-ATTENTION REFERENCE**, scoped to
64 generated token IDs, 63 cached-decode calls, 730 explicit invocations, zero
fused invocations, and zero true K=8 router membership failures on one host
class, plus the lifecycle gates. This is not official Qwen certification, not
BF16 equivalence, not cross-version equality, and not universal hardware
validation. Independent coverage ends at 64 generated tokens.

Q2.19 may now resume the expert-cache capacity experiment (1,213 slots versus
1,819; offline simulation predicted 50.2% → 62.0% hit rate, 32,981 → 25,158
misses, 58.359 GB → 44.516 GB requested). A second requirement is now
evidenced alongside it: a performant correctness-compatible attention kernel,
since recovering the 5.19% fused decode margin requires a kernel that matches
the explicit reference rather than a routing whitelist.

**Q2.18 result: PRODUCTION VALIDATED — EXPLICIT ATTENTION.**
