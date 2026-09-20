# Qwen3.5 K=8 independent oracle

This directory contains development-only independent oracles for the installed
`mlx-community/Qwen3.5-35B-A3B-4bit` artifact. They are deliberately separate
from Vampire Assistant and never import the app's Swift or native streaming
implementation.

The original full-model producer remains available for an off-host run. The
16 GB M4 path is validated in stages by `qwen35_k8_layer_oracle.py`: it never
calls `mlx_lm.load`, never constructs the 40-layer model, reads only one
layer's Safetensors ranges, and exits its worker before another layer starts.
Its full fixture coordinator traverses the prompt in the app's four-token
prefill groups and then runs cached decode one token at a time, carrying each
layer's continuation state through the worker boundary. The resulting fixture
is an independent correctness input, not a production inference path or a
performance benchmark; native comparison must still pass before the backend
can be called validated.

The Q2.15 full coordinator uses `--disk-policy rolling` to keep one committed
continuation (`state-current`) and one whole-boundary replacement
(`state-next`). Worker
directories are removed after each committed boundary, and only compact
checkpoint metadata is retained. The preflight derives recurrent, convolution,
KV, hidden, temporary, metadata, fixture, and safety-reserve bytes from the
installed config. It does not treat historical stage output or requested range
reads as simultaneous disk occupancy. A previous run is never overwritten
implicitly; `--resume` is opt-in and is accepted only at a committed
`prefill-boundary`, `prefill-head`, or `decode-ready` boundary with a matching artifact/config/
tokenizer/strategy manifest.

Q2.16 resume is deliberately fail-closed: `--resume` on a missing
`state-current/continuation-manifest.json` or a manifest with no committed
state raises an error instead of silently starting token zero. The prior
partial state was deleted after its compact evidence was saved, so a new
64-token reference must be generated only after an explicit decision to start
a fresh run.

## Q2.16 completed reference

The fresh, resource-guarded explicit Metal run produced
`/Users/m/Downloads/Qwen35-K8-Explicit-Attention-Reference-v2.zip` (162,067
bytes, SHA-256
`cfc30f62bfe1352bb1ba5586949c908ae27e55cd0cd12ee518d0d038065eb66a`). It
contains no checkpoint data. The primary fixture has 64 generated IDs and 63
ordinary cached-decode calls; the native target comparison must supply
`BEETCODE_QWEN35_ORACLE_FIXTURE` and use the explicit diagnostic strategy.
The independent raw router capture for layer 19, position 46 is retained at
`/tmp/Qwen35-K8-Q2.16-router-raw-v1/router-raw.json` and is diagnostic only.

## Pinned environment

Create a disposable virtual environment and install the exact lock:

```sh
python3.13 -m venv .venv-qwen35-oracle
.venv-qwen35-oracle/bin/python -m pip install --upgrade pip
.venv-qwen35-oracle/bin/python -m pip install -r Tools/QwenOracle/requirements.lock
```

The fixture records Python, macOS, MLX, mlx-lm, model, tokenizer, config,
template, and artifact-inventory identities. The script hashes the pinned
model files in streaming chunks and refuses a different artifact.

## Generate and self-check fixtures

Copy or download the exact pinned model directory onto the Oracle Host; do
not copy the resulting checkpoint back to the Target Host. Then run:

```sh
.venv-qwen35-oracle/bin/python Tools/QwenOracle/qwen35_k8_oracle.py \
  --model-dir "$HOME/Library/Application Support/BeetCode/Models/qwen3.5-35b-a3b-streaming-4bit" \
  --output-dir "$TMPDIR/qwen35-k8-oracle-v1" \
  --archive "$PWD/Qwen35-K8-Oracle-Fixtures-v1.zip"
```

The command renders synthetic prompts with the pinned Qwen chat template,
uses Thinking Off and greedy sampling, runs each fixture twice, and refuses
to publish if generated IDs, router IDs, positions, or stop behavior differ.
The primary fixture requires at least 64 generated tokens. The archive
contains only `manifest.json`, compact JSON fixture snapshots, and a README;
it contains no model shards and should remain well below 1 GiB.

Record the printed archive size and SHA-256. Transfer only the archive to the
Target Host. The Target Host test harness accepts either the extracted
directory or the ZIP path through `BEETCODE_QWEN35_ORACLE_FIXTURE`.

The fixture is a golden semantic input, not a performance benchmark. Do not
change K, the expert pool, routing, quantization, or native scheduling while
using it.

## Single-Mac layer-isolated proof

Use the same pinned environment and the installed model directly. The first
command is metadata-only and reads Safetensors headers without loading tensor
payloads:

```sh
/tmp/qwen35-mlx0311-op-v1/bin/python Tools/QwenOracle/qwen35_k8_layer_oracle.py \
  --mode estimate \
  --verify-artifact \
  --output-dir "$TMPDIR/qwen35-k8-layer-plan"
```

The actual worker proof runs one linear-attention layer and one full-attention
layer serially, with one worker, a 1.75 GiB RSS ceiling, a 512 MiB swap-delta
ceiling, and a 10 GiB free-disk floor:

```sh
.venv-qwen35-oracle/bin/python Tools/QwenOracle/qwen35_k8_layer_oracle.py \
  --mode layers \
  --output-dir "$TMPDIR/qwen35-k8-layer-proof"
```

The process-boundary serialization check is separate and must pass before a
coordinator may use saved continuation state:

```sh
.venv-qwen35-oracle/bin/python Tools/QwenOracle/qwen35_k8_layer_oracle.py \
  --mode serialization \
  --output-dir "$TMPDIR/qwen35-k8-layer-serialization"
```

The tool records the pinned artifact identity, exact layer byte plan, range
read totals, process peak RSS, free-memory percentage, swap delta, and bounded
state/output summaries. The full-model coordinator retains the same
single-worker/resource policy, restores full-attention offsets from each saved
state sidecar, and records recurrent `ArraysCache` offsets as zero, matching
the upstream cache types rather than treating every cache as a KV position
counter.

To generate the compact target-host primary fixture after the estimate, layer,
and serialization gates pass:

```sh
.venv-qwen35-oracle/bin/python Tools/QwenOracle/qwen35_k8_layer_oracle.py \
  --mode full \
  --verify-artifact \
  --output-dir "$TMPDIR/qwen35-k8-layer-full" \
  --archive "$TMPDIR/Qwen35-K8-Layer-Isolated-v1.zip" \
  --max-output 64
```

The archive is valid only when the command reports `FULL_GATE_COMPLETE`; it
contains compact IDs and summaries, never model shards. Supply that archive to
the target-side opt-in comparison with
`BEETCODE_QWEN35_ORACLE_FIXTURE=/path/to/archive.zip`.

## Router selector replay

Q2.5 boundary runs can retain complete layer-0 router tensors without saving
model data. Replay the exact pinned MLX selector against the reference and
native JSON outputs:

```sh
.venv-qwen35-oracle/bin/python Tools/QwenOracle/qwen35_router_replay.py \
  --reference /path/to/reference/boundary.json \
  --native /path/to/native-boundary.json \
  --output /tmp/qwen35-router-replay.json
```

The result reports selected-set equality, order-only differences, K/K+1
margins, and whether each side's MLX replay matches its recorded K=8 route.
It reads only the bounded router summaries and never loads the checkpoint.

For the Q2.5 saved-input replay, pass the complete raw BF16 router rows. This
keeps the selector test independent of native arithmetic and distinguishes a
changed router input/logit from a selector or cache-key defect:

```sh
.venv-qwen35-oracle/bin/python Tools/QwenOracle/qwen35_router_replay.py \
  --reference /tmp/qwen35-k8-q25-boundary-primary-router-full-v1/boundary.json \
  --native /tmp/qwen35-k8-q25-boundary-primary-native-router-audit-v2.json \
  --selector-fixture /tmp/qwen35-k8-q25-selector-input-v6.json \
  --native-selector-output /tmp/qwen35-k8-q25-selector-native-v3.json \
  --output /tmp/qwen35-k8-q25-router-replay.json
```

The replay fixture contains a control row and the two layer-0 boundary rows,
with the exact `[1, 1, 256]` BF16 router logits and `[1, 1, 2048]` BF16
inputs. The current captured run has 39 positions: every reference and native
row reproduces its own recorded K=8 set, six rows differ only in undefined
`argPartition` order, and two rows change membership at the K/K+1 boundary
(position 2: expert 72 versus 86; position 7: expert 163 versus 30). The
same-input replay agrees on both sets and orders, and the native quantized gate
projection agrees with the reference input within the existing tolerance.
These results localize the mismatch to upstream cross-runtime router-input /
logit drift; they do not establish full-model parity or authorize a pool
change.

## Quantized operator replay

Q2.6 can isolate one native quantized projection without loading a second
checkpoint.  The fixture producer reads only layer-0
`linear_attn.in_proj_qkv` and the two captured four-token activation groups;
the archive contains raw U32 weights, BF16 scales/biases, inputs, and saved
native/reference outputs, never model shards:

```sh
python3 Tools/QwenOracle/qwen35_qkv_operator_replay.py \
  --mode create \
  --model-dir "$HOME/Library/Application Support/BeetCode/Models/qwen3.5-35b-a3b-streaming-4bit" \
  --reference-boundary /tmp/qwen35-k8-q26-activation-reference/boundary.json \
  --native-boundary /tmp/qwen35-k8-q26-native-boundary.json \
  --output-dir /tmp/qwen35-k8-q26-qkv-operator \
  --archive /tmp/Qwen35-K8-QKV-Operator-v1.zip
```

The same fixture can be replayed by Python MLX 0.31.1 and 0.32.2, with the
effective device recorded explicitly:

```sh
python Tools/QwenOracle/qwen35_qkv_operator_replay.py \
  --mode run --fixture-dir /tmp/qwen35-k8-q26-qkv-operator \
  --device metal --runtime-label python-mlx-core-0.31.1-metal \
  --output /tmp/qkv-python-0311.json
```

The opt-in XCTest `testOptInQwenK8QKVOperatorReplay` is the native A/B leg:
A is the production Vampire Assistant wrapper and B is direct Swift MLX
`quantizedMM` over the fixture bytes.  Set
`BEETCODE_QWEN35_Q26_QKV_OPERATOR=1`,
`BEETCODE_QWEN35_Q26_QKV_FIXTURE`, and optionally
`BEETCODE_QWEN35_Q26_QKV_OUTPUT` to run it.  Complete M=4 cases are the
primary matrix; `--tokens 1` is available for a follow-up M=1 dispatch check
after the matched-shape comparison.

## Layer-0 activation localization

The Q2.6 diagnostic boundary can retain complete BF16 values for the first
two four-token groups without retaining model weights. Generate the independent
boundary with `--capture-full-components --boundary-max-groups 2`, run the
opt-in native test with `BEETCODE_QWEN35_Q25_ACTIVATION_TRACE=1`, and export
the native boundary through `BEETCODE_QWEN35_Q25_NATIVE_OUTPUT`. Compare the
two bounded files with:

```sh
python3 Tools/QwenOracle/qwen35_activation_compare.py \
  --reference /tmp/qwen35-k8-q26-activation-reference/boundary.json \
  --native /tmp/qwen35-k8-q26-native-boundary.json \
  --output /tmp/qwen35-k8-q26-activation-comparison.json
```

The report compares the A-G pre-router boundaries and the layer-0
linear-attention subpath (`qkv`, `z`, `b`, `a`, convolution, normalization,
gated update, output normalization, and projection). It consumes only the
saved activation values, reports norms, relative L2, maximum absolute error,
and the worst coordinate, and never loads a checkpoint or changes inference.

## Q2.7 matched-core full-model gate

The native app links the MLX 0.31.1 core even though the earlier CPU oracle
used MLX 0.32.2. For the final K=8 correctness gate, use the disposable
environment containing `mlx==0.31.1`, `mlx-metal==0.31.1`, and
`mlx-lm==0.31.1`, and keep the one-layer worker/resource guard enabled:

```sh
/tmp/qwen35-mlx0311-op-v1/bin/python Tools/QwenOracle/qwen35_k8_layer_oracle.py \
  --mode full --device metal --verify-artifact \
  --model-dir "$HOME/Library/Application Support/BeetCode/Models/qwen3.5-35b-a3b-streaming-4bit" \
  --output-dir /tmp/qwen35-k8-q27-matched-core-full-v1 \
  --archive /tmp/Qwen35-K8-Matched-Core-v1.zip \
  --max-output 64 --max-rss-bytes 1879048192 \
  --max-swap-delta-bytes 536870912 --min-free-memory-percent 10 \
  --min-free-disk-bytes 10737418240 \
  --fixture-format-version qwen35-k8-matched-core-v1 \
  --runtime-label python-mlx-core-0.31.1-metal
```

The archive contains compact token IDs, selected router records, cache/state
summaries, and checkpoint identities only; it contains no model shards. The
matched-core runner uses an independent Python Metal gated-delta kernel with
the same MLX 0.31.1 launch contract as Swift, including FP32 recurrent state;
the older CPU ops-loop archive is not a Q2.7 parity oracle. Set
`BEETCODE_QWEN35_Q27_MATCHED_CORE_FIXTURE` to that archive when running the
opt-in `QwenStreamOracleFixtureTests` comparison. The matched-core manifest
must report Metal, MLX 0.31.1, MLX-LM 0.31.1, the pinned artifact inventory,
and official routed K=8. A successful fixture is required before any larger
expert-pool experiment; this fixture does not change the production pool or
model scheduling.

The retained matched-core package is `~/Downloads/Qwen35-K8-Matched-Core-v3.zip`
(184,367 bytes, SHA-256
`a1ee403e54fdcd496482bd4af972eebef553d20160b8a721bf2f55f299d53777`). It
produced 64 deterministic tokens and passed the resource guard. The native
comparison matched all 64 token IDs and cache positions, but found one sampled
K=8 membership change at layer 19 / position 46 (`61` in the reference versus
`245` natively); six equal-set order permutations are logged separately. The
backend therefore remains unvalidated and the pool experiment stays blocked.

## Q2.8 cutoff-tie classification

Q2.8 captures one raw router row from the independent MLX 0.31.1 Metal oracle
and one native streamed run at layer 19 / absolute position 46. The compact
fixture is `/Users/m/Downloads/Qwen35-K8-Q2.8-cutoff-tie.json`; it contains
only router inputs, logits, selector scores, selected IDs, and exact BF16
words. The accompanying report is
`/Users/m/Downloads/Qwen35-K8-Q2.8-tie-report.json`.

Run the selector-only analysis without loading the checkpoint:

```sh
/tmp/qwen35-mlx0311-op-v1/bin/python Tools/QwenOracle/qwen35_q28_tie.py \
  --fixture /Users/m/Downloads/Qwen35-K8-Q2.8-cutoff-tie.json \
  --output /Users/m/Downloads/Qwen35-K8-Q2.8-tie-report.json
```

The diagnostic can also compare the two disputed quantized expert bundles on
the saved native MoE input. This is bounded to one layer and diagnostic only;
it does not alter production routing:

```sh
/tmp/qwen35-mlx0311-op-v1/bin/python Tools/QwenOracle/qwen35_q28_tie.py \
  --fixture /Users/m/Downloads/Qwen35-K8-Q2.8-cutoff-tie.json \
  --model-dir "$HOME/Library/Application Support/BeetCode/Models/qwen3.5-35b-a3b-streaming-4bit" \
  --probe-experts \
  --output /Users/m/Downloads/Qwen35-K8-Q2.8-tie-report.json
```

The reference selector has seven scores strictly above the cutoff and one
exact cutoff ID, `{61}`. Its selector BF16 words are expert 61 `0x3c7b`
(`0.01531982421875`) and expert 245 `0x3c6b`
(`0.01434326171875`). The native selector also has seven strictly greater
IDs, but its exact cutoff class is `{61, 245}`; both words are `0x3c72`
(`0.0147705078125`). Both Python MLX and the direct Swift MLX replay were
deterministic for 16 executions and reproduced their captured sets. Since the
reference candidates are non-tied at the actual selector dtype, this is not an
allowed cross-runtime cutoff-tie equivalence. The strict K=8 comparison must
remain a router failure; no epsilon, stable sort, K change, dependency change,
or pool experiment is justified.

## Q2.14 explicit full-attention reference candidate

The oracle supports a developer-only ordinary-MLX-compatible attention
candidate for provenance and parity work. It does not change the production
Vampire Assistant path, which remains on fused attention. The candidate is
selected with `--attention-strategy explicit`; the default remains
`--attention-strategy fused`.

The candidate derives the full-attention layer indices from the installed
`config.json` and records them in the plan and fixture metadata. For the
pinned Qwen3.5-35B-A3B artifact the indices are
`[3, 7, 11, 15, 19, 23, 27, 31, 35, 39]`. GatedDeltaNet layers continue to
use their normal upstream path.

Generate the independent explicit reference on a machine that passes the
resource guard. The model directory must exist on that machine; this command
does not copy or repack the checkpoint. The target host's pinned environment
is `/tmp/qwen35-mlx0311-op-v1`:

```sh
/tmp/qwen35-mlx0311-op-v1/bin/python Tools/QwenOracle/qwen35_k8_layer_oracle.py \
  --mode full --device metal --verify-artifact \
  --attention-strategy explicit \
  --fixture-format-version qwen35-k8-explicit-attention-reference-v1 \
  --runtime-label python-mlx-core-0.31.1-metal-explicit-q214 \
  --model-dir "$HOME/Library/Application Support/BeetCode/Models/qwen3.5-35b-a3b-streaming-4bit" \
  --output-dir "$TMPDIR/qwen35-k8-explicit-attention-reference-v1" \
  --archive "$TMPDIR/Qwen35-K8-Explicit-Attention-Reference-v1.zip" \
  --max-output 64 \
  --max-rss-bytes 1879048192 \
  --max-swap-delta-bytes 536870912 \
  --min-free-memory-percent 10 \
  --min-free-disk-bytes 3758096384
```

Accept the archive only when both independent self-validation passes finish
and agree. Transfer only the compact fixture archive and its verification
records to the target Mac; never transfer a second checkpoint copy. The
full-archive importer/comparison gate is still pending because this target
host did not publish the archive. The currently available coverage-only run
is exercised with `BEETCODE_QWEN35_Q214=1` and writes its compact report to
the path in `BEETCODE_QWEN35_Q214_OUTPUT`.

The current target-host attempt completed isolated real Metal workers for
layers 3 and 7 but the guarded full run stopped at the 3.75 GiB free-disk
floor before publishing an archive. That is a resource boundary, not a
full-model parity result. Keep the backend UNVALIDATED and do not start the
3 GiB expert-pool experiment until the independent fixture comparison and
lifecycle gates pass.

## Q2.15 rolling disk-bounded explicit reference

Q2.15 replaces the unattributed Q2.14 free-disk floor with a peak-aware
rolling policy. The old `3,758,096,384`-byte value remains visible in each
plan as an explicit admission floor, but Q2.14 did not record enough component
data to call it cumulative output or simultaneous occupancy. The new plan
separates the committed continuation, one whole-boundary replacement, compact
diagnostics, temporary worker output, atomic-write duplicate,
fixture/metadata overhead, build log, and safety reserve. Historical stage
directories are deleted after their result is committed, and writes use a
temporary file followed by an atomic rename. Layer workers write only below
`state-next`; the directory swap is the commit point, preventing a partial
layer from being mistaken for a resumable state. Resume accepts
`prefill-boundary`, `prefill-head`, and `decode-ready` records only.

Use the rolling preflight before a full run:

```sh
/tmp/qwen35-mlx0311-op-v1/bin/python Tools/QwenOracle/qwen35_k8_layer_oracle.py \
  --mode estimate \
  --device metal \
  --attention-strategy explicit \
  --disk-policy rolling \
  --verify-artifact \
  --model-dir "$HOME/Library/Application Support/BeetCode/Models/qwen3.5-35b-a3b-streaming-4bit" \
  --output-dir "$TMPDIR/qwen35-q215-disk-plan" \
  --max-output 64
```

On the target M4 at the recorded 39-token prompt, the 64-token reservation
estimated 153,280,512 bytes of simultaneous working output and required
690,151,424 bytes including the 512 MiB safety reserve. This corrected plan
includes the full replacement continuation held during the directory swap; the
earlier 626,688,512-byte figure used only the largest single-layer replacement.
The observed free disk
was 4,872,507,392 bytes and the plan admitted the run. A pre-fix one-token
rolling smoke completed with a 67,371,347-byte observed additional-output
peak; it is retained only as storage evidence because the later dispatch audit
found that its non-diagnostic worker used the fused default. Its archive was
discarded because it was `FULL_GATE_SHORT`, not a full parity fixture. The
compact accounting record is
`/Users/m/Downloads/Qwen35-K8-Q2.15-rolling-storage-smoke.json`.

The layer worker now forwards `--attention-strategy explicit` even without
component capture; focused layer workers reported ordinary explicit MLX
attention in the direct non-component worker. This prevents a fused worker
from being mistaken for an explicit reference. A post-fix short synthetic
rolling smoke reached the explicit head and finalization with one generated
token and zero cached decode calls, confirming the corrected N-versus-N−1
boundary; it was still `FULL_GATE_SHORT` and its archive was discarded. An
earlier post-fix long-prompt attempt was stopped at a committed prefill
boundary and also published no fixture. A real post-transaction smoke was
stopped after committing prefill group 1 at position 8 while the next group
was partial, leaving the committed state intact; it published no fixture. The
pure accounting/resume regression suite runs five tests. Full explicit
multi-token generation and native comparison remain pending, so Vampire
Assistant stays **UNVALIDATED** and no
pool or production attention change is authorized.

## Q2.16 resume guard

The Q2.15 partial continuation was deleted after its compact evidence was
recorded, so the 64-token explicit fixture cannot be resumed from that run.
The coordinator deliberately fails closed when `--resume` is supplied without
`state-current/continuation-manifest.json` and committed state; it never
silently restarts token zero. Generate a fresh independent run only after an
explicit operator decision. Vampire Assistant remains **UNVALIDATED** until a
complete fixture and native comparison exist.
