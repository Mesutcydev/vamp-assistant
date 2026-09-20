#!/usr/bin/env python3
"""Memory-bounded, development-only Qwen3.5 K=8 oracle.

This tool deliberately uses one short-lived mlx-lm process per stage.  A
stage either builds the prompt cache or advances it by one token, then writes
only the cache state and bounded diagnostic summaries.  The parent process
monitors the child and aborts before a resource failure can become a kernel
watchdog event.

The script is not part of the application and must never be used as an app
runtime.  It expects a separate environment containing the pinned
mlx-lm==0.31.1 and mlx==0.32.2 packages.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any


ARTIFACT_REVISION = "1e20fd8d42056f870933bf98ca6211024744f7ec"
DEFAULT_MODEL = Path(
    "/Users/m/Library/Application Support/BeetCode/Models/"
    "qwen3.5-35b-a3b-streaming-4bit"
)
DEFAULT_PROMPT_IDS = [
    7734, 220, 18, 15, 47193, 14542, 10104, 364, 17845, 3061,
    14246, 24350, 13, 8618, 11220, 1902, 6435, 6681, 1330, 4434,
    22157, 321, 2830, 264, 13769, 3010, 13,
]
SELECTED_LAYERS = (0, 19, 39)
EOS_IDS = {248044, 248046}
GIB = 1024**3


class ResourceGuardAbort(RuntimeError):
    """Raised when the parent observes an unsafe reference condition."""


def json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True))
    temporary.replace(path)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def free_bytes(path: Path) -> int:
    stat = os.statvfs(path)
    return stat.f_bavail * stat.f_frsize


def fixture_bytes(path: Path) -> int:
    total = 0
    if not path.exists():
        return total
    for root, _, names in os.walk(path):
        for name in names:
            try:
                total += (Path(root) / name).stat().st_size
            except FileNotFoundError:
                pass
    return total


def process_rss_bytes(pid: int) -> int | None:
    try:
        raw = subprocess.check_output(
            ["/bin/ps", "-o", "rss=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return int(raw.split()[0]) * 1024 if raw else None
    except (OSError, ValueError, subprocess.CalledProcessError):
        return None


def memory_free_percent() -> float | None:
    try:
        output = subprocess.check_output(
            ["/usr/bin/memory_pressure", "-Q"],
            text=True,
            stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    match = re.search(r"free percentage:\s*([0-9]+(?:\.[0-9]+)?)%", output)
    return float(match.group(1)) if match else None


def swap_used_bytes() -> int | None:
    try:
        output = subprocess.check_output(
            ["/usr/sbin/sysctl", "-n", "vm.swapusage"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    match = re.search(r"used\s*=\s*([0-9.]+)([KMGTP])", output)
    if not match:
        return None
    scale = {"K": 1024, "M": 1024**2, "G": GIB, "T": GIB**2, "P": GIB**3}
    return int(float(match.group(1)) * scale[match.group(2)])


def prompt_hash(token_ids: list[int]) -> str:
    return hashlib.sha256(str(token_ids).encode("utf-8")).hexdigest()


def installed_version(distribution: str, module: Any) -> str:
    """Read a pinned distribution version without retaining model state."""
    try:
        return importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        return str(getattr(module, "__version__", "unknown"))


class ChildGuard:
    """Run one helper while sampling bounded system/process state."""

    def __init__(
        self,
        process: subprocess.Popen[str],
        fixture_root: Path,
        timeout: float,
        max_rss: int,
        min_free_disk: int,
        max_fixture_bytes: int,
        max_swap_delta: int,
    ) -> None:
        self.process = process
        self.fixture_root = fixture_root
        self.timeout = timeout
        self.max_rss = max_rss
        self.min_free_disk = min_free_disk
        self.max_fixture_bytes = max_fixture_bytes
        self.max_swap_delta = max_swap_delta
        self.started = time.monotonic()
        self.swap_baseline = swap_used_bytes()
        self.peak_rss = 0
        self.samples: list[dict[str, Any]] = []
        self.reason: str | None = None

    def sample(self) -> dict[str, Any]:
        rss = process_rss_bytes(self.process.pid)
        if rss is not None:
            self.peak_rss = max(self.peak_rss, rss)
        swap = swap_used_bytes()
        sample = {
            "elapsedSeconds": time.monotonic() - self.started,
            "rssBytes": rss,
            "peakRSSBytes": self.peak_rss,
            "memoryFreePercent": memory_free_percent(),
            "swapUsedBytes": swap,
            "swapDeltaBytes": (
                swap - self.swap_baseline
                if swap is not None and self.swap_baseline is not None
                else None
            ),
            "freeDiskBytes": free_bytes(self.fixture_root),
            "fixtureBytes": fixture_bytes(self.fixture_root),
        }
        # Keep only a bounded record.  The diagnostic report needs resource
        # extrema, not a growing per-second history.
        if len(self.samples) < 256:
            self.samples.append(sample)
        return sample

    def check(self, sample: dict[str, Any]) -> None:
        rss = sample.get("rssBytes")
        if rss is not None and rss > self.max_rss:
            raise ResourceGuardAbort(
                f"reference RSS {rss} exceeds {self.max_rss} bytes"
            )
        free_disk = sample.get("freeDiskBytes")
        if free_disk is not None and free_disk < self.min_free_disk:
            raise ResourceGuardAbort(
                f"free disk {free_disk} is below {self.min_free_disk} bytes"
            )
        fixture_size = sample.get("fixtureBytes")
        if fixture_size is not None and fixture_size > self.max_fixture_bytes:
            raise ResourceGuardAbort(
                f"fixture bytes {fixture_size} exceed {self.max_fixture_bytes} bytes"
            )
        free_percent = sample.get("memoryFreePercent")
        if free_percent is not None and free_percent < 10:
            raise ResourceGuardAbort(
                f"system memory free percentage {free_percent} is critical"
            )
        swap_delta = sample.get("swapDeltaBytes")
        if swap_delta is not None and swap_delta > self.max_swap_delta:
            raise ResourceGuardAbort(
                f"swap increased by {swap_delta} bytes during one stage"
            )

    def wait(self) -> tuple[int, dict[str, Any]]:
        while self.process.poll() is None:
            if time.monotonic() - self.started > self.timeout:
                self.reason = f"stage timeout after {self.timeout:.1f}s"
                raise ResourceGuardAbort(self.reason)
            sample = self.sample()
            self.check(sample)
            time.sleep(1.0)
        final = self.sample()
        self.check(final)
        return self.process.returncode or 0, final


def terminate_child(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def helper_summary(array: Any, sample_count: int = 16) -> dict[str, Any] | None:
    if array is None:
        return None
    import mlx.core as mx

    mx.eval(array)
    flat = array.reshape(-1)
    count = min(sample_count, flat.size)
    sample = [float(value) for value in flat[:count].tolist()]
    return {"shape": list(array.shape), "dtype": str(array.dtype), "sample": sample}


def helper_cache_summary(cache: list[Any], position_after: int) -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    for layer_index in SELECTED_LAYERS:
        item = cache[layer_index]
        state = item.state
        arrays = [state] if not isinstance(state, (list, tuple)) else list(state)
        summaries.append(
            {
                "layer": layer_index,
                "type": type(item).__name__,
                "offset": int(getattr(item, "offset", position_after) or position_after),
                "state": [helper_summary(array) for array in arrays],
            }
        )
    return summaries


def run_helper(args: argparse.Namespace) -> int:
    """Execute exactly one independent reference stage."""
    # Imports are intentionally inside the child role.  The parent and its
    # guard remain usable even when the pinned development environment is not
    # installed, and the parent never holds MLX allocator state.
    import mlx.core as mx
    import mlx_lm
    from mlx_lm import load
    from mlx_lm.models.cache import load_prompt_cache, save_prompt_cache
    from mlx_lm.models.qwen3_next import (
        Qwen3NextDecoderLayer,
        Qwen3NextSparseMoeBlock,
    )

    mx.set_default_device(mx.cpu)
    mlx_version = installed_version("mlx", mx)
    mlx_lm_version = installed_version("mlx-lm", mlx_lm)
    if str(mlx_version) != "0.32.2" or str(mlx_lm_version) != "0.31.1":
        raise RuntimeError(
            f"pinned reference mismatch: mlx={mlx_version} mlx-lm={mlx_lm_version}"
        )

    model_dir = Path(args.model_dir)
    if not model_dir.is_dir():
        raise FileNotFoundError(model_dir)
    prompt_ids = [int(value) for value in args.prompt_token_ids]
    position = int(args.position)
    router_records: list[dict[str, Any]] = []
    layer_outputs: dict[int, Any] = {}

    model, _, _ = load(model_dir.as_posix(), lazy=True, return_config=True)
    layer_indices = {id(layer): index for index, layer in enumerate(model.layers)}
    moe_indices = {
        id(layer.mlp): index
        for index, layer in enumerate(model.layers)
        if index in SELECTED_LAYERS
    }
    original_moe = Qwen3NextSparseMoeBlock.__call__
    original_layer = Qwen3NextDecoderLayer.__call__
    current_position = position

    def traced_moe(self: Any, x: Any) -> Any:
        layer_index = moe_indices.get(id(self))
        if layer_index is not None:
            raw = self.gate(x)
            probabilities = mx.softmax(raw, axis=-1, precise=True)
            k = self.top_k
            indices = mx.argpartition(probabilities, kth=-k, axis=-1)[..., -k:]
            scores = mx.take_along_axis(probabilities, indices, axis=-1)
            if self.norm_topk_prob:
                scores = scores / scores.sum(axis=-1, keepdims=True)
            mx.eval(raw, indices, scores)
            raw_rows = raw.reshape(-1, raw.shape[-1]).tolist()
            id_rows = indices.reshape(-1, indices.shape[-1]).tolist()
            score_rows = scores.reshape(-1, scores.shape[-1]).tolist()
            for token_index, ids in enumerate(id_rows):
                row = raw_rows[token_index]
                top = sorted(range(len(row)), key=lambda index: row[index], reverse=True)[:8]
                router_records.append(
                    {
                        "layer": layer_index,
                        "position": current_position + token_index,
                        "expertIDs": [int(value) for value in ids],
                        "scores": [float(value) for value in score_rows[token_index]],
                        "topLogitIDs": top,
                        "topLogits": [float(row[index]) for index in top],
                    }
                )
        return original_moe(self, x)

    def traced_layer(self: Any, x: Any, mask: Any = None, cache: Any = None) -> Any:
        output = original_layer(self, x, mask=mask, cache=cache)
        layer_index = layer_indices.get(id(self))
        if layer_index is not None:
            layer_outputs[layer_index] = output
        return output

    Qwen3NextSparseMoeBlock.__call__ = traced_moe
    Qwen3NextDecoderLayer.__call__ = traced_layer
    try:
        if args.stage == "prefill":
            cache = model.make_cache()
            logits = None
            step = 4
            for offset in range(0, len(prompt_ids), step):
                current_position = offset
                batch = prompt_ids[offset : offset + step]
                logits = model(mx.array(batch).reshape(1, len(batch)), cache=cache)
                mx.eval(logits, *[
                    array
                    for item in cache
                    for array in (
                        [item.state]
                        if not isinstance(item.state, (list, tuple))
                        else list(item.state)
                    )
                ])
            position_after = len(prompt_ids)
            input_token = None
        else:
            cache = load_prompt_cache(Path(args.state_in).as_posix())
            input_token = int(args.input_token)
            current_position = position
            logits = model(mx.array([input_token]).reshape(1, 1), cache=cache)
            mx.eval(logits, *[
                array
                for item in cache
                for array in (
                    [item.state]
                    if not isinstance(item.state, (list, tuple))
                    else list(item.state)
                )
            ])
            position_after = position + 1

        for value in layer_outputs.values():
            mx.eval(value)
        final_logits = logits[0, -1]
        mx.eval(final_logits)
        values = final_logits.tolist()
        top_ids = sorted(range(len(values)), key=lambda index: values[index], reverse=True)[:8]
        predicted = int(top_ids[0])
        if args.state_out:
            save_prompt_cache(
                Path(args.state_out).as_posix(),
                cache,
                metadata={
                    "artifactRevision": ARTIFACT_REVISION,
                    "position": str(position_after),
                    "stateDType": "float32 (config)",
                },
            )
        result = {
            "artifactRevision": ARTIFACT_REVISION,
            "mlxLM": str(mlx_lm_version),
            "mlx": str(mlx_version),
            "device": "cpu",
            "stage": args.stage,
            "positionBefore": position,
            "positionAfter": position_after,
            "inputToken": input_token,
            "predictedToken": predicted,
            "topLogitIDs": top_ids,
            "topLogits": [float(values[index]) for index in top_ids],
            "router": router_records,
            "layers": [
                {"layer": index, "hidden": helper_summary(layer_outputs[index][0, -1])}
                for index in SELECTED_LAYERS
                if index in layer_outputs
            ],
            "cache": helper_cache_summary(cache, position_after),
            "stateBytes": (
                Path(args.state_out).stat().st_size if args.state_out else None
            ),
        }
        json_write(Path(args.result_out), result)
    finally:
        Qwen3NextSparseMoeBlock.__call__ = original_moe
        Qwen3NextDecoderLayer.__call__ = original_layer
        try:
            mx.clear_cache()
        except AttributeError:
            pass
    return 0


def run_stage(args: argparse.Namespace, stage_args: list[str], fixture_root: Path) -> dict[str, Any]:
    command = [sys.executable, str(Path(__file__).resolve()), "--role", "helper"] + stage_args
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "PYTHONUNBUFFERED": "1"},
    )
    guard = ChildGuard(
        process=process,
        fixture_root=fixture_root,
        timeout=args.stage_timeout,
        max_rss=args.max_rss_bytes,
        min_free_disk=args.min_free_disk_bytes,
        max_fixture_bytes=args.max_fixture_bytes,
        max_swap_delta=args.max_swap_delta_bytes,
    )
    try:
        return_code, _ = guard.wait()
    except ResourceGuardAbort as error:
        terminate_child(process)
        stdout, stderr = process.communicate()
        report = {
            "status": "RESOURCE_GUARD_ABORT",
            "reason": str(error),
            "command": command,
            "peakRSSBytes": guard.peak_rss,
            "samples": guard.samples,
            "stdoutTail": stdout[-4000:],
            "stderrTail": stderr[-4000:],
        }
        json_write(fixture_root / "resource-guard-abort.json", report)
        raise
    stdout, stderr = process.communicate()
    result_path = Path(stage_args[stage_args.index("--result-out") + 1])
    if return_code != 0 or not result_path.exists():
        raise RuntimeError(
            f"reference helper failed code={return_code} stderr={stderr[-4000:]}"
        )
    result = read_json(result_path)
    result["resource"] = {
        "peakRSSBytes": guard.peak_rss,
        "samples": guard.samples,
        "stdoutTail": stdout[-1000:],
        "stderrTail": stderr[-1000:],
    }
    json_write(result_path, result)
    return result


def run_parent(args: argparse.Namespace) -> int:
    model_dir = Path(args.model_dir).expanduser().resolve()
    if not model_dir.is_dir():
        raise FileNotFoundError(model_dir)
    fixture_root = Path(args.output_dir).expanduser().resolve()
    fixture_root.mkdir(parents=True, exist_ok=True)
    if fixture_bytes(fixture_root) > args.max_fixture_bytes:
        raise ResourceGuardAbort("existing fixture directory already exceeds quota")

    prompt_ids = args.prompt_token_ids or DEFAULT_PROMPT_IDS
    if not prompt_ids:
        raise ValueError("prompt token IDs are empty")
    if args.max_tokens not in (1, 8, 64):
        raise ValueError("max-tokens must be exactly 1, 8, or 64")
    metadata = {
        "artifactRevision": ARTIFACT_REVISION,
        "mlxLM": "0.31.1",
        "mlx": "0.32.2",
        "device": "cpu",
        "stateDType": "float32 (config)",
        "promptTokenIDs": prompt_ids,
        "promptTokenCount": len(prompt_ids),
        "promptSHA256": prompt_hash(prompt_ids),
        "requestedOutputTokens": args.max_tokens,
        "startedAt": time.time(),
        "resourcePolicy": {
            "maxRSSBytes": args.max_rss_bytes,
            "stageTimeoutSeconds": args.stage_timeout,
            "minFreeDiskBytes": args.min_free_disk_bytes,
            "maxFixtureBytes": args.max_fixture_bytes,
            "maxSwapDeltaBytes": args.max_swap_delta_bytes,
            "maxConcurrentHelpers": 1,
        },
    }
    json_write(fixture_root / "run.json", metadata)

    state = fixture_root / "cache-prefill.safetensors"
    result_path = fixture_root / "stage-prefill.json"
    prefill_args = [
        "--model-dir", str(model_dir),
        "--stage", "prefill",
        "--prompt-token-ids", *[str(value) for value in prompt_ids],
        "--position", "0",
        "--state-out", str(state),
        "--result-out", str(result_path),
    ]
    stages = [run_stage(args, prefill_args, fixture_root)]
    first_token = int(stages[0]["predictedToken"])
    generated: list[int] = []
    if first_token in EOS_IDS:
        stop_reason = "eos"
    else:
        generated.append(first_token)
        stop_reason = "output_limit" if args.max_tokens == 1 else "running"

    selected_steps = {-1, 1, 8, 16, 32, 64}
    if -1 in selected_steps:
        json_write(fixture_root / "checkpoint-prefill.json", stages[0])

    # Every decode helper receives the previous saved cache and then exits.
    # Keep only selected cache checkpoints plus the current continuation state.
    for step in range(1, args.max_tokens + 1):
        if not generated:
            break
        next_state = fixture_root / f"cache-step-{step:03d}.safetensors"
        next_result = fixture_root / f"stage-step-{step:03d}.json"
        stage_args = [
            "--model-dir", str(model_dir),
            "--stage", "decode",
            "--prompt-token-ids", *[str(value) for value in prompt_ids],
            "--position", str(len(prompt_ids) + step - 1),
            "--input-token", str(generated[-1]),
            "--state-in", str(state),
            "--state-out", str(next_state),
            "--result-out", str(next_result),
        ]
        result = run_stage(args, stage_args, fixture_root)
        stages.append(result)
        predicted = int(result["predictedToken"])
        if step < args.max_tokens:
            if predicted in EOS_IDS:
                stop_reason = "eos"
                break
            generated.append(predicted)
        elif args.max_tokens > 1:
            stop_reason = "eos" if predicted in EOS_IDS else "output_limit"
        if step in selected_steps:
            json_write(fixture_root / f"checkpoint-step-{step:03d}.json", result)
        previous_state = state
        state = next_state
        # Intermediate state is no longer needed once its successor is safe.
        if previous_state.name != "cache-prefill.safetensors" and previous_state != state:
            previous_state.unlink(missing_ok=True)

    final_position = len(prompt_ids) + len(generated)
    metadata.update(
        {
            "generatedTokenIDs": generated,
            "stopReason": stop_reason,
            "finalConsumedPosition": final_position,
            "stages": [
                {
                    "stage": stage.get("stage"),
                    "positionBefore": stage.get("positionBefore"),
                    "positionAfter": stage.get("positionAfter"),
                    "predictedToken": stage.get("predictedToken"),
                    "resource": stage.get("resource"),
                    "stateBytes": stage.get("stateBytes"),
                }
                for stage in stages
            ],
            "fixtureBytes": fixture_bytes(fixture_root),
            "completedAt": time.time(),
        }
    )
    json_write(fixture_root / "reference.json", {**metadata, "checkpoints": stages})
    print(json.dumps({
        "status": "COMPLETE",
        "output": str(fixture_root / "reference.json"),
        "generatedTokens": len(generated),
        "stopReason": stop_reason,
        "fixtureBytes": fixture_bytes(fixture_root),
        "peakRSSBytes": max(
            (stage.get("resource", {}).get("peakRSSBytes", 0) for stage in stages),
            default=0,
        ),
    }, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", choices=("parent", "helper"), default="parent")
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--output-dir", type=Path, default=Path("/tmp/qwen35-k8-q22"))
    parser.add_argument("--max-tokens", type=int, default=1)
    parser.add_argument("--prompt-token-ids", type=int, nargs="*")
    parser.add_argument("--stage-timeout", type=float, default=180.0)
    parser.add_argument("--max-rss-bytes", type=int, default=int(2.5 * GIB))
    parser.add_argument("--min-free-disk-bytes", type=int, default=10 * GIB)
    parser.add_argument("--max-fixture-bytes", type=int, default=2 * GIB)
    parser.add_argument("--max-swap-delta-bytes", type=int, default=512 * 1024**2)
    parser.add_argument("--stage", choices=("prefill", "decode"))
    parser.add_argument("--position", type=int, default=0)
    parser.add_argument("--input-token", type=int)
    parser.add_argument("--state-in", type=Path)
    parser.add_argument("--state-out", type=Path)
    parser.add_argument("--result-out", type=Path)
    parser.add_argument("--self-test", action="store_true")
    return parser


def self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="qwen35-q22-guard-") as directory:
        root = Path(directory)
        json_write(root / "probe.json", {"ok": True})
        assert read_json(root / "probe.json")["ok"] is True
        assert prompt_hash(DEFAULT_PROMPT_IDS)
        assert fixture_bytes(root) > 0
        assert memory_free_percent() is None or memory_free_percent() >= 0
    print("bounded-oracle-self-test=passed")
    return 0


def main() -> int:
    args = build_parser().parse_args()
    if args.self_test:
        return self_test()
    if args.role == "helper":
        if args.stage is None or args.result_out is None or args.state_out is None:
            raise SystemExit("helper requires --stage, --state-out, and --result-out")
        if args.stage == "decode" and (args.state_in is None or args.input_token is None):
            raise SystemExit("decode helper requires --state-in and --input-token")
        return run_helper(args)
    return run_parent(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ResourceGuardAbort as error:
        print(f"RESOURCE_GUARD_ABORT: {error}", file=sys.stderr)
        raise SystemExit(2)
