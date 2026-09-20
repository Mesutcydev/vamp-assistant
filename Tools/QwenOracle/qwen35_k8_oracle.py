#!/usr/bin/env python3
"""Generate portable independent Qwen3.5-35B-A3B K=8 oracle fixtures.

This is a development-only tool for a higher-memory Apple Silicon host. It
uses the pinned mlx-lm/MLX implementation directly and never imports or calls
Vampire Assistant. The output contains bounded JSON summaries, token IDs, and
selected cache/router/logit observations; it never contains model weights.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import importlib.metadata
import json
import os
import platform
import re
import resource
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import Any


ARTIFACT_REPO = "mlx-community/Qwen3.5-35B-A3B-4bit"
ARTIFACT_REVISION = "1e20fd8d42056f870933bf98ca6211024744f7ec"
ARTIFACT_INVENTORY_SHA256 = "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592"
CONFIG_SHA256 = "c0cf317cba802cfb1d2984d4b4afc98ceb3d86450ed757e028383bfb03643964"
TOKENIZER_SHA256 = "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"
TOKENIZER_CONFIG_SHA256 = "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"
TEMPLATE_SHA256 = "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"
INDEX_SHA256 = "56f02123353b7fe444b287a46a779a836cb939860502908da4a79e3b43931cdb"
ROUTING_K = 8
EXPERT_COUNT = 256
SELECTED_ROUTER_LAYERS = (0, 19, 39)
SELECTED_LINEAR_STATE_LAYERS = (0, 18, 39)
SELECTED_ATTENTION_LAYERS = (3, 19, 35)
SNAPSHOT_STEPS = (-1, 1, 2, 4, 8, 16, 32, 64)
EOS_IDS = {248044, 248046}
GIB = 1024**3

PRIMARY_PROMPT = (
    "Write 30 numbered practical tips for improving software engineering "
    "productivity. Each tip must contain exactly two complete sentences and "
    "include a concrete example."
)
SECONDARY_PROMPTS = {
    "english": "Give four concise tips for debugging a Swift program, one sentence per tip.",
    "turkish": "Bir yazılım geliştiricisi için dört kısa verimlilik önerisi yaz.",
    "arithmetic": "Compute 37 times 24 and show the calculation.",
    "code": "Write a Swift function that returns the sum of an integer array.",
}

PINNED_FILES = {
    "chat_template.jinja": (7756, TEMPLATE_SHA256, ""),
    "config.json": (3809, CONFIG_SHA256, ""),
    "generation_config.json": (244, "4f25002776b741773666203dcea8f54619f177ace3ae483d311102092a4658e0", ""),
    "model-00001-of-00004.safetensors": (5285828971, "0952c2fd5ec5f6163a045003eb0e60465290ac0ebedbe2cecde35dd95abed345", "4a3b4420de60057931faff2d91a2e5f1ccf3984105a658e97494f8716f8e8860"),
    "model-00002-of-00004.safetensors": (5366101807, "ddf163fcbaa7fc1ff2e93ee2e3306b1c31c4fe3c7dd46990cd2737d0cc30197f", "dbff10353518668a03be092a95620dcc215a16b1e23a079a9a09ad4b4f1ac3c"),
    "model-00003-of-00004.safetensors": (5364643286, "5e7d8deca9240eec828c9a451fbd8a95389a7cc18494f400c330d0717c41f6e1", "9565bfb20ad126db776bd5ce624b35cb384f8dc06e0be181c5d5572adb0d4417"),
    "model-00004-of-00004.safetensors": (4375105375, "b540bac1ef081d7011e32428e0c2da77f00699db2f4f1508da73ee3b8de40551", "ff9d432cb779ff356c2ad35e402198f032e75c0aea6656a20f94a1c69c485823"),
    "model.safetensors.index.json": (215755, INDEX_SHA256, ""),
    "tokenizer.json": (19989343, TOKENIZER_SHA256, ""),
    "tokenizer_config.json": (1139, TOKENIZER_CONFIG_SHA256, ""),
}


class OracleResourceAbort(RuntimeError):
    """Raised before an unsafe oracle run can continue."""


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(json.dumps(value, indent=2, sort_keys=True).encode("utf-8"))
    temporary.replace(path)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def free_disk_bytes(path: Path) -> int:
    stat = os.statvfs(path)
    return stat.f_bavail * stat.f_frsize


def memory_free_percent() -> float | None:
    try:
        output = subprocess.check_output(
            ["/usr/bin/memory_pressure", "-Q"], text=True, stderr=subprocess.STDOUT
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


def physical_memory_bytes() -> int | None:
    try:
        return int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True))
    except (OSError, ValueError, subprocess.CalledProcessError):
        return None


def package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


def prompt_hash(token_ids: list[int]) -> str:
    return hashlib.sha256(str(token_ids).encode("utf-8")).hexdigest()


def verify_artifact(model_dir: Path) -> dict[str, Any]:
    inventory = []
    for name, (expected_bytes, expected_hash, header_hash) in PINNED_FILES.items():
        path = model_dir / name
        if not path.is_file():
            raise ValueError(f"missing pinned artifact file: {name}")
        actual_bytes = path.stat().st_size
        if actual_bytes != expected_bytes:
            raise ValueError(f"size mismatch for {name}: {actual_bytes} != {expected_bytes}")
        actual_hash = sha256_file(path)
        if actual_hash != expected_hash:
            raise ValueError(f"SHA-256 mismatch for {name}: {actual_hash} != {expected_hash}")
        inventory.append({
            "name": name,
            "bytes": expected_bytes,
            "sha256": expected_hash,
            "headerSHA256": header_hash,
        })
    inventory_hash = hashlib.sha256(canonical_json(inventory)).hexdigest()
    if inventory_hash != ARTIFACT_INVENTORY_SHA256:
        raise ValueError(f"artifact inventory identity mismatch: {inventory_hash}")
    return {
        "repo": ARTIFACT_REPO,
        "revision": ARTIFACT_REVISION,
        "inventorySHA256": inventory_hash,
        "files": inventory,
    }


def host_identity() -> dict[str, Any]:
    values: dict[str, Any] = {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "macOS": platform.mac_ver()[0] or None,
        "physicalMemoryBytes": physical_memory_bytes(),
    }
    try:
        values["model"] = subprocess.check_output(
            ["/usr/sbin/sysctl", "-n", "hw.model"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        values["model"] = None
    return values


class SafetyGuard:
    def __init__(self, output_dir: Path, max_swap_delta: int, min_free_percent: float) -> None:
        self.output_dir = output_dir
        self.max_swap_delta = max_swap_delta
        self.min_free_percent = min_free_percent
        self.free_disk_before = free_disk_bytes(output_dir)
        self.swap_before = swap_used_bytes()

    def check(self, label: str) -> None:
        free_percent = memory_free_percent()
        if free_percent is not None and free_percent < self.min_free_percent:
            raise OracleResourceAbort(f"{label}: system memory free percentage {free_percent} is below {self.min_free_percent}")
        swap_after = swap_used_bytes()
        if swap_after is not None and self.swap_before is not None:
            delta = swap_after - self.swap_before
            if delta > self.max_swap_delta:
                raise OracleResourceAbort(f"{label}: swap increased by {delta} bytes")

    def report(self, model_dir: Path, started: float) -> dict[str, Any]:
        swap_after = swap_used_bytes()
        swap_delta = None
        if swap_after is not None and self.swap_before is not None:
            swap_delta = swap_after - self.swap_before
        max_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        if sys.platform != "darwin":
            max_rss *= 1024
        return {
            "host": host_identity(),
            "startedAt": started,
            "elapsedSeconds": time.monotonic() - started,
            "freeDiskBeforeBytes": self.free_disk_before,
            "freeDiskAfterBytes": free_disk_bytes(model_dir),
            "swapBeforeBytes": self.swap_before,
            "swapAfterBytes": swap_after,
            "swapDeltaBytes": swap_delta,
            "peakProcessRSSBytes": max_rss,
            "mlxPeakBytes": None,
            "physicalStorageBytes": None,
            "memoryFreePercent": memory_free_percent(),
            "fixtureBytes": sum(path.stat().st_size for path in self.output_dir.rglob("*") if path.is_file()),
        }


def array_summary(array: Any, mx: Any, sample_count: int = 16) -> dict[str, Any]:
    if array is None:
        return {"shape": [], "dtype": "none", "sample": [], "checksum": None}
    mx.eval(array)
    flat = array.reshape(-1)
    size = int(flat.size)
    count = min(sample_count, size)
    sample = [] if count == 0 else [float(value) for value in flat[:count].tolist()]
    tail_count = min(count, size)
    tail = [] if tail_count == 0 else [float(value) for value in flat[-tail_count:].tolist()]
    summary = {
        "shape": list(array.shape),
        "dtype": str(array.dtype),
        "sample": sample,
        "tailSample": tail,
    }
    summary["checksum"] = hashlib.sha256(canonical_json(summary)).hexdigest()
    return summary


def cache_summary(cache: list[Any], mx: Any) -> list[dict[str, Any]]:
    selected = sorted(set(SELECTED_LINEAR_STATE_LAYERS + SELECTED_ATTENTION_LAYERS))
    output = []
    for layer in selected:
        item = cache[layer]
        state = item.state
        arrays = [state] if not isinstance(state, (list, tuple)) else list(state)
        output.append({
            "layer": layer,
            "type": type(item).__name__,
            "offset": int(getattr(item, "offset", 0) or 0),
            "state": [array_summary(value, mx) for value in arrays],
        })
    return output


def render_prompt(tokenizer: Any, text: str) -> list[int]:
    rendered = tokenizer.apply_chat_template(
        [{"role": "user", "content": text}],
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    if isinstance(rendered, dict):
        rendered = rendered["input_ids"]
    return [int(value) for value in rendered]


def top_logits(logits: Any, mx: Any, count: int = 8) -> tuple[list[int], list[float]]:
    mx.eval(logits)
    values = [float(value) for value in logits.tolist()]
    ids = sorted(range(len(values)), key=lambda index: values[index], reverse=True)[:count]
    return ids, [values[index] for index in ids]


def run_fixture(model: Any, tokenizer: Any, mx: Any, fixture_id: str, prompt_text: str, max_output: int, guard: SafetyGuard) -> dict[str, Any]:
    prompt_ids = render_prompt(tokenizer, prompt_text)
    if not prompt_ids:
        raise ValueError(f"empty rendered prompt for {fixture_id}")
    trace_positions = {len(prompt_ids) - 1}
    trace_positions.update(len(prompt_ids) + step - 1 for step in SNAPSHOT_STEPS if step >= 1)
    router_records: list[dict[str, Any]] = []
    layer_outputs: dict[int, Any] = {}
    current_position = 0
    from mlx_lm.models.qwen3_next import Qwen3NextDecoderLayer, Qwen3NextSparseMoeBlock

    layer_indices = {id(layer): index for index, layer in enumerate(model.layers)}
    moe_indices = {id(layer.mlp): index for index, layer in enumerate(model.layers)}
    original_moe = Qwen3NextSparseMoeBlock.__call__
    original_layer = Qwen3NextDecoderLayer.__call__

    def traced_moe(self: Any, x: Any) -> Any:
        layer_index = moe_indices.get(id(self))
        if layer_index in SELECTED_ROUTER_LAYERS:
            raw = self.gate(x)
            probabilities = mx.softmax(raw, axis=-1, precise=True)
            indices = mx.argpartition(probabilities, kth=-self.top_k, axis=-1)[..., -self.top_k :]
            scores = mx.take_along_axis(probabilities, indices, axis=-1)
            if self.norm_topk_prob:
                scores = scores / scores.sum(axis=-1, keepdims=True)
            mx.eval(raw, indices, scores)
            raw_rows = raw.reshape(-1, raw.shape[-1]).tolist()
            id_rows = indices.reshape(-1, indices.shape[-1]).tolist()
            score_rows = scores.reshape(-1, scores.shape[-1]).tolist()
            for token_index, ids in enumerate(id_rows):
                absolute = current_position + token_index
                if absolute not in trace_positions:
                    continue
                row = [float(value) for value in raw_rows[token_index]]
                top = sorted(range(len(row)), key=lambda index: row[index], reverse=True)[: ROUTING_K + 1]
                router_records.append({
                    "layer": layer_index,
                    "position": absolute,
                    "expertIDs": [int(value) for value in ids],
                    "scores": [float(value) for value in score_rows[token_index]],
                    "topLogitIDs": [int(value) for value in top],
                    "topLogits": [row[index] for index in top],
                    "kthScore": float(row[top[ROUTING_K - 1]]),
                    "kPlusOneScore": float(row[top[ROUTING_K]]),
                    "kGap": float(row[top[ROUTING_K - 1]] - row[top[ROUTING_K]]),
                })
        return original_moe(self, x)

    def traced_layer(self, x: Any, mask: Any = None, cache: Any = None) -> Any:
        output = original_layer(self, x, mask=mask, cache=cache)
        layer_index = layer_indices.get(id(self))
        if layer_index in set(SELECTED_ROUTER_LAYERS):
            layer_outputs[layer_index] = output
        return output

    def checkpoint(step: int, position_before: int, position_after: int, input_token: int | None, logits: Any, cache: list[Any]) -> dict[str, Any]:
        final_logits = logits[0, -1]
        ids, values = top_logits(final_logits, mx)
        wanted_position = len(prompt_ids) - 1 if step == -1 else len(prompt_ids) + step - 1
        records = [record for record in router_records if record["position"] == wanted_position]
        return {
            "decodeStep": step,
            "positionBefore": position_before,
            "positionAfter": position_after,
            "inputToken": input_token,
            "predictedToken": ids[0],
            "topLogitIDs": ids,
            "topLogits": values,
            "layerSnapshots": [
                {"layer": layer, "hidden": array_summary(layer_outputs[layer][0, -1], mx)}
                for layer in SELECTED_ROUTER_LAYERS
                if layer in layer_outputs
            ],
            "cache": cache_summary(cache, mx),
            "router": records,
        }

    Qwen3NextSparseMoeBlock.__call__ = traced_moe
    Qwen3NextDecoderLayer.__call__ = traced_layer
    try:
        cache = model.make_cache()
        logits = None
        group_size = 4
        for offset in range(0, len(prompt_ids), group_size):
            current_position = offset
            batch = prompt_ids[offset : offset + group_size]
            logits = model(mx.array(batch).reshape(1, len(batch)), cache=cache)
            arrays = [array for item in cache for array in ([item.state] if not isinstance(item.state, (list, tuple)) else list(item.state))]
            mx.eval(logits, *arrays)
            guard.check(f"{fixture_id} prefill")
        assert logits is not None
        prefill = checkpoint(-1, 0, len(prompt_ids), None, logits, cache)
        checkpoints = [prefill]
        generated: list[int] = []
        stop_reason = "output_limit"
        while len(generated) < max_output:
            next_ids, _ = top_logits(logits[0, -1], mx)
            next_token = int(next_ids[0])
            if next_token in EOS_IDS:
                stop_reason = "eos"
                break
            generated.append(next_token)
            current_position = len(prompt_ids) + len(generated) - 1
            logits = model(mx.array([next_token]).reshape(1, 1), cache=cache)
            arrays = [array for item in cache for array in ([item.state] if not isinstance(item.state, (list, tuple)) else list(item.state))]
            mx.eval(logits, *arrays)
            step = len(generated)
            if step in SNAPSHOT_STEPS:
                checkpoints.append(checkpoint(step, current_position, current_position + 1, next_token, logits, cache))
            guard.check(f"{fixture_id} decode-{step}")
        if len(generated) < max_output and stop_reason != "eos":
            stop_reason = "eos"
        return {
            "fixtureID": fixture_id,
            "promptTokenIDs": prompt_ids,
            "promptTokenCount": len(prompt_ids),
            "promptSHA256": prompt_hash(prompt_ids),
            "generatedTokenIDs": generated,
            "stopReason": stop_reason,
            "finalConsumedPosition": len(prompt_ids) + len(generated),
            "checkpoints": checkpoints,
        }
    finally:
        Qwen3NextSparseMoeBlock.__call__ = original_moe
        Qwen3NextDecoderLayer.__call__ = original_layer
        try:
            mx.clear_cache()
        except AttributeError:
            pass
        gc.collect()


def semantic_signature(fixture: dict[str, Any]) -> dict[str, Any]:
    return {
        "promptTokenIDs": fixture["promptTokenIDs"],
        "generatedTokenIDs": fixture["generatedTokenIDs"],
        "stopReason": fixture["stopReason"],
        "finalConsumedPosition": fixture["finalConsumedPosition"],
        "checkpoints": [
            {
                "decodeStep": item["decodeStep"],
                "positionBefore": item["positionBefore"],
                "positionAfter": item["positionAfter"],
                "predictedToken": item["predictedToken"],
                "router": [(record["layer"], record["position"], record["expertIDs"]) for record in item["router"]],
            }
            for item in fixture["checkpoints"]
        ],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--max-swap-delta-bytes", type=int, default=4 * GIB)
    parser.add_argument("--min-free-memory-percent", type=float, default=10.0)
    parser.add_argument("--self-test", action="store_true")
    return parser


def self_test() -> int:
    assert hashlib.sha256(canonical_json([])).hexdigest()
    assert len(ARTIFACT_REVISION) == 40
    assert ROUTING_K == 8
    assert set(SNAPSHOT_STEPS) == {-1, 1, 2, 4, 8, 16, 32, 64}
    print("qwen35-k8-oracle-self-test=passed")
    return 0


def main() -> int:
    args = build_parser().parse_args()
    if args.self_test:
        return self_test()
    if args.model_dir is None or args.output_dir is None or args.archive is None:
        raise SystemExit("--model-dir, --output-dir, and --archive are required unless --self-test is used")
    model_dir = args.model_dir.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    archive = args.archive.expanduser().resolve()
    if not model_dir.is_dir():
        raise FileNotFoundError(model_dir)
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ValueError(f"output directory must be new or empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    inventory = verify_artifact(model_dir)
    guard = SafetyGuard(output_dir, args.max_swap_delta_bytes, args.min_free_memory_percent)
    guard.check("before model load")

    import mlx.core as mx
    import mlx_lm
    from mlx_lm import load

    mx.set_default_device(mx.cpu)
    mlx_version = package_version("mlx")
    mlx_lm_version = package_version("mlx-lm")
    if mlx_version != "0.32.2" or mlx_lm_version != "0.31.1":
        raise ValueError(f"pinned reference mismatch: mlx={mlx_version} mlx-lm={mlx_lm_version}")
    model, tokenizer, config = load(model_dir.as_posix(), lazy=True, return_config=True)
    guard.check("after model load")

    prompts = {"primary": PRIMARY_PROMPT, **SECONDARY_PROMPTS}
    output_limits = {"primary": 64, "english": 12, "turkish": 12, "arithmetic": 12, "code": 16}
    fixtures: dict[str, Any] = {}
    for fixture_id, text in prompts.items():
        first = run_fixture(model, tokenizer, mx, fixture_id, text, output_limits[fixture_id], guard)
        second = run_fixture(model, tokenizer, mx, fixture_id, text, output_limits[fixture_id], guard)
        if semantic_signature(first) != semantic_signature(second):
            raise ValueError(f"oracle is nondeterministic for fixture {fixture_id}")
        if fixture_id == "primary" and len(first["generatedTokenIDs"]) < 64:
            raise ValueError(f"primary fixture stopped at {len(first['generatedTokenIDs'])} tokens before 64")
        fixture_path = output_dir / "fixtures" / f"{fixture_id}.json"
        json_write(fixture_path, first)
        fixtures[fixture_id] = {
            "path": f"fixtures/{fixture_id}.json",
            "bytes": fixture_path.stat().st_size,
            "sha256": sha256_file(fixture_path),
            "promptTokenCount": first["promptTokenCount"],
            "promptSHA256": first["promptSHA256"],
            "generatedTokens": len(first["generatedTokenIDs"]),
            "stopReason": first["stopReason"],
        }
        guard.check(f"after {fixture_id}")

    metadata = {
        "fixtureFormatVersion": "qwen35-k8-oracle-v1",
        "artifact": inventory,
        "configSHA256": CONFIG_SHA256,
        "tokenizerSHA256": TOKENIZER_SHA256,
        "tokenizerConfigSHA256": TOKENIZER_CONFIG_SHA256,
        "templateSHA256": TEMPLATE_SHA256,
        "oracle": {
            "python": platform.python_version(),
            "mlx": mlx_version,
            "mlxLM": mlx_lm_version,
            "device": "cpu",
            "recurrentState": "float32 (config)",
            "configModelType": config.get("model_type") if isinstance(config, dict) else None,
        },
        "semantics": {
            "routingK": ROUTING_K,
            "expertCount": EXPERT_COUNT,
            "sharedExpert": True,
            "thinking": False,
            "sampler": "greedy/temperature-disabled",
            "selectedRouterLayers": list(SELECTED_ROUTER_LAYERS),
            "selectedLinearStateLayers": list(SELECTED_LINEAR_STATE_LAYERS),
            "selectedAttentionLayers": list(SELECTED_ATTENTION_LAYERS),
            "snapshotSteps": list(SNAPSHOT_STEPS),
        },
        "fixtures": fixtures,
        "resource": guard.report(model_dir, started),
        "generatedAt": time.time(),
    }
    json_write(output_dir / "manifest.json", metadata)
    (output_dir / "README.md").write_text(
        "# Qwen3.5 K=8 oracle fixtures\\n\\n"
        "Generated from the pinned quantized artifact with mlx-lm 0.31.1 / MLX 0.32.2.\\n"
        "This archive contains no model shards. Set `BEETCODE_QWEN35_ORACLE_FIXTURE`\\n"
        "to this archive or an extracted directory on the Vampire Assistant target.\\n"
    )
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists():
        raise ValueError(f"archive already exists: {archive}")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as handle:
        for path in sorted(output_dir.rglob("*")):
            if path.is_file():
                handle.write(path, path.relative_to(output_dir).as_posix())
    if archive.stat().st_size > GIB:
        raise ValueError("fixture archive exceeds the 1 GiB portability limit")
    archive_hash = sha256_file(archive)
    (archive.with_suffix(archive.suffix + ".sha256")).write_text(f"{archive_hash}  {archive.name}\n")
    print(json.dumps({
        "status": "READY_FOR_TARGET_VALIDATION",
        "archive": str(archive),
        "archiveBytes": archive.stat().st_size,
        "archiveSHA256": archive_hash,
        "fixtureBytes": sum(path.stat().st_size for path in output_dir.rglob("*") if path.is_file()),
        "resource": metadata["resource"],
        "fixtures": fixtures,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OracleResourceAbort as error:
        print(f"RESOURCE_GUARD_ABORT: {error}", file=sys.stderr)
        raise SystemExit(2)
