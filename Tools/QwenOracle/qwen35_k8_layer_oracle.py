#!/usr/bin/env python3
"""Layer-isolated independent Qwen3.5 K=8 validation oracle.

This development-only tool is deliberately separate from Vampire Assistant.
Unlike the original Q2.3 producer, it never calls ``mlx_lm.load`` and never
constructs the 40-layer reference model.  A short-lived worker reads only the
Safetensors entries for one decoder layer, builds that upstream layer with
native quantized MLX modules, materializes its output/state, and exits before
another worker is started.

The first safe gates are metadata planning, one real linear-attention layer,
one real full-attention layer, and a process-boundary serialization check.
Full-model fixture generation is intentionally gated behind those proofs.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import resource
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np

from qwen35_q215_storage import (
    Q215_DEFAULT_SAFETY_RESERVE_BYTES,
    Q215_LEGACY_Q214_FLOOR_BYTES,
    Q215_STORAGE_FORMAT_VERSION,
    directory_size,
    estimate_rolling_disk_budget,
    load_config,
)


try:
    # The shared constants are deliberately imported from the already pinned
    # Q2.3 producer.  That module does not import MLX at module import time.
    from qwen35_k8_oracle import (
        ARTIFACT_INVENTORY_SHA256,
        ARTIFACT_REPO,
        ARTIFACT_REVISION,
        CONFIG_SHA256,
        EOS_IDS,
        GIB,
        INDEX_SHA256,
        PINNED_FILES,
        PRIMARY_PROMPT,
        ROUTING_K,
        TEMPLATE_SHA256,
        TOKENIZER_CONFIG_SHA256,
        TOKENIZER_SHA256,
        canonical_json,
        free_disk_bytes,
        memory_free_percent,
        package_version,
        physical_memory_bytes,
        sha256_file,
        swap_used_bytes,
        verify_artifact,
    )
except ImportError:  # pragma: no cover - useful when copied as one file
    ARTIFACT_REPO = "mlx-community/Qwen3.5-35B-A3B-4bit"
    ARTIFACT_REVISION = "1e20fd8d42056f870933bf98ca6211024744f7ec"
    ARTIFACT_INVENTORY_SHA256 = "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592"
    CONFIG_SHA256 = "c0cf317cba802cfb1d2984d4b4afc98ceb3d86450ed757e028383bfb03643964"
    TOKENIZER_SHA256 = "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"
    TOKENIZER_CONFIG_SHA256 = "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"
    TEMPLATE_SHA256 = "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"
    INDEX_SHA256 = "56f02123353b7fe444b287a46a779a836cb939860502908da4a79e3b43931cdb"
    ROUTING_K = 8
    EOS_IDS = {248044, 248046}
    PRIMARY_PROMPT = (
        "Write 30 numbered practical tips for improving software engineering "
        "productivity. Each tip must contain exactly two complete sentences "
        "and include a concrete example."
    )
    GIB = 1024**3

    def canonical_json(value: Any) -> bytes:
        return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()

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
            out = subprocess.check_output(["/usr/bin/memory_pressure", "-Q"], text=True)
        except (OSError, subprocess.CalledProcessError):
            return None
        import re

        match = re.search(r"free percentage:\s*([0-9]+(?:\.[0-9]+)?)%", out)
        return float(match.group(1)) if match else None

    def swap_used_bytes() -> int | None:
        try:
            out = subprocess.check_output(["/usr/sbin/sysctl", "-n", "vm.swapusage"], text=True)
        except (OSError, subprocess.CalledProcessError):
            return None
        import re

        match = re.search(r"used\s*=\s*([0-9.]+)([KMGTP])", out)
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

    def verify_artifact(model_dir: Path) -> dict[str, Any]:
        inventory = []
        for name, (expected_bytes, expected_hash, header_hash) in PINNED_FILES.items():
            path = model_dir / name
            if not path.is_file() or path.stat().st_size != expected_bytes:
                raise ValueError(f"missing or size-mismatched pinned artifact file: {name}")
            actual_hash = sha256_file(path)
            if actual_hash != expected_hash:
                raise ValueError(f"SHA-256 mismatch for {name}: {actual_hash}")
            inventory.append({"name": name, "bytes": expected_bytes, "sha256": expected_hash, "headerSHA256": header_hash})
        identity = hashlib.sha256(canonical_json(inventory)).hexdigest()
        if identity != ARTIFACT_INVENTORY_SHA256:
            raise ValueError(f"artifact inventory identity mismatch: {identity}")
        return {"repo": ARTIFACT_REPO, "revision": ARTIFACT_REVISION, "inventorySHA256": identity, "files": inventory}


SAFE_TENSOR_HEADER_LIMIT = 128 * 1024 * 1024
MAX_TENSOR_BYTES = 8 * GIB
DTYPE_INFO: dict[str, tuple[str, int]] = {
    "BOOL": ("?", 1),
    "U8": ("u1", 1),
    "U16": ("<u2", 2),
    "U32": ("<u4", 4),
    "U64": ("<u8", 8),
    "I8": ("i1", 1),
    "I16": ("<i2", 2),
    "I32": ("<i4", 4),
    "I64": ("<i8", 8),
    "F16": ("<f2", 2),
    "F32": ("<f4", 4),
    "F64": ("<f8", 8),
    # NumPy has no portable bfloat16 dtype.  The raw words are viewed as
    # MLX bfloat16 only after the range has been read and length-checked.
    "BF16": ("<u2", 2),
}


class LayerOracleError(RuntimeError):
    """A validation-stage failure that must not be treated as a parity pass."""


@dataclass(frozen=True)
class TensorEntry:
    name: str
    shard: str
    dtype: str
    shape: tuple[int, ...]
    start: int
    end: int

    @property
    def byte_count(self) -> int:
        return self.end - self.start


def _safe_model_child(model_dir: Path, name: str) -> Path:
    if not name or Path(name).is_absolute() or ".." in Path(name).parts:
        raise LayerOracleError(f"invalid shard path: {name!r}")
    child = (model_dir / name).resolve()
    root = model_dir.resolve()
    if child != root and root not in child.parents:
        raise LayerOracleError(f"shard escapes model directory: {name!r}")
    if child.is_symlink():
        raise LayerOracleError(f"symlinked shard is not accepted: {name!r}")
    return child


class SelectiveSafeTensorReader:
    """Read individual Safetensors ranges without materializing a shard."""

    def __init__(self, model_dir: Path):
        self.model_dir = model_dir.resolve()
        index_path = self.model_dir / "model.safetensors.index.json"
        index_hash = sha256_file(index_path)
        if index_hash != INDEX_SHA256:
            raise LayerOracleError(f"index SHA-256 mismatch: {index_hash}")
        raw = json.loads(index_path.read_text())
        weight_map = raw.get("weight_map")
        if not isinstance(weight_map, dict) or not weight_map:
            raise LayerOracleError("Safetensors index has no weight_map")
        self.weight_map: dict[str, str] = {}
        for key, shard in weight_map.items():
            if not isinstance(key, str) or not isinstance(shard, str):
                raise LayerOracleError("non-string Safetensors index entry")
            self.weight_map[key] = shard
        self._headers: dict[str, tuple[int, dict[str, Any], int]] = {}
        self.requested_bytes = 0
        self.completed_bytes = 0
        self.read_calls = 0

    def _header(self, shard: str) -> tuple[int, dict[str, Any], int]:
        if shard in self._headers:
            return self._headers[shard]
        path = _safe_model_child(self.model_dir, shard)
        with path.open("rb") as handle:
            prefix = handle.read(8)
            if len(prefix) != 8:
                raise LayerOracleError(f"truncated Safetensors header prefix: {shard}")
            header_len = struct.unpack("<Q", prefix)[0]
            if header_len > SAFE_TENSOR_HEADER_LIMIT:
                raise LayerOracleError(f"Safetensors header too large: {shard}")
            header_bytes = handle.read(header_len)
            if len(header_bytes) != header_len:
                raise LayerOracleError(f"truncated Safetensors header: {shard}")
            try:
                header = json.loads(header_bytes)
            except json.JSONDecodeError as error:
                raise LayerOracleError(f"invalid Safetensors header: {shard}") from error
            if not isinstance(header, dict):
                raise LayerOracleError(f"Safetensors header is not an object: {shard}")
            file_size = path.stat().st_size
            data_start = 8 + header_len
            ranges: list[tuple[int, int, str]] = []
            for name, item in header.items():
                if name == "__metadata__":
                    continue
                if not isinstance(item, dict):
                    raise LayerOracleError(f"invalid tensor header entry: {name}")
                offsets = item.get("data_offsets")
                shape = item.get("shape")
                dtype = item.get("dtype")
                if (not isinstance(offsets, list) or len(offsets) != 2 or
                        not isinstance(shape, list) or not isinstance(dtype, str) or
                        dtype not in DTYPE_INFO):
                    raise LayerOracleError(f"invalid tensor metadata: {name}")
                start, end = offsets
                if (not isinstance(start, int) or not isinstance(end, int) or
                        start < 0 or end < start or end - start > MAX_TENSOR_BYTES):
                    raise LayerOracleError(f"invalid tensor range: {name}")
                if any(not isinstance(dim, int) or dim < 0 for dim in shape):
                    raise LayerOracleError(f"invalid tensor shape: {name}")
                element_count = math.prod(shape) if shape else 1
                expected = element_count * DTYPE_INFO[dtype][1]
                if expected != end - start:
                    raise LayerOracleError(f"tensor byte/shape mismatch: {name}")
                if data_start + end > file_size:
                    raise LayerOracleError(f"tensor range exceeds shard: {name}")
                ranges.append((start, end, name))
            previous_end = 0
            for start, end, name in sorted(ranges):
                if start < previous_end:
                    raise LayerOracleError(f"overlapping tensor ranges: {name}")
                previous_end = end
            self._headers[shard] = (data_start, header, file_size)
            return self._headers[shard]

    def entry(self, name: str) -> TensorEntry:
        try:
            shard = self.weight_map[name]
        except KeyError as error:
            raise LayerOracleError(f"tensor is absent from index: {name}") from error
        data_start, header, _ = self._header(shard)
        try:
            item = header[name]
        except KeyError as error:
            raise LayerOracleError(f"tensor is absent from shard header: {name}") from error
        return TensorEntry(
            name=name,
            shard=shard,
            dtype=item["dtype"],
            shape=tuple(int(value) for value in item["shape"]),
            start=data_start + int(item["data_offsets"][0]),
            end=data_start + int(item["data_offsets"][1]),
        )

    def entries_for_prefix(self, prefix: str) -> list[TensorEntry]:
        return [self.entry(name) for name in sorted(self.weight_map) if name.startswith(prefix)]

    def read_raw(self, entry: TensorEntry) -> bytes:
        return self.read_range(entry.shard, entry.start, entry.byte_count, entry.name)

    def read_range(self, shard: str, absolute_start: int, count: int, label: str) -> bytes:
        if count < 0 or count > MAX_TENSOR_BYTES:
            raise LayerOracleError(f"invalid read length for {label}: {count}")
        self.requested_bytes += count
        self.read_calls += 1
        path = _safe_model_child(self.model_dir, shard)
        with path.open("rb") as handle:
            handle.seek(absolute_start)
            data = handle.read(count)
        if len(data) != count:
            raise LayerOracleError(f"short read for {label}: {len(data)} != {count}")
        self.completed_bytes += len(data)
        return data

    @staticmethod
    def _from_raw(entry: TensorEntry, raw: bytes, mx: Any, shape: tuple[int, ...] | None = None) -> Any:
        np_dtype, _ = DTYPE_INFO[entry.dtype]
        values = np.frombuffer(raw, dtype=np.dtype(np_dtype))
        array = mx.array(values)
        if entry.dtype == "BF16":
            array = array.view(mx.bfloat16)
        return array.reshape(shape if shape is not None else (entry.shape or ()))

    def read_mlx(self, name: str, mx: Any) -> Any:
        entry = self.entry(name)
        raw = self.read_raw(entry)
        return self._from_raw(entry, raw, mx)

    def read_mlx_rows(self, name: str, rows: list[int], mx: Any) -> Any:
        entry = self.entry(name)
        if len(entry.shape) < 1:
            raise LayerOracleError(f"cannot row-select scalar tensor: {name}")
        row_count = entry.shape[0]
        row_bytes = entry.byte_count // row_count
        if any(row < 0 or row >= row_count for row in rows):
            raise LayerOracleError(f"row selection out of bounds for {name}")
        arrays = []
        row_shape = (1, *entry.shape[1:])
        for row in rows:
            raw = self.read_range(entry.shard, entry.start + row * row_bytes, row_bytes, f"{name}[{row}]")
            arrays.append(self._from_raw(entry, raw, mx, row_shape))
        return mx.concatenate(arrays, axis=0) if arrays else mx.zeros((0, *entry.shape[1:]), dtype=mx.float32)

    def layer_plan(self, layer_index: int) -> dict[str, Any]:
        prefix = f"language_model.model.layers.{layer_index}."
        entries = self.entries_for_prefix(prefix)
        if not entries:
            raise LayerOracleError(f"layer {layer_index} has no indexed tensors")
        routed = sum(
            entry.byte_count
            for entry in entries
            if ".mlp.switch_mlp." in entry.name
        )
        common = sum(entry.byte_count for entry in entries) - routed
        return {
            "layer": layer_index,
            "tensorCount": len(entries),
            "bytes": sum(entry.byte_count for entry in entries),
            "routedExpertPayloadBytes": routed,
            "commonAndTemporaryInputBytes": common,
            "entries": [
                {
                    "name": entry.name,
                    "shard": entry.shard,
                    "dtype": entry.dtype,
                    "shape": list(entry.shape),
                    "bytes": entry.byte_count,
                }
                for entry in entries
            ],
        }


def _json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True))
    temporary.replace(path)


def _prompt_hash(token_ids: list[int]) -> str:
    return hashlib.sha256(str(token_ids).encode("utf-8")).hexdigest()


def _process_rss_bytes(pid: int) -> int | None:
    try:
        raw = subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", str(pid)], text=True).strip()
        return int(raw.split()[0]) * 1024 if raw else None
    except (OSError, ValueError, subprocess.CalledProcessError):
        return None


def _self_peak_rss_bytes() -> int:
    value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return value if sys.platform == "darwin" else value * 1024


def _host_identity() -> dict[str, Any]:
    result: dict[str, Any] = {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "macOS": platform.mac_ver()[0] or None,
        "physicalMemoryBytes": physical_memory_bytes(),
    }
    try:
        result["model"] = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        result["model"] = None
    return result


class WorkerGuard:
    def __init__(self, process: subprocess.Popen[str], args: argparse.Namespace, root: Path):
        self.process = process
        self.args = args
        self.root = root
        self.started = time.monotonic()
        self.swap_before = swap_used_bytes()
        self.peak_rss = 0
        self.samples: list[dict[str, Any]] = []

    def sample(self) -> dict[str, Any]:
        rss = _process_rss_bytes(self.process.pid)
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
                swap - self.swap_before
                if swap is not None and self.swap_before is not None
                else None
            ),
            "freeDiskBytes": free_disk_bytes(self.root),
        }
        if len(self.samples) < 256:
            self.samples.append(sample)
        return sample

    def check(self, sample: dict[str, Any]) -> None:
        rss = sample.get("rssBytes")
        if rss is not None and rss > self.args.max_rss_bytes:
            raise LayerOracleError(f"worker RSS {rss} exceeds {self.args.max_rss_bytes}")
        free = sample.get("memoryFreePercent")
        if free is not None and free < self.args.min_free_memory_percent:
            raise LayerOracleError(f"system memory free percentage {free} is below {self.args.min_free_memory_percent}")
        swap_delta = sample.get("swapDeltaBytes")
        if swap_delta is not None and swap_delta > self.args.max_swap_delta_bytes:
            raise LayerOracleError(f"swap increased by {swap_delta} bytes")
        if sample.get("freeDiskBytes", 0) < self.args.min_free_disk_bytes:
            raise LayerOracleError(f"free disk is below {self.args.min_free_disk_bytes} bytes")

    def wait(self) -> tuple[int, dict[str, Any]]:
        while self.process.poll() is None:
            if time.monotonic() - self.started > self.args.worker_timeout:
                raise LayerOracleError(f"worker timeout after {self.args.worker_timeout:.1f}s")
            sample = self.sample()
            self.check(sample)
            time.sleep(1.0)
        final = self.sample()
        self.check(final)
        return self.process.returncode or 0, final


def _terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def _dtype_size(dtype: str) -> int:
    if dtype not in DTYPE_INFO:
        raise LayerOracleError(f"unsupported dtype {dtype}")
    return DTYPE_INFO[dtype][1]


def _array_summary(
    array: Any,
    mx: Any,
    sample_count: int = 16,
    capture_full: bool = False,
) -> dict[str, Any]:
    mx.eval(array)
    flat = array.reshape(-1)
    size = int(flat.size)
    count = min(sample_count, size)
    values = [] if count == 0 else [float(value) for value in flat[:count].tolist()]
    tail = [] if count == 0 else [float(value) for value in flat[-count:].tolist()]
    summary = {"shape": list(array.shape), "dtype": str(array.dtype), "sample": values, "tailSample": tail}
    if capture_full:
        complete = [float(value) for value in flat.tolist()]
        summary["values"] = complete
        dtype_text = str(array.dtype).lower()
        if "bfloat16" in dtype_text:
            raw_bits = array.reshape(-1).view(mx.uint16)
            mx.eval(raw_bits)
            bits = [int(value) for value in raw_bits.tolist()]
            # Keep the legacy field for existing BF16 consumers while also
            # exposing a dtype-neutral exact representation for Q2.8.
            summary["rawBFloat16Bits"] = bits
            summary["rawUInt16Bits"] = bits
        elif "float16" in dtype_text:
            raw_bits = array.reshape(-1).view(mx.uint16)
            mx.eval(raw_bits)
            summary["rawUInt16Bits"] = [int(value) for value in raw_bits.tolist()]
        elif "float32" in dtype_text:
            raw_bits = array.reshape(-1).view(mx.uint32)
            mx.eval(raw_bits)
            summary["rawUInt32Bits"] = [int(value) for value in raw_bits.tolist()]
    summary["checksum"] = hashlib.sha256(canonical_json(summary)).hexdigest()
    return summary


def _cache_arrays(cache: Any) -> list[Any]:
    state = cache.state
    return [state] if not isinstance(state, (list, tuple)) else [value for value in state if value is not None]


def _cache_summary(cache: Any, mx: Any, capture_full: bool = False) -> dict[str, Any]:
    arrays = _cache_arrays(cache)
    for value in arrays:
        mx.eval(value)
    return {
        "type": type(cache).__name__,
        "offset": int(getattr(cache, "offset", 0) or 0),
        "state": [_array_summary(value, mx, capture_full=capture_full) for value in arrays],
    }


def _new_quantized_linear(nn: Any, input_dims: int, output_dims: int, bits: int, has_bias: bool = False) -> Any:
    # Construct with tiny dimensions so the upstream constructor never
    # materializes a dense layer-sized random matrix.  Its arrays are replaced
    # immediately by the selectively read checkpoint ranges.
    module = nn.QuantizedLinear(64, 1, bias=has_bias, group_size=64, bits=bits, mode="affine")
    module.group_size = 64
    module.bits = bits
    module.mode = "affine"
    return module


def _new_quantized_switch(bits: int) -> Any:
    from mlx_lm.models.switch_layers import QuantizedSwitchLinear

    module = QuantizedSwitchLinear(64, 1, 1, bias=False, group_size=64, bits=bits, mode="affine")
    module.group_size = 64
    module.bits = bits
    module.mode = "affine"
    return module


def _install_quantized_linear(module: Any, reader: SelectiveSafeTensorReader, mx: Any, prefix: str, bits: int) -> None:
    module.weight = reader.read_mlx(prefix + ".weight", mx)
    module.scales = reader.read_mlx(prefix + ".scales", mx)
    module.biases = reader.read_mlx(prefix + ".biases", mx)
    module.group_size = 64
    module.bits = bits
    module.mode = "affine"
    module.freeze()


def _install_quantized_switch(module: Any, reader: SelectiveSafeTensorReader, mx: Any, prefix: str, bits: int) -> None:
    module.weight = reader.read_mlx(prefix + ".weight", mx)
    module.scales = reader.read_mlx(prefix + ".scales", mx)
    module.biases = reader.read_mlx(prefix + ".biases", mx)
    module.group_size = 64
    module.bits = bits
    module.mode = "affine"
    module.freeze()


def _quantized_bits(reader: SelectiveSafeTensorReader, prefix: str, input_dims: int) -> int:
    """Derive bits from packed checkpoint geometry instead of a model-family override."""
    entry = reader.entry(prefix + ".weight")
    packed_input = entry.shape[-1]
    packed_bits = packed_input * 32
    if input_dims <= 0 or packed_bits % input_dims != 0:
        raise LayerOracleError(
            f"cannot derive quantization bits for {prefix}: packed={packed_input}, input={input_dims}"
        )
    bits = packed_bits // input_dims
    if bits not in (2, 3, 4, 8, 16):
        raise LayerOracleError(f"unsupported derived bit width {bits} for {prefix}")
    scales = reader.entry(prefix + ".scales")
    if not scales.shape or scales.shape[-1] != (input_dims + 63) // 64:
        raise LayerOracleError(
            f"group geometry mismatch for {prefix}: scales={scales.shape}, input={input_dims}"
        )
    return bits


def _build_layer(model_dir: Path, layer_index: int, mx: Any, nn: Any) -> tuple[Any, SelectiveSafeTensorReader, Any]:
    import mlx_lm.models.qwen3_5 as qwen35

    # mlx-lm 0.31.1's public Qwen3.5 module drops the artifact's
    # ``mamba_ssm_dtype`` field and its compiled CPU op returns a BF16 state.
    # The pinned config declares FP32 recurrent state, which is also the state
    # type used by the native Swift implementation. Install the small,
    # independent configured adapter before constructing the layer so every
    # worker observes the same declared contract.
    qwen35.gated_delta_update = _configured_gated_delta_update
    DecoderLayer = qwen35.DecoderLayer
    TextModelArgs = qwen35.TextModelArgs

    config = json.loads((model_dir / "config.json").read_text())
    text_config = config.get("text_config", config)
    args = TextModelArgs.from_dict(text_config)
    layer = DecoderLayer(args=args, layer_idx=layer_index)
    reader = SelectiveSafeTensorReader(model_dir)
    prefix = f"language_model.model.layers.{layer_index}"

    layer.input_layernorm.weight = reader.read_mlx(prefix + ".input_layernorm.weight", mx)
    layer.post_attention_layernorm.weight = reader.read_mlx(prefix + ".post_attention_layernorm.weight", mx)

    if layer.is_linear:
        attention = layer.linear_attn
        attention.conv1d.weight = reader.read_mlx(prefix + ".linear_attn.conv1d.weight", mx)
        attention.A_log = reader.read_mlx(prefix + ".linear_attn.A_log", mx)
        attention.dt_bias = reader.read_mlx(prefix + ".linear_attn.dt_bias", mx)
        # The gated RMS norm is a learned checkpoint tensor.  Leaving the
        # constructor's all-ones placeholder in place creates an oracle-only
        # mismatch after the recurrent update and can be mistaken for a
        # native gated-delta defect.
        attention.norm.weight = reader.read_mlx(prefix + ".linear_attn.norm.weight", mx)
        for name in ("in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a", "out_proj"):
            input_dims = attention.value_dim if name == "out_proj" else int(layer.input_layernorm.weight.shape[0])
            bits = _quantized_bits(reader, prefix + ".linear_attn." + name, input_dims)
            replacement = _new_quantized_linear(nn, input_dims, 1, bits)
            _install_quantized_linear(replacement, reader, mx, prefix + ".linear_attn." + name, bits)
            setattr(attention, name, replacement)
    else:
        attention = layer.self_attn
        attention.q_norm.weight = reader.read_mlx(prefix + ".self_attn.q_norm.weight", mx)
        attention.k_norm.weight = reader.read_mlx(prefix + ".self_attn.k_norm.weight", mx)
        for name in ("q_proj", "k_proj", "v_proj", "o_proj"):
            input_dims = attention.num_attention_heads * attention.head_dim if name == "o_proj" else int(layer.input_layernorm.weight.shape[0])
            bits = _quantized_bits(reader, prefix + ".self_attn." + name, input_dims)
            replacement = _new_quantized_linear(nn, input_dims, 1, bits)
            _install_quantized_linear(replacement, reader, mx, prefix + ".self_attn." + name, bits)
            setattr(attention, name, replacement)

    mlp = layer.mlp
    gate_bits = _quantized_bits(reader, prefix + ".mlp.gate", layer.input_layernorm.weight.shape[0])
    gate = _new_quantized_linear(nn, layer.input_layernorm.weight.shape[0], 1, gate_bits)
    _install_quantized_linear(gate, reader, mx, prefix + ".mlp.gate", gate_bits)
    mlp.gate = gate

    shared = mlp.shared_expert
    for name in ("gate_proj", "up_proj", "down_proj"):
        input_dims = shared.gate_proj.weight.shape[0] if name == "down_proj" else layer.input_layernorm.weight.shape[0]
        bits = _quantized_bits(reader, prefix + ".mlp.shared_expert." + name, int(input_dims))
        replacement = _new_quantized_linear(nn, int(input_dims), 1, bits)
        _install_quantized_linear(replacement, reader, mx, prefix + ".mlp.shared_expert." + name, bits)
        setattr(shared, name, replacement)
    shared_gate_bits = _quantized_bits(reader, prefix + ".mlp.shared_expert_gate", layer.input_layernorm.weight.shape[0])
    shared_gate = _new_quantized_linear(nn, layer.input_layernorm.weight.shape[0], 1, shared_gate_bits)
    _install_quantized_linear(shared_gate, reader, mx, prefix + ".mlp.shared_expert_gate", shared_gate_bits)
    mlp.shared_expert_gate = shared_gate

    switch = mlp.switch_mlp
    for name in ("gate_proj", "up_proj", "down_proj"):
        input_dims = layer.input_layernorm.weight.shape[0] if name != "down_proj" else switch.gate_proj.weight.shape[1]
        bits = _quantized_bits(reader, prefix + ".mlp.switch_mlp." + name, int(input_dims))
        replacement = _new_quantized_switch(bits)
        _install_quantized_switch(replacement, reader, mx, prefix + ".mlp.switch_mlp." + name, bits)
        setattr(switch, name, replacement)

    layer.eval()
    mx.eval(layer.parameters())
    return layer, reader, args


def _configured_recurrent_dtype(model_dir: Path, mx: Any) -> Any:
    """Return the recurrent-state dtype declared by the pinned text config.

    mlx-lm 0.31.1's Qwen3.5 cache starts its ArraysCache state from the
    input dtype when the cache slot is empty.  The selected artifact declares
    ``mamba_ssm_dtype: float32``; seed that slot explicitly so a worker
    boundary and a continuous reference execute the same FP32 recurrence.
    """
    config = json.loads((model_dir / "config.json").read_text())
    text_config = config.get("text_config", config)
    value = text_config.get("mamba_ssm_dtype")
    if value == "float32":
        return mx.float32
    if value in ("bfloat16", "bf16"):
        return mx.bfloat16
    if value in ("float16", "f16"):
        return mx.float16
    raise LayerOracleError(f"unsupported mamba_ssm_dtype in pinned config: {value!r}")


def _configured_gated_delta_update(
    q: Any,
    k: Any,
    v: Any,
    a: Any,
    b: Any,
    A_log: Any,
    dt_bias: Any,
    state: Any | None = None,
    mask: Any | None = None,
    use_kernel: bool = True,
) -> tuple[Any, Any]:
    """FP32 recurrent adapter for the pinned config.

    The upstream 0.31.1 helper hard-codes its compiled output state to the
    input dtype (BF16), even when the artifact declares ``mamba_ssm_dtype``.
    This adapter keeps the public quantized projections and layer structure
    from that implementation, while making the declared state precision
    explicit.  On Metal it uses the same FP32-state kernel contract as the
    native Swift path; the bounded ops fallback is retained for the legacy
    CPU oracle.
    """
    import mlx.core as mx
    import mlx.nn as nn

    # Keep the same promotion points as mlx-swift-lm's implementation:
    # sigmoid and the a + dt_bias softplus see the quantized projection dtype,
    # while the A_log exponential and the recurrent arithmetic are FP32.
    beta = mx.sigmoid(b).astype(mx.float32)
    decay_rate = mx.exp(-mx.exp(A_log.astype(mx.float32)) * nn.softplus(a + dt_bias))
    batch = q.shape[0]
    time_steps = q.shape[1]
    key_heads = q.shape[2]
    key_dim = q.shape[3]
    value_heads = v.shape[2]
    value_dim = v.shape[3]
    if state is None:
        state = mx.zeros((batch, value_heads, value_dim, key_dim), dtype=mx.float32)
    else:
        state = state.astype(mx.float32)

    # The first Q2.7 matched-core fixture used the mathematically equivalent
    # ops loop here.  That is a useful CPU reference, but it is not the same
    # execution as the app's Metal kernel: the recurrent reduction order
    # accumulates a small error over a long cached decode.  Keep the oracle
    # independent while matching the actual Metal kernel's output/state
    # dtypes and reduction order for the pinned Q2.7 contract.
    if use_kernel and mx.metal.is_available() and mx.default_device() == mx.gpu:
        kernel = _configured_gated_delta_kernel(mx, has_mask=mask is not None)
        inputs = [q, k, v, decay_rate, beta, state, mx.array(time_steps)]
        if mask is not None:
            inputs.append(mask)
        outputs = kernel(
            inputs=inputs,
            template=[
                ("InT", q.dtype),
                ("StT", state.dtype),
                ("Dk", key_dim),
                ("Dv", value_dim),
                ("Hk", key_heads),
                ("Hv", value_heads),
            ],
            grid=(32, value_dim, batch * value_heads),
            threadgroup=(32, 4, 1),
            output_shapes=[(batch, time_steps, value_heads, value_dim), state.shape],
            output_dtypes=[q.dtype, state.dtype],
        )
        return outputs[0], outputs[1]

    if value_heads // key_heads > 1:
        repeat = value_heads // key_heads
        q = mx.repeat(q, repeat, axis=-2)
        k = mx.repeat(k, repeat, axis=-2)

    outputs = []
    for index in range(time_steps):
        old_state = state
        # Let MLX promote each product with the FP32 state, as the native
        # gated-delta ops/kernel do, rather than inserting earlier casts.
        q_t = q[:, index]
        k_t = k[:, index]
        v_t = v[:, index]
        g_t = decay_rate[:, index]
        beta_t = beta[:, index]
        state = state * g_t[..., None, None]
        kv_mem = (state * k_t[..., None, :]).sum(axis=-1)
        delta = (v_t - kv_mem) * beta_t[..., None]
        state = state + k_t[..., None, :] * delta[..., None]
        y_t = (state * q_t[..., None, :]).sum(axis=-1)
        if mask is not None:
            mask_t = mask[:, index]
            state = mx.where(mask_t.reshape(batch, 1, 1, 1), state, old_state)
        outputs.append(y_t.astype(q.dtype))
    return mx.stack(outputs, axis=1), state


def _configured_gated_delta_kernel(mx: Any, has_mask: bool) -> Any:
    """Create the independent Python Metal kernel used by the Q2.7 oracle.

    This is deliberately a separate implementation from the Swift package,
    but keeps its source and launch contract aligned so parity compares the
    same MLX 0.31.1 Metal computation rather than an ops approximation.
    """
    mask_source = "mask[b_idx * T + t]" if has_mask else "true"
    suffix = "_mask" if has_mask else ""
    source = f"""
        auto n = thread_position_in_grid.z;
        auto b_idx = n / Hv;
        auto hv_idx = n % Hv;
        auto hk_idx = hv_idx / (Hv / Hk);
        constexpr int n_per_t = Dk / 32;

        auto q_ = q + b_idx * T * Hk * Dk + hk_idx * Dk;
        auto k_ = k + b_idx * T * Hk * Dk + hk_idx * Dk;
        auto v_ = v + b_idx * T * Hv * Dv + hv_idx * Dv;
        y += b_idx * T * Hv * Dv + hv_idx * Dv;

        auto dk_idx = thread_position_in_threadgroup.x;
        auto dv_idx = thread_position_in_grid.y;

        auto i_state = state_in + (n * Dv + dv_idx) * Dk;
        auto o_state = state_out + (n * Dv + dv_idx) * Dk;

        float state[n_per_t];
        for (int i = 0; i < n_per_t; ++i) {{
          auto s_idx = n_per_t * dk_idx + i;
          state[i] = static_cast<float>(i_state[s_idx]);
        }}

        auto g_ = g + b_idx * T * Hv;
        auto beta_ = beta + b_idx * T * Hv;
        for (int t = 0; t < T; ++t) {{
          if ({mask_source}) {{
            float kv_mem = 0.0f;
            for (int i = 0; i < n_per_t; ++i) {{
              auto s_idx = n_per_t * dk_idx + i;
              state[i] = state[i] * g_[hv_idx];
              kv_mem += state[i] * k_[s_idx];
            }}
            kv_mem = simd_sum(kv_mem);

            auto delta = (v_[dv_idx] - kv_mem) * beta_[hv_idx];
            float out = 0.0f;
            for (int i = 0; i < n_per_t; ++i) {{
              auto s_idx = n_per_t * dk_idx + i;
              state[i] = state[i] + k_[s_idx] * delta;
              out += state[i] * q_[s_idx];
            }}
            out = simd_sum(out);
            if (thread_index_in_simdgroup == 0) {{
              y[dv_idx] = static_cast<InT>(out);
            }}
          }} else {{
            y[dv_idx] = static_cast<InT>(0);
          }}
          q_ += Hk * Dk;
          k_ += Hk * Dk;
          v_ += Hv * Dv;
          y += Hv * Dv;
          g_ += Hv;
          beta_ += Hv;
        }}
        for (int i = 0; i < n_per_t; ++i) {{
          auto s_idx = n_per_t * dk_idx + i;
          o_state[s_idx] = static_cast<StT>(state[i]);
        }}
    """
    input_names = ["q", "k", "v", "g", "beta", "state_in", "T"]
    if has_mask:
        input_names.append("mask")
    return mx.fast.metal_kernel(
        # Reuse mlx-lm's stable kernel name so MLX can share its existing
        # Metal pipeline cache across the short-lived layer workers.  The
        # FP32 ``StT`` specialization remains distinct at launch time.
        name=f"gated_delta_step{suffix}",
        input_names=input_names,
        output_names=["y", "state_out"],
        source=source,
    )


def _make_cache(layer: Any, cache_module: Any, recurrent_dtype: Any | None = None) -> Any:
    if not layer.is_linear:
        return cache_module.KVCache()
    cache = cache_module.ArraysCache(size=2)
    if recurrent_dtype is not None:
        import mlx.core as mx

        attention = layer.linear_attn
        cache[1] = mx.zeros(
            (1, attention.num_v_heads, attention.head_v_dim, attention.head_k_dim),
            dtype=recurrent_dtype,
        )
    return cache


def _deterministic_input(mx: Any, length: int = 2) -> Any:
    values = mx.arange(length * 2048, dtype=mx.float32).reshape(1, length, 2048)
    values = (values % 97 - 48) / 97.0
    return values.astype(mx.bfloat16)


def _materialize_state(cache: Any, mx: Any) -> list[Any]:
    arrays = _cache_arrays(cache)
    mx.eval(*arrays)
    return arrays


def _save_safetensors_atomic(path: Path, values: dict[str, Any], mx: Any) -> None:
    """Write a bounded tensor artifact without exposing a partial destination."""
    path.parent.mkdir(parents=True, exist_ok=True)
    # MLX infers the serializer from the filename suffix. Keep a
    # `.safetensors` suffix on the temporary path so the write is completed
    # at the expected location before the atomic rename.
    temporary = path.with_name(path.stem + ".tmp" + path.suffix)
    temporary.unlink(missing_ok=True)
    try:
        mx.save_safetensors(temporary.as_posix(), values)
        temporary.replace(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _save_continuation(path: Path, output: Any, cache: Any, mx: Any, metadata: dict[str, Any]) -> None:
    values: dict[str, Any] = {"output": output}
    for index, array in enumerate(_cache_arrays(cache)):
        values[f"cache.{index}"] = array
    _save_safetensors_atomic(path, values, mx)
    _json_write(path.with_suffix(path.suffix + ".json"), {"cacheType": type(cache).__name__, **metadata})


def _load_continuation(path: Path, cache: Any, mx: Any) -> tuple[Any, Any]:
    values = mx.load(path.as_posix())
    output = values.pop("output")
    state = [values[key] for key in sorted(values) if key.startswith("cache.")]
    cache.state = state
    if hasattr(cache, "offset"):
        cache.offset = int(json.loads(path.with_suffix(path.suffix + ".json").read_text()).get("positionAfter", 0))
    return output, cache


def _save_cache_only(path: Path, cache: Any, mx: Any, metadata: dict[str, Any]) -> None:
    values = {f"cache.{index}": array for index, array in enumerate(_cache_arrays(cache))}
    _save_safetensors_atomic(path, values, mx)
    _json_write(path.with_suffix(path.suffix + ".json"), {"cacheType": type(cache).__name__, **metadata})


def _load_cache_only(path: Path, cache: Any, mx: Any) -> None:
    values = mx.load(path.as_posix())
    state = [values[key] for key in sorted(values) if key.startswith("cache.")]
    cache.state = state
    # A layer worker is a separate process.  Reloading its state must also
    # restore the attention cache's logical offset; otherwise every streamed
    # prefill group and decode step would construct its mask/RoPE position as
    # if the cache were empty.  ArraysCache (GatedDeltaNet) intentionally has
    # no offset and keeps its recurrent position in the state arrays.
    metadata_path = path.with_suffix(path.suffix + ".json")
    if hasattr(cache, "offset") and metadata_path.is_file():
        metadata = json.loads(metadata_path.read_text())
        cache.offset = int(metadata.get("positionAfter", 0))


def _load_hidden(path: Path, mx: Any) -> Any:
    values = mx.load(path.as_posix())
    if "hidden" not in values:
        raise LayerOracleError(f"hidden-state file has no hidden tensor: {path}")
    hidden = values["hidden"]
    mx.eval(hidden)
    return hidden


def _save_hidden(path: Path, hidden: Any, mx: Any) -> None:
    mx.eval(hidden)
    _save_safetensors_atomic(path, {"hidden": hidden}, mx)


def _explicit_attention(
    queries: Any,
    keys: Any,
    values: Any,
    scale: float,
    mask: Any,
    mx: Any,
) -> Any:
    """Q2.13 ordinary-MLX attention contract used by Q2.14.

    This deliberately mirrors the versioned Q2.13 fixture producer rather
    than calling the fused SDPA helper.  Inputs are already in
    ``[batch, heads, sequence, head_dim]`` layout and are expected to be
    evaluated only at the caller's normal layer boundary.
    """
    repeats = queries.shape[1] // keys.shape[1]
    expanded_keys = mx.repeat(keys, repeats, axis=1)
    expanded_values = mx.repeat(values, repeats, axis=1)
    q_float = queries.astype(mx.float32)
    k_float = expanded_keys.astype(mx.float32)
    v_float = expanded_values.astype(mx.float32)
    transposed_keys = k_float.transpose(0, 1, 3, 2)
    scaled_scores = mx.matmul(
        q_float * mx.array(scale, dtype=mx.float32), transposed_keys
    )
    if mask is None:
        mask = mx.ones((queries.shape[2], keys.shape[2]), dtype=mx.bool_)
    elif isinstance(mask, str):
        if mask != "causal":
            raise LayerOracleError(f"unsupported explicit attention mask: {mask}")
        mask = mx.tril(
            mx.ones((queries.shape[2], keys.shape[2]), dtype=mx.bool_)
        )
    masked_scores = mx.where(
        mask[None, None, :, :],
        scaled_scores,
        mx.finfo(mx.float32).min,
    )
    probabilities = mx.softmax(masked_scores, axis=-1, precise=True)
    weighted_output = mx.matmul(probabilities, v_float)
    return weighted_output.astype(mx.bfloat16)


def _layer_call_explicit(layer: Any, x: Any, cache: Any, mx: Any) -> Any:
    """Run one complete upstream decoder layer with explicit full attention."""
    import mlx.nn as nn
    from mlx_lm.models.base import create_attention_mask

    if layer.is_linear:
        return layer(x, mask=None, cache=cache)

    attention_input = layer.input_layernorm(x)
    attention = layer.self_attn
    B, S, _ = attention_input.shape
    query_projection = attention.q_proj(attention_input)
    queries, gate = mx.split(
        query_projection.reshape(B, S, attention.num_attention_heads, -1),
        2,
        axis=-1,
    )
    gate = gate.reshape(B, S, -1)
    keys, values = attention.k_proj(attention_input), attention.v_proj(attention_input)
    queries = attention.q_norm(queries).transpose(0, 2, 1, 3)
    keys = attention.k_norm(
        keys.reshape(B, S, attention.num_key_value_heads, -1)
    ).transpose(0, 2, 1, 3)
    values = values.reshape(B, S, attention.num_key_value_heads, -1).transpose(
        0, 2, 1, 3
    )

    mask = create_attention_mask(x, cache, return_array=True)
    if cache is not None:
        queries = attention.rope(queries, offset=cache.offset)
        keys = attention.rope(keys, offset=cache.offset)
        keys, values = cache.update_and_fetch(keys, values)
    else:
        queries = attention.rope(queries)
        keys = attention.rope(keys)

    output = _explicit_attention(
        queries,
        keys,
        values,
        attention.scale,
        mask,
        mx,
    )
    attention_output = attention.o_proj(
        output.transpose(0, 2, 1, 3).reshape(B, S, -1) * mx.sigmoid(gate)
    )
    h = x + attention_output
    result = h + layer.mlp(layer.post_attention_layernorm(h))
    _materialize_state(cache, mx)
    mx.eval(result)
    return result


def _layer_call(
    layer: Any,
    x: Any,
    cache: Any,
    layer_module: Any,
    mx: Any,
    attention_strategy: str = "fused",
) -> Any:
    if layer.is_linear:
        mask = None
    else:
        from mlx_lm.models.base import create_attention_mask

        mask = create_attention_mask(x, cache)
    if attention_strategy == "explicit" and not layer.is_linear:
        output = _layer_call_explicit(layer, x, cache, mx)
    else:
        output = layer(x, mask=mask, cache=cache)
    _materialize_state(cache, mx)
    mx.eval(output)
    return output


def _layer_call_components(
    layer: Any, x: Any, cache: Any, layer_module: Any, mx: Any, position: int = 0,
    layer_index: int = 0, attention_strategy: str = "fused"
) -> tuple[Any, dict[str, Any]]:
    """Run one layer once while retaining bounded component handles.

    This mirrors ``DecoderLayer.__call__`` line-for-line.  It is only used by
    the Q2.5 boundary probe to separate recurrent/attention drift from MoE
    projection or router drift; the normal layer worker remains unchanged.
    """
    import mlx.nn as nn

    linear_projections = None
    linear_attention = None
    full_attention = None
    if layer.is_linear:
        attention_input = layer.input_layernorm(x)
        linear = layer.linear_attn
        B, S, _ = attention_input.shape
        linear_projections = {
            "qkv": linear.in_proj_qkv(attention_input),
            "z": linear.in_proj_z(attention_input),
            "b": linear.in_proj_b(attention_input),
            "a": linear.in_proj_a(attention_input),
        }
        qkv = linear_projections["qkv"]
        z = linear_projections["z"].reshape(B, S, linear.num_v_heads, linear.head_v_dim)
        a = linear_projections["a"]
        b = linear_projections["b"]
        if cache is not None and cache[0] is not None:
            conv_state = cache[0]
        else:
            conv_state = mx.zeros(
                (B, linear.conv_kernel_size - 1, linear.conv_dim),
                dtype=attention_input.dtype,
            )
        conv_input = mx.concatenate([conv_state, qkv], axis=1)
        if cache is not None:
            cache[0] = conv_input[:, -(linear.conv_kernel_size - 1) :]
        conv_output = nn.silu(linear.conv1d(conv_input))
        q, k, v = [
            t.reshape(B, S, h, d)
            for t, h, d in zip(
                mx.split(conv_output, [linear.key_dim, 2 * linear.key_dim], -1),
                [linear.num_k_heads, linear.num_k_heads, linear.num_v_heads],
                [linear.head_k_dim, linear.head_k_dim, linear.head_v_dim],
            )
        ]
        state = cache[1] if cache is not None else None
        inv_scale = k.shape[-1] ** -0.5
        q_normed = (inv_scale**2) * mx.fast.rms_norm(q, None, 1e-6)
        k_normed = inv_scale * mx.fast.rms_norm(k, None, 1e-6)
        gated_output, state = _configured_gated_delta_update(
            q_normed,
            k_normed,
            v,
            a,
            b,
            linear.A_log,
            linear.dt_bias,
            state,
            None,
        )
        if cache is not None:
            cache[1] = state
        normalized_output = linear.norm(gated_output, z)
        attention_output = linear.out_proj(normalized_output.reshape(B, S, -1))
        linear_attention = {
            "convOutput": conv_output,
            "qNormed": q_normed,
            "kNormed": k_normed,
            "v": v,
            "gatedOutput": gated_output,
            "normalizedOutput": normalized_output,
        }
    else:
        attention_input = layer.input_layernorm(x)
        from mlx_lm.models.base import create_attention_mask, scaled_dot_product_attention

        attention_mask = create_attention_mask(
            x, cache, return_array=attention_strategy == "explicit"
        )
        attention = layer.self_attn
        B, S, _ = attention_input.shape
        query_projection = attention.q_proj(attention_input)
        queries, gate = mx.split(
            query_projection.reshape(B, S, attention.num_attention_heads, -1),
            2,
            axis=-1,
        )
        gate = gate.reshape(B, S, -1)
        keys, values = attention.k_proj(attention_input), attention.v_proj(attention_input)
        queries = attention.q_norm(queries).transpose(0, 2, 1, 3)
        keys = attention.k_norm(
            keys.reshape(B, S, attention.num_key_value_heads, -1)
        ).transpose(0, 2, 1, 3)
        values = values.reshape(B, S, attention.num_key_value_heads, -1).transpose(
            0, 2, 1, 3
        )
        if cache is not None:
            queries = attention.rope(queries, offset=cache.offset)
            keys = attention.rope(keys, offset=cache.offset)
            # Keep the diagnostic key/value fields scoped to the current
            # token group, matching the native seam.  The cache update is a
            # separate lifetime boundary and feeds only the attention op.
            current_keys, current_values = keys, values
            keys, values = cache.update_and_fetch(keys, values)
        else:
            queries = attention.rope(queries)
            keys = attention.rope(keys)
            current_keys, current_values = keys, values
        if attention_strategy == "explicit":
            attention_values = _explicit_attention(
                queries, keys, values, attention.scale, attention_mask, mx
            )
        else:
            attention_values = scaled_dot_product_attention(
                queries,
                keys,
                values,
                cache=cache,
                scale=attention.scale,
                mask=attention_mask,
            )
        attention_output = attention.o_proj(
            attention_values.transpose(0, 2, 1, 3).reshape(B, S, -1)
            * mx.sigmoid(gate)
        )
        full_attention = {
            "queryProjection": query_projection,
            "gate": gate,
            "queries": queries,
            "keys": current_keys,
            "values": current_values,
            "attentionValues": attention_values.transpose(0, 2, 1, 3).reshape(B, S, -1),
            "gatedValues": attention_values.transpose(0, 2, 1, 3).reshape(B, S, -1)
            * mx.sigmoid(gate),
        }
    h = x + attention_output
    post_attention_input = layer.post_attention_layernorm(h)
    # Reconstruct the MoE decomposition directly from its submodules. Calling
    # the individual branches once keeps the diagnostic output tied to the
    # same router decision and avoids a second hidden MoE invocation.
    router_logits = layer.mlp.gate(post_attention_input)
    probabilities = mx.softmax(router_logits, axis=-1, precise=True)
    k = layer.mlp.top_k
    kth = probabilities.shape[-1] - k
    expert_ids = mx.argpartition(probabilities, kth=kth, axis=-1)[..., kth:]
    scores = mx.take_along_axis(probabilities, expert_ids, axis=-1)
    if layer.mlp.norm_topk_prob:
        scores = scores / scores.sum(axis=-1, keepdims=True)
    routed_output = layer.mlp.switch_mlp(post_attention_input, expert_ids)
    routed_combined = (routed_output * mx.expand_dims(scores, axis=-1)).sum(axis=-2)
    shared_output = mx.sigmoid(layer.mlp.shared_expert_gate(post_attention_input)) * layer.mlp.shared_expert(post_attention_input)
    mlp_output = routed_combined + shared_output
    output = h + mlp_output
    _materialize_state(cache, mx)
    diagnostic_arrays = list(linear_attention.values()) if linear_attention is not None else []
    if full_attention is not None:
        diagnostic_arrays.extend(full_attention.values())
    mx.eval(
        attention_input,
        attention_output,
        h,
        post_attention_input,
        mlp_output,
        router_logits,
        routed_output,
        routed_combined,
        shared_output,
        *diagnostic_arrays,
        output,
    )

    # The decomposition executes the MoE branches directly, so the normal
    # monkey-patched model call does not observe its router.  Retain compact
    # scalar records here; without them an oracle boundary can silently have
    # an empty routing section and cannot distinguish a K=8 selection change
    # from a later expert aggregation mismatch.
    mx.eval(router_logits, expert_ids, scores)
    raw_rows = router_logits.reshape(-1, router_logits.shape[-1]).tolist()
    id_rows = expert_ids.reshape(-1, expert_ids.shape[-1]).tolist()
    score_rows = scores.reshape(-1, scores.shape[-1]).tolist()
    router_records: list[dict[str, Any]] = []
    for token_index, selected in enumerate(id_rows):
        row = [float(value) for value in raw_rows[token_index]]
        top = sorted(range(len(row)), key=lambda index: row[index], reverse=True)[: ROUTING_K + 1]
        router_records.append({
            "layer": int(layer_index),
            "position": int(position + token_index),
            "expertIDs": [int(value) for value in selected],
            "scores": [float(value) for value in score_rows[token_index]],
            "topLogitIDs": [int(value) for value in top],
            "topLogits": [row[index] for index in top],
            "kthScore": row[top[ROUTING_K - 1]],
            "kPlusOneScore": row[top[ROUTING_K]],
            "kGap": row[top[ROUTING_K - 1]] - row[top[ROUTING_K]],
        })
    return output, {
        "attentionInput": attention_input,
        "attentionOutput": attention_output,
        "postAttentionResidual": h,
        "postAttentionInput": post_attention_input,
        "mlpOutput": mlp_output,
        "routerInput": post_attention_input,
        "routerLogits": router_logits,
        # Kept as an in-process handle so the opt-in raw-router worker can
        # serialize the exact selector vector even when component capture is
        # enabled. It is omitted from ordinary component JSON below.
        "selectorScores": probabilities,
        "routedOutput": routed_combined,
        "sharedOutput": shared_output,
        "linearProjections": linear_projections,
        "linearAttention": linear_attention,
        "fullAttention": full_attention,
        "router": router_records,
    }


def _worker_layer(args: argparse.Namespace) -> int:
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_lm.models import cache as cache_module

    # The historical CPU oracle is pinned to MLX 0.32.2, while Q2.7's
    # matched-core Metal oracle intentionally uses the app's MLX 0.31.1.
    # Both use the same mlx-lm model implementation; reject everything else
    # rather than silently running an unrecorded runtime.
    if package_version("mlx") not in {"0.31.1", "0.32.2"} or package_version("mlx-lm") != "0.31.1":
        raise LayerOracleError(f"pinned reference mismatch: mlx={package_version('mlx')} mlx-lm={package_version('mlx-lm')}")
    mx.set_default_device(mx.cpu if args.device == "cpu" else mx.default_device())
    model_dir = Path(args.model_dir).resolve()
    layer, reader, _ = _build_layer(model_dir, args.layer_index, mx, nn)
    cache = _make_cache(layer, cache_module, _configured_recurrent_dtype(model_dir, mx))
    x = _deterministic_input(mx, args.input_length)
    output = _layer_call(
        layer, x, cache, cache_module, mx,
        attention_strategy=getattr(args, "attention_strategy", "fused"))
    result: dict[str, Any] = {
        "status": "LAYER_COMPLETE",
        "layer": args.layer_index,
        "layerKind": "linear_attention" if layer.is_linear else "full_attention",
        "inputShape": list(x.shape),
        "output": _array_summary(output, mx),
        "cache": _cache_summary(cache, mx, capture_full=args.capture_cache_full),
        "requestedBytes": reader.requested_bytes,
        "completedBytes": reader.completed_bytes,
        "readCalls": reader.read_calls,
        "workerPeakRSSBytes": _self_peak_rss_bytes(),
        "device": args.device,
        "mlx": package_version("mlx"),
        "mlxLM": package_version("mlx-lm"),
        "attentionStrategy": getattr(args, "attention_strategy", "fused"),
        "attentionContract": (
            "explicit ordinary MLX attention"
            if getattr(args, "attention_strategy", "fused") == "explicit"
            else "fused SDPA"
        ),
    }
    if args.state_out:
        _save_continuation(
            Path(args.state_out),
            output,
            cache,
            mx,
            {"layer": args.layer_index, "positionAfter": args.input_length},
        )
        result["statePath"] = str(args.state_out)
    _json_write(Path(args.result_out), result)
    mx.eval(*_cache_arrays(cache))
    try:
        mx.clear_cache()
    except AttributeError:
        pass
    del layer, cache, output
    gc.collect()
    return 0


def _install_router_trace(
    layer: Any,
    layer_index: int,
    position: int,
    mx: Any,
    positions: set[int] | None = None,
    capture_full: bool = False,
    raw_layer: int | None = None,
    raw_position: int | None = None,
) -> tuple[list[dict[str, Any]], Any, Any] | None:
    if not getattr(layer.mlp, "gate", None) or not getattr(layer, "mlp", None):
        return None
    from mlx_lm.models.qwen3_next import Qwen3NextSparseMoeBlock

    records: list[dict[str, Any]] = []
    original = Qwen3NextSparseMoeBlock.__call__

    def traced(self: Any, x: Any) -> Any:
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
        for token_index, selected in enumerate(id_rows):
            absolute_position = position + token_index
            if positions is not None and absolute_position not in positions:
                continue
            row = [float(value) for value in raw_rows[token_index]]
            top = sorted(range(len(row)), key=lambda index: row[index], reverse=True)[: ROUTING_K + 1]
            record = {
                "layer": layer_index,
                "position": absolute_position,
                "expertIDs": [int(value) for value in selected],
                "scores": [float(value) for value in score_rows[token_index]],
                "topLogitIDs": [int(value) for value in top],
                "topLogits": [row[index] for index in top],
                "kthScore": row[top[ROUTING_K - 1]],
                "kPlusOneScore": row[top[ROUTING_K]],
                "kGap": row[top[ROUTING_K - 1]] - row[top[ROUTING_K]],
            }
            if (
                capture_full
                and raw_layer == layer_index
                and raw_position == absolute_position
            ):
                record["raw"] = {
                    "position": absolute_position,
                    "routerInput": _array_summary(
                        x[0, token_index],
                        mx,
                        sample_count=int(x.shape[-1]),
                        capture_full=True,
                    ),
                    "routerLogits": _array_summary(
                        raw[0, token_index],
                        mx,
                        sample_count=int(raw.shape[-1]),
                        capture_full=True,
                    ),
                    "selectorScores": _array_summary(
                        probabilities[0, token_index],
                        mx,
                        sample_count=int(probabilities.shape[-1]),
                        capture_full=True,
                    ),
                    "selectedExpertIDs": [int(value) for value in selected],
                    "selectedNormalizedScores": [
                        float(value) for value in score_rows[token_index]
                    ],
                }
            records.append(record)
        return original(self, x)

    Qwen3NextSparseMoeBlock.__call__ = traced
    return records, Qwen3NextSparseMoeBlock, original


def _worker_layer_forward(args: argparse.Namespace) -> int:
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_lm.models import cache as cache_module

    model_dir = Path(args.model_dir).resolve()
    layer, reader, _ = _build_layer(model_dir, args.layer_index, mx, nn)
    cache = _make_cache(layer, cache_module, _configured_recurrent_dtype(model_dir, mx))
    if args.cache_in:
        _load_cache_only(Path(args.cache_in), cache, mx)
    cache_before = None
    if args.capture_cache_before:
        cache_before = _cache_summary(
            cache, mx, capture_full=args.capture_full_components)
    hidden = _load_hidden(Path(args.input_path), mx)
    trace_positions = set(args.trace_positions) if args.trace_positions else None
    trace = (
        _install_router_trace(
            layer,
            args.layer_index,
            args.position,
            mx,
            trace_positions,
            capture_full=args.capture_full_router,
            raw_layer=args.raw_router_layer,
            raw_position=args.raw_router_position,
        )
        if args.trace_router else None
    )
    try:
        if args.capture_components:
            output, components = _layer_call_components(
                layer,
                hidden,
                cache,
                cache_module,
                mx,
                position=args.position,
                layer_index=args.layer_index,
                attention_strategy=getattr(args, "attention_strategy", "fused"))
        else:
            # The full coordinator uses this ordinary path for most workers.
            # Carry the selected strategy through even when component capture
            # is disabled; otherwise an explicit run would silently execute
            # fused SDPA while recording ``attentionStrategy=explicit``.
            output = _layer_call(
                layer,
                hidden,
                cache,
                cache_module,
                mx,
                attention_strategy=getattr(args, "attention_strategy", "fused"),
            )
            components = None
    finally:
        if trace is not None:
            _, trace_type, original = trace
            trace_type.__call__ = original
    _save_hidden(Path(args.hidden_out), output, mx)
    _save_cache_only(Path(args.cache_out), cache, mx, {"layer": args.layer_index, "positionAfter": args.position + hidden.shape[1]})
    result = {
        "status": "LAYER_FORWARD_COMPLETE",
        "layer": args.layer_index,
        "layerKind": "linear_attention" if layer.is_linear else "full_attention",
        "positionBefore": args.position,
        "positionAfter": args.position + int(hidden.shape[1]),
        "inputShape": list(hidden.shape),
        # Boundary diagnostics deliberately retain only bounded summaries.
        # The per-token rows let the native test distinguish an input-state
        # mismatch from a later aggregation mismatch without persisting a
        # hidden-state tensor.
        "input": _array_summary(hidden, mx, capture_full=args.capture_full_components),
        "output": _array_summary(output, mx, capture_full=args.capture_full_components),
        "lastOutput": _array_summary(output[0, -1], mx, capture_full=args.capture_full_components),
        "tokenOutputs": [
            _array_summary(
                output[0, index], mx, capture_full=args.capture_full_components
            )
            for index in range(int(hidden.shape[1]))
        ],
        "cache": _cache_summary(cache, mx, capture_full=args.capture_cache_full),
        "router": (
            trace[0]
            if trace is not None and trace[0]
            else (components.get("router", []) if components else [])
        ),
        "requestedBytes": reader.requested_bytes,
        "completedBytes": reader.completed_bytes,
        "readCalls": reader.read_calls,
        "workerPeakRSSBytes": _self_peak_rss_bytes(),
        "attentionStrategy": getattr(args, "attention_strategy", "fused"),
        "attentionContract": (
            "explicit ordinary MLX attention"
            if getattr(args, "attention_strategy", "fused") == "explicit"
            else "fused SDPA"
        ),
    }
    if cache_before is not None:
        result["cacheBefore"] = cache_before
    if components is not None:
        result["components"] = {}
        for key, value in components.items():
            if value is None:
                continue
            if key == "linearProjections":
                result["components"][key] = {
                    name: _array_summary(
                        array, mx, capture_full=args.capture_full_components
                    ) for name, array in value.items()
                }
            elif key == "linearAttention":
                result["components"][key] = {
                    name: _array_summary(
                        array, mx, capture_full=args.capture_full_components
                    ) for name, array in value.items()
                }
            elif key == "fullAttention":
                result["components"][key] = {
                    name: _array_summary(
                        array, mx, capture_full=args.capture_full_components
                    ) for name, array in value.items()
                }
            elif key in {"router", "selectorScores"}:
                # Router records are already compact Python scalars and are
                # emitted at the layer top level, alongside native traces.
                # selectorScores is retained only long enough to construct a
                # raw record below; never duplicate its 256-way vector in the
                # generic component map.
                continue
            else:
                # Retain complete bounded inputs for the explicit router
                # replay probe.  A four-token hidden input is only 8192
                # values and the 256-way logits are 1024 values; all other
                # component summaries stay at the normal 16-value samples.
                sample_count = {
                    "routerInput": 8192,
                    "routerLogits": 1024,
                }.get(key, 16)
                if args.capture_full_components:
                    sample_count = int(value.size)
                result["components"][key] = _array_summary(
                    value,
                    mx,
                    sample_count=sample_count,
                    capture_full=args.capture_full_components,
                )
        if (
            args.capture_full_router
            and args.raw_router_layer == args.layer_index
            and args.raw_router_position is not None
            and "routerInput" in components
            and "routerLogits" in components
            and "selectorScores" in components
        ):
            raw_records = result["router"]
            input_rows = components["routerInput"].reshape(-1, components["routerInput"].shape[-1])
            logit_rows = components["routerLogits"].reshape(-1, components["routerLogits"].shape[-1])
            score_rows = components["selectorScores"].reshape(-1, components["selectorScores"].shape[-1])
            for record in raw_records:
                if int(record.get("position", -1)) != int(args.raw_router_position):
                    continue
                token_index = int(args.raw_router_position) - int(args.position)
                if token_index < 0 or token_index >= int(input_rows.shape[0]):
                    continue
                record["raw"] = {
                    "position": int(args.raw_router_position),
                    "routerInput": _array_summary(
                        input_rows[token_index],
                        mx,
                        sample_count=int(input_rows.shape[-1]),
                        capture_full=True,
                    ),
                    "routerLogits": _array_summary(
                        logit_rows[token_index],
                        mx,
                        sample_count=int(logit_rows.shape[-1]),
                        capture_full=True,
                    ),
                    "selectorScores": _array_summary(
                        score_rows[token_index],
                        mx,
                        sample_count=int(score_rows.shape[-1]),
                        capture_full=True,
                    ),
                    "selectedExpertIDs": [int(value) for value in record["expertIDs"]],
                    "selectedNormalizedScores": [float(value) for value in record["scores"]],
                }
    _json_write(Path(args.result_out), result)
    return 0


def _run_boundary(args: argparse.Namespace, inventory: dict[str, Any], output: Path) -> dict[str, Any]:
    """Run a compact prefill boundary probe through a bounded layer prefix.

    This is intentionally separate from the full fixture coordinator.  A
    one-layer run needs only the embedding worker and one layer worker per
    four-token group, which makes it practical for localizing the first
    semantic mismatch on a 16 GB host.  It still uses the same indexed ranges,
    cache serialization, and configured recurrent dtype as the full path.
    """
    model_dir = Path(args.model_dir).resolve()
    prompt_ids = _render_primary_prompt(model_dir, args.prompt_text)
    if not prompt_ids:
        raise LayerOracleError("boundary prompt rendered to no tokens")
    layer_count = max(1, min(40, int(args.boundary_layer_count)))
    prefill_group_size = 4
    if args.boundary_max_groups > 0:
        prompt_ids = prompt_ids[: args.boundary_max_groups * prefill_group_size]
        if not prompt_ids:
            raise LayerOracleError("boundary group limit removed every prompt token")
    states = output / "boundary-states"
    states.mkdir(parents=True, exist_ok=True)
    groups: list[dict[str, Any]] = []

    for group_index, start in enumerate(range(0, len(prompt_ids), prefill_group_size)):
        group_ids = prompt_ids[start:start + prefill_group_size]
        group_hidden = output / f"boundary-hidden-{group_index:03d}-embed.safetensors"
        embed_extra = [
            "--hidden-out", str(group_hidden),
            "--token-ids", *[str(value) for value in group_ids],
        ]
        if args.capture_full_components:
            embed_extra.append("--capture-full-components")
        embed = _run_staged_worker(
            args,
            output,
            f"boundary-{group_index:03d}-embed",
            "embed",
            embed_extra,
        )
        current_hidden = group_hidden
        layer_results: list[dict[str, Any]] = []
        trace_args = [
            "--trace-router",
            "--trace-positions",
            *[str(start + i) for i in range(len(group_ids))],
        ]
        for layer_index in range(layer_count):
            args.layer_index = layer_index
            next_hidden = output / f"boundary-hidden-{group_index:03d}-{layer_index:02d}.safetensors"
            cache_path = states / f"layer-{layer_index:02d}.safetensors"
            next_state = states / f"layer-{layer_index:02d}.next.safetensors"
            next_state.unlink(missing_ok=True)
            next_state.with_suffix(next_state.suffix + ".json").unlink(missing_ok=True)
            extra = [
                "--input-path", str(current_hidden),
                "--hidden-out", str(next_hidden),
                "--cache-out", str(next_state),
                "--position", str(start),
                *trace_args,
            ]
            # A boundary run still executes every preceding layer to carry
            # the real state forward, but a focused component capture should
            # retain full arrays for only the requested layer.  This keeps a
            # seven-group localization fixture compact on the 16 GB host.
            capture_components = (
                args.boundary_capture_layer < 0
                or layer_index == args.boundary_capture_layer
            )
            if capture_components:
                extra.append("--capture-components")
                if args.capture_full_components:
                    extra.append("--capture-full-components")
            if args.boundary_capture_cache_layer == layer_index:
                extra.append("--capture-cache-full")
            if cache_path.is_file():
                extra.extend(["--cache-in", str(cache_path)])
            result = _run_staged_worker(
                args,
                output,
                f"boundary-{group_index:03d}-layer-{layer_index:02d}",
                "layer-forward",
                extra,
            )
            layer_results.append({
                key: result[key]
                for key in (
                    "layer", "layerKind", "positionBefore", "positionAfter",
                    "input", "output", "lastOutput", "tokenOutputs", "cache",
                    "router", "components", "requestedBytes", "completedBytes", "readCalls",
                )
                if key in result
            })
            if current_hidden != group_hidden:
                current_hidden.unlink(missing_ok=True)
            current_hidden = next_hidden
            cache_path.unlink(missing_ok=True)
            cache_path.with_suffix(cache_path.suffix + ".json").unlink(missing_ok=True)
            next_state.replace(cache_path)
            next_state.with_suffix(next_state.suffix + ".json").replace(
                cache_path.with_suffix(cache_path.suffix + ".json")
            )
        groups.append({
            "groupIndex": group_index,
            "positionBefore": start,
            "positionAfter": start + len(group_ids),
            "tokenIDs": group_ids,
            "embedding": {
                "output": embed.get("output"),
                "requestedBytes": embed.get("requestedBytes"),
                "completedBytes": embed.get("completedBytes"),
                "readCalls": embed.get("readCalls"),
            },
            "layers": layer_results,
        })
        current_hidden.unlink(missing_ok=True)

    boundary = {
        # Keep the legacy v1 default for the earlier CPU boundary fixtures,
        # while allowing a caller to publish a separately identified
        # same-core reference without changing any model math.
        "fixtureFormatVersion": args.fixture_format_version,
        "fixtureID": "qwen35-k8-prefill-boundary",
        "artifact": {
            "repo": ARTIFACT_REPO,
            "revision": ARTIFACT_REVISION,
            "inventorySHA256": inventory.get("inventorySHA256", ARTIFACT_INVENTORY_SHA256),
        },
        "configSHA256": CONFIG_SHA256,
        "tokenizerSHA256": TOKENIZER_SHA256,
        "tokenizerConfigSHA256": TOKENIZER_CONFIG_SHA256,
        "templateSHA256": TEMPLATE_SHA256,
        "oracle": {
            "python": platform.python_version(),
            "mlx": package_version("mlx"),
            "mlxLM": package_version("mlx-lm"),
            "device": "cpu" if args.device == "cpu" else args.device,
            "runtimeLabel": args.runtime_label or f"python-mlx-core-{package_version('mlx')}-{args.device}",
            "recurrentKernel": (
                "python-metal-gated-delta-fp32-state"
                if args.device == "metal" else "python-ops-gated-delta-fp32-state"
            ),
            "recurrentState": "float32 (config mamba_ssm_dtype)",
            "recurrentStateSource": "text_config.mamba_ssm_dtype",
            "layerIsolated": True,
            "workerConcurrency": 1,
        },
        "semantics": {
            "routingK": ROUTING_K,
            "expertCount": 256,
            "sharedExpert": True,
            "thinking": False,
            "prefillGroupSize": prefill_group_size,
        },
        "promptTokenIDs": prompt_ids,
        "promptTokenCount": len(prompt_ids),
        "promptSHA256": _prompt_hash(prompt_ids),
        "prefillGroupSize": prefill_group_size,
        "captureFullComponents": bool(args.capture_full_components),
        "boundaryCaptureLayer": int(args.boundary_capture_layer),
        "boundaryCaptureCacheLayer": int(args.boundary_capture_cache_layer),
        "boundaryMaxGroups": int(args.boundary_max_groups),
        "boundaryLayerCount": layer_count,
        "groups": groups,
    }
    path = output / "boundary.json"
    _json_write(path, boundary)
    return {"status": "BOUNDARY_COMPLETE", "path": path, "boundary": boundary}


def _worker_embed(args: argparse.Namespace) -> int:
    import mlx.core as mx

    model_dir = Path(args.model_dir).resolve()
    token_ids = [int(value) for value in args.token_ids]
    if not token_ids:
        raise LayerOracleError("embedding stage received no token IDs")
    reader = SelectiveSafeTensorReader(model_dir)
    prefix = "language_model.model.embed_tokens"
    weights = reader.read_mlx_rows(prefix + ".weight", token_ids, mx)
    scales = reader.read_mlx_rows(prefix + ".scales", token_ids, mx)
    biases = reader.read_mlx_rows(prefix + ".biases", token_ids, mx)
    bits = _quantized_bits(reader, prefix, 2048)
    hidden = mx.dequantize(weights, scales, biases, group_size=64, bits=bits, mode="affine")
    hidden = hidden.reshape(1, len(token_ids), 2048)
    mx.eval(hidden)
    _save_hidden(Path(args.hidden_out), hidden, mx)
    _json_write(Path(args.result_out), {
        "status": "EMBED_COMPLETE",
        "tokenCount": len(token_ids),
        "inputTokenIDs": token_ids,
        "output": _array_summary(hidden, mx, capture_full=args.capture_full_components),
        "requestedBytes": reader.requested_bytes,
        "completedBytes": reader.completed_bytes,
        "readCalls": reader.read_calls,
        "workerPeakRSSBytes": _self_peak_rss_bytes(),
    })
    return 0


def _worker_head(args: argparse.Namespace) -> int:
    import mlx.core as mx
    import mlx.nn as nn

    model_dir = Path(args.model_dir).resolve()
    reader = SelectiveSafeTensorReader(model_dir)
    hidden = _load_hidden(Path(args.input_path), mx)
    norm = reader.read_mlx("language_model.model.norm.weight", mx)
    prefix = "language_model.lm_head"
    weight = reader.read_mlx(prefix + ".weight", mx)
    scales = reader.read_mlx(prefix + ".scales", mx)
    biases = reader.read_mlx(prefix + ".biases", mx)
    bits = _quantized_bits(reader, prefix, 2048)
    head = nn.QuantizedLinear(64, 1, bias=False, group_size=64, bits=bits, mode="affine")
    head.weight = weight
    head.scales = scales
    head.biases = biases
    head.group_size = 64
    head.bits = bits
    head.mode = "affine"
    head.freeze()
    # Only the final position selects the next token.  Slicing before the
    # quantized head keeps prefill logits bounded instead of allocating a
    # vocabulary matrix for every prompt position.
    normalized = mx.fast.rms_norm(hidden[:, -1:, :], norm, 1e-6)
    logits = head(normalized)
    mx.eval(logits)
    row = logits[0, -1]
    values = [float(value) for value in row.tolist()]
    top_ids = sorted(range(len(values)), key=lambda index: values[index], reverse=True)[:8]
    _json_write(Path(args.result_out), {
        "status": "HEAD_COMPLETE",
        "predictedToken": int(top_ids[0]),
        "topLogitIDs": [int(value) for value in top_ids],
        "topLogits": [values[index] for index in top_ids],
        "logitSummary": _array_summary(logits, mx),
        "requestedBytes": reader.requested_bytes,
        "completedBytes": reader.completed_bytes,
        "readCalls": reader.read_calls,
        "workerPeakRSSBytes": _self_peak_rss_bytes(),
    })
    return 0


def _worker_serialization_create(args: argparse.Namespace) -> int:
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_lm.models import cache as cache_module

    model_dir = Path(args.model_dir).resolve()
    layer, reader, _ = _build_layer(model_dir, args.layer_index, mx, nn)
    cache = _make_cache(layer, cache_module, _configured_recurrent_dtype(model_dir, mx))
    first = _deterministic_input(mx, 1)
    second = _deterministic_input(mx, 1) + mx.array(0.03125, dtype=mx.bfloat16)
    _layer_call(layer, first, cache, cache_module, mx)
    _save_continuation(Path(args.state_out), first, cache, mx, {"layer": args.layer_index, "positionAfter": 1})
    continuous = _layer_call(layer, second, cache, cache_module, mx)
    expected_path = Path(args.state_out).with_suffix(args.state_out.suffix + ".expected.safetensors")
    _save_continuation(expected_path, continuous, cache, mx, {"layer": args.layer_index, "positionAfter": 2})
    _json_write(Path(args.result_out), {
        "status": "SERIALIZATION_EXPECTED_WRITTEN",
        "layer": args.layer_index,
        "expectedPath": str(expected_path),
        "requestedBytes": reader.requested_bytes,
        "completedBytes": reader.completed_bytes,
        "readCalls": reader.read_calls,
        "workerPeakRSSBytes": _self_peak_rss_bytes(),
        "first": _array_summary(first, mx),
        "second": _array_summary(second, mx),
    })
    return 0


def _worker_serialization_resume(args: argparse.Namespace) -> int:
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_lm.models import cache as cache_module

    model_dir = Path(args.model_dir).resolve()
    layer, reader, _ = _build_layer(model_dir, args.layer_index, mx, nn)
    cache = _make_cache(layer, cache_module, _configured_recurrent_dtype(model_dir, mx))
    state_path = Path(args.state_in)
    _load_continuation(state_path, cache, mx)
    second = _deterministic_input(mx, 1) + mx.array(0.03125, dtype=mx.bfloat16)
    actual = _layer_call(layer, second, cache, cache_module, mx)
    actual_path = Path(args.result_out).with_suffix(Path(args.result_out).suffix + ".actual.safetensors")
    _save_continuation(actual_path, actual, cache, mx, {"layer": args.layer_index, "positionAfter": 2})
    expected_path = state_path.with_suffix(state_path.suffix + ".expected.safetensors")
    expected = mx.load(expected_path.as_posix())
    expected_output = expected.pop("output")
    actual_state = mx.load(actual_path.as_posix())
    actual_output = actual_state.pop("output")
    mx.eval(expected_output, actual_output, *expected.values(), *actual_state.values())
    def rel_l2(left: Any, right: Any) -> float:
        numerator = float(mx.linalg.norm((left.astype(mx.float32) - right.astype(mx.float32))).item())
        denominator = max(float(mx.linalg.norm(left.astype(mx.float32)).item()), 1e-12)
        return numerator / denominator
    comparisons = [{"name": "output", "relL2": rel_l2(expected_output, actual_output), "maxAbs": float(mx.max(mx.abs(expected_output.astype(mx.float32) - actual_output.astype(mx.float32))).item())}]
    for key in sorted(expected):
        comparisons.append({"name": key, "relL2": rel_l2(expected[key], actual_state[key]), "maxAbs": float(mx.max(mx.abs(expected[key].astype(mx.float32) - actual_state[key].astype(mx.float32))).item())})
    result = {
        "status": "SERIALIZATION_COMPARED",
        "layer": args.layer_index,
        "comparisons": comparisons,
        "requestedBytes": reader.requested_bytes,
        "completedBytes": reader.completed_bytes,
        "readCalls": reader.read_calls,
        "workerPeakRSSBytes": _self_peak_rss_bytes(),
        "passed": all(item["relL2"] <= args.rel_l2_tolerance and item["maxAbs"] <= args.max_abs_tolerance for item in comparisons),
    }
    _json_write(Path(args.result_out), result)
    if not result["passed"]:
        raise LayerOracleError(f"serialization comparison exceeded tolerances: {result}")
    return 0


def _worker_main(args: argparse.Namespace) -> int:
    if args.worker_kind in ("layer", "layer-attention"):
        return _worker_layer(args)
    if args.worker_kind == "layer-forward":
        return _worker_layer_forward(args)
    if args.worker_kind == "embed":
        return _worker_embed(args)
    if args.worker_kind == "head":
        return _worker_head(args)
    if args.worker_kind == "serialization-create":
        return _worker_serialization_create(args)
    if args.worker_kind == "serialization-resume":
        return _worker_serialization_resume(args)
    raise LayerOracleError(f"unknown worker kind {args.worker_kind}")


def _audit_full_loader() -> dict[str, Any]:
    candidates: list[Path] = []
    try:
        distribution = importlib.metadata.distribution("mlx-lm")
        candidates.append(Path(distribution.locate_file("mlx_lm/utils.py")))
    except importlib.metadata.PackageNotFoundError:
        pass
    candidates.extend(Path(path) / "mlx_lm/utils.py" for path in sys.path if path)
    source_path = next((path for path in candidates if path.is_file()), None)
    if source_path is None:
        return {"status": "SOURCE_UNAVAILABLE", "finding": "Install the pinned oracle environment before auditing the loader."}
    source = source_path.read_text(errors="replace")
    markers = {
        "globModelShards": "glob.glob(str(model_path / \"model*.safetensors\"))" in source,
        "globalWeightDictionary": "weights.update(mx.load(wf))" in source,
        "globalSanitize": "model.sanitize(weights)" in source,
        "eagerParameterEvaluation": "mx.eval(model.parameters())" in source,
    }
    qwen_source = source_path.parent / "models" / "qwen3_next.py"
    qwen35_source = source_path.parent / "models" / "qwen3_5.py"
    sanitize_source = ""
    if qwen35_source.is_file():
        sanitize_source += qwen35_source.read_text(errors="replace")
    if qwen_source.is_file():
        sanitize_source += qwen_source.read_text(errors="replace")
    markers["expertStackDuringSanitize"] = "mx.stack(to_join)" in sanitize_source
    return {
        "status": "AUDITED",
        "source": str(source_path),
        "markers": markers,
        "finding": (
            "The pinned full-model loader reads every model*.safetensors file into a global dictionary; "
            "Qwen sanitization may stack expert tensors and eager evaluation can materialize them. "
            "A memory guard around that path is not a layer bound."
        ),
        "layerWorkerDifference": "The new worker reads only indexed ranges under language_model.model.layers.<i> and exits after materialization.",
    }


def _run_worker(args: argparse.Namespace, root: Path, kind: str, extra: Iterable[str]) -> dict[str, Any]:
    result_path = root / f"{kind}.json"
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--role",
        "worker",
        "--worker-kind",
        kind,
        "--model-dir",
        str(args.model_dir),
        "--layer-index",
        str(args.layer_index),
        "--result-out",
        str(result_path),
        "--device",
        args.device,
        "--attention-strategy",
        args.attention_strategy,
        *list(extra),
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env={**os.environ, "PYTHONUNBUFFERED": "1"})
    guard = WorkerGuard(process, args, root)
    try:
        code, final = guard.wait()
    except Exception:
        _terminate(process)
        stdout, stderr = process.communicate()
        _json_write(root / f"{kind}-guard-abort.json", {
            "status": "RESOURCE_GUARD_ABORT",
            "command": command,
            "peakRSSBytes": guard.peak_rss,
            "samples": guard.samples,
            "stdoutTail": stdout[-4000:],
            "stderrTail": stderr[-4000:],
        })
        raise
    stdout, stderr = process.communicate()
    if code != 0 or not result_path.exists():
        raise LayerOracleError(f"{kind} worker failed code={code}: {stderr[-4000:]}")
    result = json.loads(result_path.read_text())
    result["resource"] = {
        "peakRSSBytes": max(guard.peak_rss, int(result.get("workerPeakRSSBytes", 0))),
        "guardPeakRSSBytes": guard.peak_rss,
        "workerPeakRSSBytes": result.get("workerPeakRSSBytes"),
        "lastSample": final,
        "samples": guard.samples,
        "stdoutTail": stdout[-1000:],
        "stderrTail": stderr[-1000:],
    }
    _json_write(result_path, result)
    return result


def _remove_artifact(path: Path) -> None:
    path.unlink(missing_ok=True)
    path.with_suffix(path.suffix + ".json").unlink(missing_ok=True)


def _replace_artifact(source: Path, destination: Path) -> None:
    """Atomically advance one rolling artifact and its optional sidecar."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    _remove_artifact(destination)
    source.replace(destination)
    source_meta = source.with_suffix(source.suffix + ".json")
    destination_meta = destination.with_suffix(destination.suffix + ".json")
    if source_meta.exists():
        _remove_artifact(destination_meta)
        source_meta.replace(destination_meta)


class RollingContinuation:
    """Keep exactly one committed state and one replacement state on disk.

    ``resume`` is deliberately opt-in.  A fresh run never overwrites a
    committed continuation, while a resumed run reuses only state written at
    a coordinator boundary.  The coordinator stores compact JSON metadata in
    this directory; tensor histories are never accumulated here.
    """

    def __init__(self, root: Path, identity: dict[str, Any], *, resume: bool = False) -> None:
        self.root = root
        self.identity = identity
        self.current = root / "state-current"
        self.next = root / "state-next"
        self.resumed = False
        # Recover a process interruption in the three-directory rename
        # sequence before creating missing directories.  A replacement that
        # never acquired the committed name is discarded in favor of the old
        # state; a committed replacement keeps its state and retires the old
        # directory.
        retired = root / "state-retired"
        if retired.exists():
            if not self.current.exists():
                if self.next.exists():
                    shutil.rmtree(self.next)
                retired.replace(self.current)
            else:
                shutil.rmtree(retired)
        self.current.mkdir(parents=True, exist_ok=True)
        self.next.mkdir(parents=True, exist_ok=True)
        self.manifest_path = self.current / "continuation-manifest.json"
        if self.manifest_path.exists():
            existing = json.loads(self.manifest_path.read_text())
            if existing != identity:
                raise LayerOracleError(
                    "rolling continuation manifest does not match artifact/config/tokenizer/strategy"
                )
            has_state = any(
                path.is_file()
                for path in self.current.iterdir()
                if path != self.manifest_path
            )
            # A caller must make an explicit resume decision rather than
            # silently overwriting a continuation from an earlier run.
            if has_state and not resume:
                raise LayerOracleError(
                    "rolling continuation already contains state; use --resume "
                    "only after a committed coordinator boundary, or choose a new output directory"
                )
            if resume and not has_state:
                raise LayerOracleError(
                    "--resume requested but rolling continuation has no committed state"
                )
            self.resumed = has_state and resume
        else:
            if resume:
                raise LayerOracleError(
                    "--resume requested but state-current/continuation-manifest.json is missing"
                )
            _json_write(self.manifest_path, identity)
        self._clear_next()

    @property
    def hidden_current(self) -> Path:
        return self.current / "hidden.safetensors"

    @property
    def hidden_next(self) -> Path:
        return self.next / "hidden.safetensors"

    @property
    def hidden_work_a(self) -> Path:
        return self.next / "hidden-work-a.safetensors"

    @property
    def hidden_work_b(self) -> Path:
        return self.next / "hidden-work-b.safetensors"

    def cache_current(self, layer: int) -> Path:
        return self.current / f"layer-{layer:02d}.safetensors"

    def cache_next(self, layer: int) -> Path:
        return self.next / f"layer-{layer:02d}.safetensors"

    def _clear_next(self) -> None:
        for path in list(self.next.iterdir()):
            if path.is_file() or path.is_symlink():
                path.unlink(missing_ok=True)
            elif path.is_dir():
                shutil.rmtree(path)

    def clear_next_hidden(self) -> None:
        _remove_artifact(self.hidden_next)
        _remove_artifact(self.hidden_work_a)
        _remove_artifact(self.hidden_work_b)

    def clear_next_cache(self, layer: int) -> None:
        _remove_artifact(self.cache_next(layer))

    def write_next_progress(self, progress: dict[str, Any]) -> None:
        _json_write(self.next / "progress.json", progress)

    def write_next_metadata(self, name: str, value: Any) -> None:
        """Write one bounded metadata record into the replacement state."""
        if Path(name).name != name:
            raise LayerOracleError(f"rolling metadata name must be a basename: {name}")
        _json_write(self.next / name, value)

    def commit_boundary(
        self,
        *,
        progress: dict[str, Any],
        metadata: dict[str, Any] | None = None,
        cache_layers: Iterable[int] = range(40),
    ) -> None:
        """Publish a complete state replacement as one coordinator boundary.

        Layer workers write only below ``state-next``.  ``state-current`` is
        left untouched until every replacement cache and the final hidden
        tensor are present.  The directory swap therefore cannot expose a
        mixture of two decode steps to an explicit ``--resume`` operation.
        """
        if not self.hidden_next.is_file():
            raise LayerOracleError("rolling hidden replacement is missing at boundary")
        required_caches = [self.cache_next(int(layer)) for layer in cache_layers]
        missing = [path.name for path in required_caches if not path.is_file()]
        if missing:
            raise LayerOracleError(
                "rolling boundary is missing replacement caches: " + ", ".join(missing[:4])
            )
        # The manifest belongs to the committed directory, so stage an
        # identical copy in the replacement before swapping directory names.
        _json_write(self.next / "continuation-manifest.json", self.identity)
        if metadata:
            for name, value in metadata.items():
                self.write_next_metadata(name, value)
        self.write_next_progress(progress)

        retired = self.root / "state-retired"
        if retired.exists():
            shutil.rmtree(retired)
        # Renaming directories changes names without duplicating tensor
        # payloads.  The old committed directory is retained only until the
        # replacement has the committed name, then cleared for reuse.
        self.current.replace(retired)
        try:
            self.next.replace(self.current)
            retired.replace(self.next)
        except BaseException:
            # Best-effort recovery for an interrupted rename sequence.  Do
            # not silently continue with an ambiguous continuation.
            if not self.current.exists() and self.next.exists():
                self.next.replace(self.current)
            raise
        self._clear_next()

    def write_progress(self, progress: dict[str, Any]) -> None:
        _json_write(self.current / "progress.json", progress)

    @property
    def progress_path(self) -> Path:
        return self.current / "progress.json"

    def read_progress(self) -> dict[str, Any] | None:
        if not self.progress_path.is_file():
            return None
        value = json.loads(self.progress_path.read_text())
        if not isinstance(value, dict):
            raise LayerOracleError("rolling progress metadata is not an object")
        return value

    def write_metadata(self, name: str, value: Any) -> None:
        """Atomically replace one bounded metadata record in the current state."""
        if Path(name).name != name:
            raise LayerOracleError(f"rolling metadata name must be a basename: {name}")
        _json_write(self.current / name, value)

    def read_metadata(self, name: str) -> Any | None:
        if Path(name).name != name:
            raise LayerOracleError(f"rolling metadata name must be a basename: {name}")
        path = self.current / name
        if not path.is_file():
            return None
        return json.loads(path.read_text())


class RollingDiskTracker:
    """Bounded diagnostic snapshots of actual oracle output occupancy."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.baseline_bytes = directory_size(root)
        self.peak_total_bytes = self.baseline_bytes
        self.peak_additional_bytes = 0
        self.samples: list[dict[str, Any]] = []

    def sample(self, label: str) -> None:
        total = directory_size(self.root)
        additional = max(0, total - self.baseline_bytes)
        self.peak_total_bytes = max(self.peak_total_bytes, total)
        self.peak_additional_bytes = max(self.peak_additional_bytes, additional)
        sample = {
            "label": label,
            "totalBytes": total,
            "additionalBytes": additional,
            "freeDiskBytes": free_disk_bytes(self.root),
        }
        if len(self.samples) < 256:
            self.samples.append(sample)

    def report(self) -> dict[str, Any]:
        return {
            "root": str(self.root),
            "baselineBytes": self.baseline_bytes,
            "peakTotalBytes": self.peak_total_bytes,
            "peakAdditionalBytes": self.peak_additional_bytes,
            "sampleCount": len(self.samples),
            "samples": self.samples,
            "sampling": "bounded-after-stage snapshots; worker guard monitors during execution",
        }


def _run_staged_worker(
    args: argparse.Namespace,
    root: Path,
    label: str,
    kind: str,
    extra: Iterable[str],
    *,
    cleanup: bool = False,
    disk_tracker: RollingDiskTracker | None = None,
) -> dict[str, Any]:
    stage_root = root / "stages" / label
    stage_root.mkdir(parents=True, exist_ok=True)
    try:
        result = _run_worker(args, stage_root, kind, extra)
    except BaseException:
        # Keep a compact abort record at the rolling root while removing the
        # worker's potentially large stage directory.
        abort_candidates = list(stage_root.glob("*-guard-abort.json"))
        if cleanup and abort_candidates:
            try:
                _json_write(root / f"{label}-guard-abort.json", json.loads(abort_candidates[0].read_text()))
            except (OSError, ValueError, json.JSONDecodeError):
                pass
        if cleanup:
            shutil.rmtree(stage_root, ignore_errors=True)
        if disk_tracker is not None:
            disk_tracker.sample(f"{label}:failed")
        raise
    else:
        if cleanup:
            shutil.rmtree(stage_root, ignore_errors=True)
        if disk_tracker is not None:
            disk_tracker.sample(label)
        return result


def _compact_layer_result(result: dict[str, Any]) -> dict[str, Any]:
    """Keep only bounded data needed to rebuild a resume/checkpoint record."""
    keys = (
        "layer",
        "layerKind",
        "positionBefore",
        "positionAfter",
        "lastOutput",
        "cache",
        "router",
    )
    return {key: result[key] for key in keys if key in result}


def _compact_head_result(result: dict[str, Any]) -> dict[str, Any]:
    """Persist only deterministic head data needed by a safe resume."""
    keys = ("predictedToken", "topLogitIDs", "topLogits", "logitSummary")
    return {key: result[key] for key in keys if key in result}


def _decode_boundary_phase(stop_reason: str, generated_count: int, max_output: int) -> str:
    """Classify a committed cached-decode boundary.

    ``output_limit`` is also the historical initial value used while a run is
    still in progress.  It is terminal only once the requested output count
    has actually been reached; otherwise the committed state must remain
    resumable.
    """
    if stop_reason == "eos":
        return "complete"
    if stop_reason == "output_limit" and generated_count >= max_output:
        return "complete"
    return "decode-ready"


def _render_primary_prompt(model_dir: Path, text: str) -> list[int]:
    from mlx_lm.tokenizer_utils import load as load_tokenizer

    tokenizer = load_tokenizer(model_dir)
    rendered = tokenizer.apply_chat_template(
        [{"role": "user", "content": text}],
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    if isinstance(rendered, dict):
        rendered = rendered["input_ids"]
    return [int(value) for value in rendered]


def _fixture_cache_layers(layer_results: list[dict[str, Any]], position_after: int) -> list[dict[str, Any]]:
    layers = []
    for result in layer_results:
        cache = dict(result["cache"])
        cache["layer"] = int(result["layer"])
        layers.append(cache)
    return layers


def _run_router_raw_prefix(
    args: argparse.Namespace,
    inventory: dict[str, Any],
    output: Path,
) -> dict[str, Any]:
    """Capture one raw router row with a teacher-forced layer prefix.

    The frozen Q2.7 output IDs are used as inputs after prefill.  Only layers
    through the disputed router are executed, but every stateful layer in
    that prefix advances in the same four-token/cached-token order as the
    full reference.  No vocabulary head or later layer is loaded.
    """
    import zipfile

    if args.reference_fixture is None:
        raise LayerOracleError("router-raw mode requires --reference-fixture")
    with zipfile.ZipFile(Path(args.reference_fixture).expanduser()) as archive:
        fixture = json.loads(archive.read("fixtures/primary.json"))
    prompt_ids = [int(value) for value in fixture["promptTokenIDs"]]
    forced_ids = [int(value) for value in fixture["generatedTokenIDs"][: args.max_output]]
    if not prompt_ids or len(forced_ids) < 8:
        raise LayerOracleError("router-raw mode requires the frozen prompt and at least eight output IDs")
    if args.raw_router_layer is None or args.raw_router_position is None:
        raise LayerOracleError("router-raw mode requires --raw-router-layer and --raw-router-position")
    prefix_count = max(1, min(40, args.raw_router_layer + 1))
    if args.raw_router_position < len(prompt_ids) or args.raw_router_position >= len(prompt_ids) + len(forced_ids):
        raise LayerOracleError("raw router position is outside the frozen teacher-forced sequence")

    model_dir = Path(args.model_dir).resolve()
    states = output / "states"
    states.mkdir(parents=True, exist_ok=True)
    group_size = 4
    raw_result: dict[str, Any] | None = None
    captured_results: dict[int, dict[str, Any]] = {}
    capture_layers = set(int(value) for value in (args.capture_layers or []))

    def run_prefix_token(token_ids: list[int], start: int, label: str) -> None:
        nonlocal raw_result
        group_hidden = output / f"{label}-embed.safetensors"
        _run_staged_worker(
            args,
            output,
            f"{label}-embed",
            "embed",
            ["--hidden-out", str(group_hidden), "--token-ids", *[str(value) for value in token_ids]],
        )
        current_hidden = group_hidden
        end = start + len(token_ids)
        for layer_index in range(prefix_count):
            args.layer_index = layer_index
            next_hidden = output / f"{label}-layer-{layer_index:02d}.safetensors"
            old_state = states / f"layer-{layer_index:02d}.safetensors"
            next_state = states / f"layer-{layer_index:02d}.next.safetensors"
            next_state.unlink(missing_ok=True)
            next_state.with_suffix(next_state.suffix + ".json").unlink(missing_ok=True)
            extra = [
                "--input-path", str(current_hidden),
                "--hidden-out", str(next_hidden),
                "--cache-out", str(next_state),
                "--position", str(start),
            ]
            if old_state.is_file():
                extra.extend(["--cache-in", str(old_state)])
            if layer_index == args.raw_router_layer and args.raw_router_position in range(start, end):
                extra.extend([
                    "--trace-router",
                    "--trace-positions", str(args.raw_router_position),
                    "--capture-full-router",
                    "--raw-router-layer", str(args.raw_router_layer),
                    "--raw-router-position", str(args.raw_router_position),
                ])
            if args.raw_router_position in range(start, end) and layer_index in capture_layers:
                if args.capture_components:
                    extra.append("--capture-components")
                if args.capture_full_components:
                    extra.append("--capture-full-components")
                if args.capture_cache_before:
                    extra.append("--capture-cache-before")
            result = _run_staged_worker(
                args,
                output,
                f"{label}-layer-{layer_index:02d}",
                "layer-forward",
                extra,
            )
            if layer_index == args.raw_router_layer and result.get("router"):
                raw_result = result
            if args.raw_router_position in range(start, end) and layer_index in capture_layers:
                captured_results[layer_index] = result
            if current_hidden != group_hidden:
                current_hidden.unlink(missing_ok=True)
            current_hidden = next_hidden
            if old_state.is_file():
                old_state.unlink(missing_ok=True)
                old_state.with_suffix(old_state.suffix + ".json").unlink(missing_ok=True)
            next_state.replace(old_state)
            next_state.with_suffix(next_state.suffix + ".json").replace(
                old_state.with_suffix(old_state.suffix + ".json")
            )
        current_hidden.unlink(missing_ok=True)

    for group_index, start in enumerate(range(0, len(prompt_ids), group_size)):
        group = prompt_ids[start:start + group_size]
        run_prefix_token(group, start, f"prefill-{group_index:03d}")

    for step, token in enumerate(forced_ids[: args.raw_router_position - len(prompt_ids) + 1], start=1):
        run_prefix_token([token], len(prompt_ids) + step - 1, f"decode-{step:03d}")
        if raw_result is not None:
            break
    if raw_result is None:
        raise LayerOracleError("router-raw target record was not captured")
    records = [record for record in raw_result.get("router", []) if record.get("position") == args.raw_router_position]
    if not records or "raw" not in records[0]:
        raise LayerOracleError("router-raw target record has no full raw payload")
    result = {
        "status": "ROUTER_RAW_COMPLETE",
        "artifact": {
            "repo": ARTIFACT_REPO,
            "revision": ARTIFACT_REVISION,
            "inventorySHA256": inventory.get("inventorySHA256", ARTIFACT_INVENTORY_SHA256),
        },
        "fixtureFormatVersion": "qwen35-k8-cutoff-tie-v1",
        "layer": args.raw_router_layer,
        "position": args.raw_router_position,
        "promptTokenCount": len(prompt_ids),
        "promptSHA256": _prompt_hash(prompt_ids),
        "forcedTokenIDs": forced_ids,
        "routingK": ROUTING_K,
        "oracle": {
            "python": platform.python_version(),
            "mlx": package_version("mlx"),
            "mlxLM": package_version("mlx-lm"),
            "device": args.device,
            "runtimeLabel": args.runtime_label or f"python-mlx-core-{package_version('mlx')}-{args.device}",
            "recurrentState": "float32 (config)",
            "layerIsolated": True,
            "prefixLayers": prefix_count,
            "teacherForced": True,
        },
        "router": records[0],
        "capturedLayers": [
            {
                "layer": int(layer_index),
                "layerKind": captured_results[layer_index].get("layerKind"),
                "positionBefore": int(args.raw_router_position),
                "positionAfter": int(args.raw_router_position) + 1,
                "input": captured_results[layer_index].get("input"),
                "output": captured_results[layer_index].get("lastOutput"),
                "cacheBefore": captured_results[layer_index].get("cacheBefore"),
                "cache": captured_results[layer_index].get("cache"),
                "components": captured_results[layer_index].get("components"),
            }
            for layer_index in sorted(captured_results)
        ],
    }
    path = output / "router-raw.json"
    _json_write(path, result)
    return result


def _run_full_staged(args: argparse.Namespace, inventory: dict[str, Any], output: Path) -> dict[str, Any]:
    model_dir = Path(args.model_dir).resolve()
    prompt_ids = getattr(args, "_q215_prompt_ids", None) or _render_primary_prompt(
        model_dir, args.prompt_text
    )
    if not prompt_ids:
        raise LayerOracleError("rendered primary prompt is empty")
    if args.max_output < 1:
        raise LayerOracleError("--max-output must be positive")

    prefill_group_size = 4
    continuation_identity = {
        "storageFormatVersion": Q215_STORAGE_FORMAT_VERSION,
        "artifactRevision": ARTIFACT_REVISION,
        "inventorySHA256": ARTIFACT_INVENTORY_SHA256,
        "configSHA256": CONFIG_SHA256,
        "tokenizerSHA256": TOKENIZER_SHA256,
        "templateSHA256": TEMPLATE_SHA256,
        "attentionStrategy": args.attention_strategy,
        "promptSHA256": _prompt_hash(prompt_ids),
        "promptTokenCount": len(prompt_ids),
        "prefillGroupSize": prefill_group_size,
        "maxOutput": args.max_output,
        "decodeSemantics": "prefill output token 1; cached qLen=1 calls feed emitted tokens",
    }
    rolling = RollingContinuation(
        output,
        continuation_identity,
        resume=bool(getattr(args, "resume", False)),
    )
    disk_tracker = RollingDiskTracker(output)
    disk_tracker.sample("start")
    progress = rolling.read_progress() if rolling.resumed else None
    resumable_phases = {"prefill-boundary", "prefill-head", "decode-ready"}
    if rolling.resumed:
        if progress is None:
            raise LayerOracleError(
                "--resume requires progress metadata from a committed coordinator boundary"
            )
        phase = str(progress.get("phase", ""))
        if phase not in resumable_phases:
            raise LayerOracleError(
                "--resume is supported only after a committed prefill-boundary, prefill-head, or "
                f"decode-ready boundary (found phase {phase!r}); use a new output directory"
            )
        if not rolling.hidden_current.is_file():
            raise LayerOracleError("--resume continuation is missing state-current/hidden.safetensors")
        if any(not rolling.cache_current(layer).is_file() for layer in range(40)):
            raise LayerOracleError(
                "--resume continuation is missing one or more committed layer caches"
            )
    else:
        progress = {"phase": "start", "position": 0}
        rolling.write_progress(progress)

    def stage(label: str, kind: str, extra: Iterable[str]) -> dict[str, Any]:
        return _run_staged_worker(
            args,
            output,
            label,
            kind,
            extra,
            cleanup=True,
            disk_tracker=disk_tracker,
        )

    layer_results: list[dict[str, Any]] = []
    current_hidden: Path | None = rolling.hidden_current if rolling.resumed else None
    embed: dict[str, Any] | None = {} if rolling.resumed else None
    if rolling.resumed:
        saved_layers = rolling.read_metadata("layer-results.json")
        if not isinstance(saved_layers, list) or not saved_layers:
            raise LayerOracleError(
                "--resume continuation is missing bounded layer-results metadata"
            )
        layer_results = [
            value for value in saved_layers if isinstance(value, dict)
        ]
        if len(layer_results) != 40:
            raise LayerOracleError(
                "--resume continuation does not contain all 40 committed layer results"
            )
    resume_phase = str(progress.get("phase", "")) if rolling.resumed and progress else ""
    if rolling.resumed and resume_phase == "prefill-boundary":
        resume_start = int(progress.get("nextGroupStart", len(prompt_ids)))
        resume_group = int(progress.get("nextGroupIndex", 0))
        if resume_start < 0 or resume_start > len(prompt_ids):
            raise LayerOracleError("--resume continuation has an invalid next prefill start")
        prefill_iterations = enumerate(
            range(resume_start, len(prompt_ids), prefill_group_size),
            start=resume_group,
        )
    else:
        prefill_iterations = (
            () if rolling.resumed else enumerate(range(0, len(prompt_ids), prefill_group_size))
        )
    for group_index, start in prefill_iterations:
        group_ids = prompt_ids[start:start + prefill_group_size]
        rolling.clear_next_hidden()
        embed = stage(
            f"prefill-{group_index:03d}-embed",
            "embed",
            [
                "--hidden-out", str(rolling.hidden_work_a),
                "--token-ids", *[str(value) for value in group_ids],
            ],
        )
        working_hidden = rolling.hidden_work_a
        layer_results = []
        group_results: list[dict[str, Any]] = []
        is_final_group = start + len(group_ids) == len(prompt_ids)
        trace_args = (
            ["--trace-router", "--trace-positions", str(len(prompt_ids) - 1)]
            if is_final_group else []
        )
        if args.capture_full_router:
            if args.raw_router_layer is None or args.raw_router_position is None:
                raise LayerOracleError(
                    "--capture-full-router requires --raw-router-layer and --raw-router-position"
                )
            trace_args.extend([
                "--capture-full-router",
                "--raw-router-layer", str(args.raw_router_layer),
                "--raw-router-position", str(args.raw_router_position),
            ])
        for layer_index in range(40):
            args.layer_index = layer_index
            rolling.clear_next_cache(layer_index)
            cache_path = rolling.cache_current(layer_index)
            next_state = rolling.cache_next(layer_index)
            next_hidden = (
                rolling.hidden_work_b
                if working_hidden == rolling.hidden_work_a
                else rolling.hidden_work_a
            )
            _remove_artifact(next_hidden)
            extra = [
                "--input-path", str(working_hidden),
                "--hidden-out", str(next_hidden),
                "--cache-out", str(next_state),
                "--position", str(start),
            ]
            if cache_path.is_file():
                extra.extend(["--cache-in", str(cache_path)])
            extra.extend(trace_args)
            result = stage(
                f"prefill-{group_index:03d}-layer-{layer_index:02d}",
                "layer-forward",
                extra,
            )
            group_results.append(result)
            working_hidden = next_hidden
        layer_results = group_results
        _replace_artifact(working_hidden, rolling.hidden_next)
        _remove_artifact(rolling.hidden_work_a)
        _remove_artifact(rolling.hidden_work_b)
        compact_group = [_compact_layer_result(value) for value in group_results]
        rolling.commit_boundary(
            progress={
                "phase": "prefill-boundary",
                "group": group_index,
                "nextGroupIndex": group_index + 1,
                "nextGroupStart": start + len(group_ids),
                "position": start + len(group_ids),
            },
            metadata={"layer-results.json": compact_group},
        )
        current_hidden = rolling.hidden_current
        disk_tracker.sample(f"prefill-{group_index:03d}:boundary-committed")
    if current_hidden is None or embed is None:
        raise LayerOracleError("prefill produced no hidden state")

    if rolling.resumed and resume_phase in {"prefill-head", "decode-ready"}:
        saved_head = rolling.read_metadata("head-result.json")
        if not isinstance(saved_head, dict) or "predictedToken" not in saved_head:
            raise LayerOracleError("--resume continuation is missing prefill head metadata")
        head_result = saved_head
    else:
        head_result = stage(
            "prefill-head", "head", ["--input-path", str(current_hidden)]
        )
    checkpoints: dict[int, dict[str, Any]] = {}
    if rolling.resumed:
        saved_checkpoints = rolling.read_metadata("checkpoints.json")
        if isinstance(saved_checkpoints, dict):
            checkpoints = {
                int(key): value
                for key, value in saved_checkpoints.items()
                if isinstance(value, dict)
            }
    position_after = len(prompt_ids)
    if -1 not in checkpoints:
        checkpoints[-1] = {
            "decodeStep": -1,
            "positionBefore": 0,
            "positionAfter": position_after,
            "inputToken": None,
            "predictedToken": int(head_result["predictedToken"]),
            "topLogitIDs": head_result["topLogitIDs"],
            "topLogits": head_result["topLogits"],
            "layerSnapshots": [
                {"layer": int(result["layer"]), "hidden": result["lastOutput"]}
                for result in layer_results
                if int(result["layer"]) in (0, 19, 39)
            ],
            "cache": _fixture_cache_layers(layer_results, position_after),
            "router": [
                record
                for result in layer_results
                if int(result["layer"]) in (0, 19, 39)
                for record in result.get("router", [])
            ],
        }
    if not rolling.resumed or resume_phase == "prefill-boundary":
        rolling.write_metadata("head-result.json", _compact_head_result(head_result))
        rolling.write_metadata("checkpoints.json", {str(key): value for key, value in checkpoints.items()})
        rolling.write_progress({"phase": "prefill-head", "position": len(prompt_ids)})
    first = int(head_result["predictedToken"])
    generated: list[int] = []
    # This is an internal running state.  ``output_limit`` is reserved for a
    # boundary that actually reached the configured output count.
    stop_reason = "in_progress"
    decode_calls = 0
    if rolling.resumed and resume_phase == "decode-ready":
        saved_run = rolling.read_metadata("run-state.json")
        if not isinstance(saved_run, dict):
            raise LayerOracleError("--resume continuation is missing decode run-state metadata")
        saved_generated = saved_run.get("generatedTokenIDs")
        if not isinstance(saved_generated, list) or not saved_generated:
            raise LayerOracleError("--resume decode state has no generated token sequence")
        generated = [int(value) for value in saved_generated]
        decode_calls = int(saved_run.get("decodeCalls", 0))
        stop_reason = str(saved_run.get("stopReason", "output_limit"))
    elif first in EOS_IDS:
        stop_reason = "eos"
    else:
        generated.append(first)

    if not rolling.resumed:
        rolling.write_metadata(
            "run-state.json",
            {
                "phase": "prefill-head",
                "generatedTokenIDs": generated,
                "decodeCalls": decode_calls,
                "stopReason": stop_reason,
            },
        )

    # The first token is produced by the prefill head.  Only the remaining
    # output tokens require cached decode calls, so a max-output budget of N
    # permits at most N-1 subsequent calls.  Keeping the boundary here avoids
    # an unreported terminal decode after the requested output is complete.
    while generated and len(generated) < args.max_output:
        step = len(generated)
        input_token = generated[-1]
        rolling.clear_next_hidden()
        stage(
            f"decode-{step:03d}-embed",
            "embed",
            ["--hidden-out", str(rolling.hidden_work_a), "--token-ids", str(input_token)],
        )
        working_hidden = rolling.hidden_work_a
        absolute_position = len(prompt_ids) + step - 1
        decode_results: list[dict[str, Any]] = []
        for layer_index in range(40):
            args.layer_index = layer_index
            rolling.clear_next_cache(layer_index)
            old_state = rolling.cache_current(layer_index)
            next_state = rolling.cache_next(layer_index)
            next_hidden = (
                rolling.hidden_work_b
                if working_hidden == rolling.hidden_work_a
                else rolling.hidden_work_a
            )
            _remove_artifact(next_hidden)
            decode_extra = [
                "--input-path", str(working_hidden),
                "--hidden-out", str(next_hidden),
                "--cache-in", str(old_state),
                "--cache-out", str(next_state),
                "--position", str(absolute_position),
                "--trace-router",
                "--trace-positions", str(absolute_position),
            ]
            if args.capture_full_router:
                decode_extra.extend([
                    "--capture-full-router",
                    "--raw-router-layer", str(args.raw_router_layer),
                    "--raw-router-position", str(args.raw_router_position),
                ])
            result = stage(
                f"decode-{step:03d}-layer-{layer_index:02d}",
                "layer-forward",
                decode_extra,
            )
            decode_results.append(result)
            working_hidden = next_hidden
        _replace_artifact(working_hidden, rolling.hidden_next)
        _remove_artifact(rolling.hidden_work_a)
        _remove_artifact(rolling.hidden_work_b)
        head_result = stage(
            f"decode-{step:03d}-head", "head", ["--input-path", str(rolling.hidden_next)]
        )
        position_after = absolute_position + 1
        checkpoint = {
            "decodeStep": step,
            "positionBefore": absolute_position,
            "positionAfter": position_after,
            "inputToken": input_token,
            "predictedToken": int(head_result["predictedToken"]),
            "topLogitIDs": head_result["topLogitIDs"],
            "topLogits": head_result["topLogits"],
            "layerSnapshots": [
                {"layer": int(result["layer"]), "hidden": result["lastOutput"]}
                for result in decode_results
                if int(result["layer"]) in (0, 19, 39)
            ],
            "cache": _fixture_cache_layers(decode_results, position_after),
            "router": [
                record
                for result in decode_results
                if int(result["layer"]) in (0, 19, 39)
                for record in result.get("router", [])
            ],
        }
        if step in {-1, 1, 2, 4, 8, 16, 32, 64}:
            checkpoints[step] = checkpoint
        decode_calls += 1
        predicted = int(head_result["predictedToken"])
        if predicted in EOS_IDS:
            stop_reason = "eos"
            next_generated = list(generated)
        else:
            next_generated = [*generated, predicted]
        if len(next_generated) >= args.max_output and stop_reason != "eos":
            stop_reason = "output_limit"
        boundary_phase = _decode_boundary_phase(
            stop_reason, len(next_generated), args.max_output
        )
        compact_results = [_compact_layer_result(value) for value in decode_results]
        rolling.commit_boundary(
            progress={
                "phase": boundary_phase,
                "step": step,
                "position": position_after,
            },
            metadata={
                "layer-results.json": compact_results,
                "head-result.json": _compact_head_result(head_result),
                "checkpoints.json": {str(key): value for key, value in checkpoints.items()},
                "run-state.json": {
                    "phase": boundary_phase,
                    "generatedTokenIDs": next_generated,
                    "decodeCalls": decode_calls,
                    "stopReason": stop_reason,
                },
            },
        )
        generated = next_generated
        current_hidden = rolling.hidden_current
        disk_tracker.sample(f"decode-{step:03d}:{boundary_phase}-committed")
        if boundary_phase == "complete":
            break
    if len(generated) < args.max_output and stop_reason == "in_progress":
        stop_reason = "eos"
    selected_checkpoints = [
        checkpoints[key]
        for key in (-1, 1, 2, 4, 8, 16, 32, 64)
        if key in checkpoints
    ]
    rolling.write_metadata(
        "checkpoints.json",
        {str(key): value for key, value in checkpoints.items()},
    )
    rolling.write_metadata(
        "run-state.json",
        {
            "phase": "complete",
            "generatedTokenIDs": generated,
            "decodeCalls": decode_calls,
            "stopReason": stop_reason,
        },
    )
    fixture = {
        "fixtureID": "primary",
        "promptTokenIDs": prompt_ids,
        "promptTokenCount": len(prompt_ids),
        "promptSHA256": _prompt_hash(prompt_ids),
        "generatedTokenIDs": generated,
        "stopReason": stop_reason,
        "finalConsumedPosition": len(prompt_ids) + len(generated),
        "checkpoints": selected_checkpoints,
        "referenceExecution": {
            "layerWorkerConcurrency": 1,
            "layerWorkers": 40,
            "cachedDecodeCalls": decode_calls,
            "device": args.device,
            "independentUpstreamLayer": "mlx_lm.models.qwen3_5.DecoderLayer",
            "attentionStrategy": args.attention_strategy,
            "fullAttentionLayerIndices": _full_attention_layer_indices(model_dir),
            "attentionContract": (
                "explicit ordinary MLX attention"
                if args.attention_strategy == "explicit" else "fused SDPA"
            ),
            "continuationStorage": "rolling state-current/state-next",
        },
    }
    fixture_path = output / "fixtures" / "primary.json"
    _json_write(fixture_path, fixture)
    disk_tracker.sample("fixture-written")
    stages = output / "stages"
    if stages.is_dir() and not any(stages.iterdir()):
        stages.rmdir()
    disk_tracker.sample("completed")
    _json_write(output / "disk-usage-report.json", disk_tracker.report())
    disk_tracker.sample("disk-report-written")
    _json_write(output / "disk-usage-report.json", disk_tracker.report())
    rolling.write_progress({
        "phase": "complete",
        "generatedTokens": len(generated),
        "decodeCalls": decode_calls,
        "position": len(prompt_ids) + len(generated),
    })
    return {
        "fixture": fixture,
        "fixturePath": fixture_path,
        "embed": embed,
        "generatedTokens": len(generated),
        "decodeCalls": decode_calls,
        "status": "FULL_GATE_COMPLETE" if len(generated) >= 64 else "FULL_GATE_SHORT",
        "diskUsage": disk_tracker.report(),
    }


def _full_attention_layer_indices(model_dir: Path) -> list[int]:
    """Derive full-attention indices from the installed config."""
    config = json.loads((model_dir / "config.json").read_text())
    text_config = config.get("text_config", config)
    layer_types = text_config.get("layer_types")
    if isinstance(layer_types, list) and layer_types:
        indices = [index for index, value in enumerate(layer_types) if value == "full_attention"]
        if len(indices) + layer_types.count("linear_attention") != len(layer_types):
            raise LayerOracleError("config layer_types contains an unsupported attention kind")
        return indices
    hidden_layers = int(text_config.get("num_hidden_layers", 0))
    interval = int(text_config.get("full_attention_interval", 0))
    if hidden_layers <= 0 or interval <= 0:
        raise LayerOracleError("config has no usable full-attention layout")
    return [index for index in range(hidden_layers) if (index + 1) % interval == 0]


def _write_full_fixture_package(output: Path, run: dict[str, Any], inventory: dict[str, Any], archive: Path | None, args: argparse.Namespace) -> dict[str, Any]:
    fixture_path: Path = run["fixturePath"]
    fixture = run["fixture"]
    full_attention_layers = _full_attention_layer_indices(Path(args.model_dir).expanduser().resolve())
    metadata = {
        # v1 remains the default so existing off-host CPU fixtures retain
        # their original schema. Q2.7 passes a matched-core version string.
        "fixtureFormatVersion": args.fixture_format_version,
        "artifact": {
            "repo": ARTIFACT_REPO,
            "revision": ARTIFACT_REVISION,
            "inventorySHA256": ARTIFACT_INVENTORY_SHA256,
        },
        "configSHA256": CONFIG_SHA256,
        "tokenizerSHA256": TOKENIZER_SHA256,
        "tokenizerConfigSHA256": TOKENIZER_CONFIG_SHA256,
        "templateSHA256": TEMPLATE_SHA256,
        "oracle": {
            "python": platform.python_version(),
            "mlx": package_version("mlx"),
            "mlxLM": package_version("mlx-lm"),
            "device": "cpu" if args.device == "cpu" else args.device,
            "runtimeLabel": args.runtime_label or f"python-mlx-core-{package_version('mlx')}-{args.device}",
            "recurrentKernel": (
                "python-metal-gated-delta-fp32-state"
                if args.device == "metal" else "python-ops-gated-delta-fp32-state"
            ),
            "recurrentState": "float32 (config)",
            "layerIsolated": True,
            "workerConcurrency": 1,
        },
        "semantics": {
            "routingK": ROUTING_K,
            "expertCount": 256,
            "sharedExpert": True,
            "thinking": False,
            "sampler": "greedy/temperature-disabled",
            "snapshotSteps": [-1, 1, 2, 4, 8, 16, 32, 64],
            "attentionContract": (
                "explicit ordinary MLX attention"
                if args.attention_strategy == "explicit" else "fused SDPA"
            ),
            "attentionStrategy": args.attention_strategy,
            "fullAttentionLayerIndices": full_attention_layers,
            "decodeSemantics": "prefill output token 1; cached qLen=1 calls feed emitted tokens",
        },
        "fixtures": {
            "primary": {
                "path": "fixtures/primary.json",
                "bytes": fixture_path.stat().st_size,
                "sha256": sha256_file(fixture_path),
                "promptTokenCount": fixture["promptTokenCount"],
                "promptSHA256": fixture["promptSHA256"],
                "generatedTokens": len(fixture["generatedTokenIDs"]),
                "stopReason": fixture["stopReason"],
            }
        },
        "resource": {
            "method": "one-layer worker, one process at a time",
            "artifactVerification": "completed-once" if inventory.get("verification") != "skipped-by-explicit-option" else inventory["verification"],
        },
        "generatedAt": time.time(),
    }
    _json_write(output / "manifest.json", metadata)
    (output / "README.md").write_text(
        "# Qwen3.5 K=8 layer-isolated oracle fixture\n\n"
        "Generated from the pinned quantized artifact without a full-model loader.\n"
        "Only compact JSON summaries and token IDs are included; no model shards.\n"
        f"Fixture format: {args.fixture_format_version}. Runtime: {args.runtime_label or f'python-mlx-core-{package_version('mlx')}-{args.device}'}. Attention: {metadata['semantics']['attentionContract']}.\n"
    )
    if archive is None:
        return {"manifest": metadata, "archive": None}
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists():
        raise LayerOracleError(f"archive already exists: {archive}")
    with __import__("zipfile").ZipFile(archive, "w", compression=__import__("zipfile").ZIP_DEFLATED, compresslevel=6) as handle:
        for path in sorted((output / "fixtures").rglob("*")):
            if path.is_file():
                handle.write(path, path.relative_to(output).as_posix())
        for name in ("manifest.json", "README.md"):
            handle.write(output / name, name)
    archive_hash = sha256_file(archive)
    (archive.with_suffix(archive.suffix + ".sha256")).write_text(f"{archive_hash}  {archive.name}\n")
    return {"manifest": metadata, "archive": str(archive), "archiveBytes": archive.stat().st_size, "archiveSHA256": archive_hash}


def _plan(model_dir: Path, layer_indices: list[int]) -> dict[str, Any]:
    reader = SelectiveSafeTensorReader(model_dir)
    config = json.loads((model_dir / "config.json").read_text())
    text_config = config.get("text_config", config)
    plans = [reader.layer_plan(index) for index in layer_indices]
    max_tensor = max((entry["bytes"] for plan in plans for entry in plan["entries"]), default=0)
    for plan in plans:
        plan["lowerBoundResidentBytes"] = plan["bytes"]
        plan["conservativeRangeReadPeakBytes"] = plan["bytes"] + max_tensor
    return {
        "status": "METADATA_ONLY",
        "artifact": {"repo": ARTIFACT_REPO, "revision": ARTIFACT_REVISION, "inventorySHA256": ARTIFACT_INVENTORY_SHA256},
        "config": {key: text_config.get(key) for key in ("num_hidden_layers", "hidden_size", "num_experts", "num_experts_per_tok", "full_attention_interval", "mamba_ssm_dtype", "vocab_size")},
        "layerPlans": plans,
        "maxTensorBytes": max_tensor,
        "workerConcurrency": 1,
        "fullAttentionLayerIndices": _full_attention_layer_indices(model_dir),
        "note": "The lower bound retains one layer; the conservative range-read estimate adds one largest transient range. It is not a peak-memory guarantee.",
    }


def _prepare_full_disk_policy(
    args: argparse.Namespace,
    model_dir: Path,
    output: Path,
    prompt_ids: list[int],
) -> dict[str, Any]:
    """Write a byte-level peak estimate and configure the worker guard.

    Q2.14 supplied 3,758,096,384 as an explicit free-disk floor.  It was a
    conservative admission value, not a component ledger.  Q2.15 keeps that
    value visible for comparison and uses a rolling peak calculation only
    when the caller explicitly selects ``--disk-policy rolling``.
    """
    config = load_config(model_dir / "config.json")
    budget, state = estimate_rolling_disk_budget(
        config,
        prompt_tokens=len(prompt_ids),
        output_tokens=args.max_output,
        safety_reserve_bytes=args.disk_safety_reserve_bytes,
    )
    requested_floor = args.min_free_disk_bytes
    if args.disk_policy == "rolling":
        effective_floor = max(
            budget.required_free_bytes,
            requested_floor if requested_floor is not None else 0,
        )
        policy_note = (
            "rolling peak estimate plus reserve; an explicitly supplied floor "
            "is still honored"
        )
    else:
        effective_floor = requested_floor if requested_floor is not None else 10 * GIB
        policy_note = "legacy caller-supplied free-disk floor"
    old_breakdown = {
        "persistentRequired": "unavailable: Q2.14 did not record a component ledger",
        "rollingContinuationState": "unavailable: Q2.14 did not record a component ledger",
        "diagnosticSnapshot": "unavailable: Q2.14 did not record a component ledger",
        "temporaryWorkerOutput": "unavailable: Q2.14 did not record a component ledger",
        "atomicWriteDuplicate": "unavailable: Q2.14 did not record a component ledger",
        "buildLogOverhead": "unavailable: Q2.14 did not record a component ledger",
        "safetyReserveOrUnattributedFloorBytes": Q215_LEGACY_Q214_FLOOR_BYTES,
        "classification": (
            "explicit free-disk admission floor; not evidence of cumulative "
            "bytes written or simultaneous occupancy"
        ),
    }
    report = {
        "storageFormatVersion": Q215_STORAGE_FORMAT_VERSION,
        "artifactRevision": ARTIFACT_REVISION,
        "inventorySHA256": ARTIFACT_INVENTORY_SHA256,
        "attentionStrategy": args.attention_strategy,
        "promptTokenCount": len(prompt_ids),
        "promptSHA256": _prompt_hash(prompt_ids),
        "outputReservationTokens": args.max_output,
        "legacyQ214Estimate": old_breakdown,
        "rollingBudget": budget.as_dict(),
        "continuationState": state,
        "estimatedPeakWorkingBytes": budget.peak_working_bytes,
        "requiredFreeBytesIncludingReserve": budget.required_free_bytes,
        "requestedExternalFloorBytes": requested_floor,
        "effectiveGuardFloorBytes": effective_floor,
        "policy": args.disk_policy,
        "policyNote": policy_note,
        "freeDiskBytesBefore": free_disk_bytes(output),
        "admission": free_disk_bytes(output) >= effective_floor,
        "peakAccounting": (
            "simultaneous occupancy including one full replacement continuation "
            "at the directory-swap boundary; historical stages are deleted after each worker"
        ),
    }
    _json_write(output / "disk-plan.json", report)
    print(json.dumps({
        "status": "DISK_PREFLIGHT",
        "policy": args.disk_policy,
        "estimatedPeakWorkingBytes": budget.peak_working_bytes,
        "requiredFreeBytesIncludingReserve": budget.required_free_bytes,
        "effectiveGuardFloorBytes": effective_floor,
        "freeDiskBytesBefore": report["freeDiskBytesBefore"],
        "admission": report["admission"],
        "continuationState": state,
    }, indent=2, sort_keys=True))
    args.min_free_disk_bytes = effective_floor
    if not report["admission"]:
        raise LayerOracleError(
            f"free disk {report['freeDiskBytesBefore']} is below effective rolling requirement {effective_floor}"
        )
    return report


def _parent(args: argparse.Namespace) -> int:
    if args.fixture_format_version == "qwen35-k8-matched-core-v1":
        # A matched-core archive is meaningful only when it was actually
        # produced by the same MLX/Metal generation core as the app. Fail
        # before touching model payloads if a caller activates the label in
        # an older or otherwise unrecorded environment.
        if package_version("mlx") != "0.31.1" or package_version("mlx-lm") != "0.31.1" or args.device != "metal":
            raise LayerOracleError(
                "matched-core fixture requires mlx==0.31.1, mlx-lm==0.31.1, and --device metal"
            )
    model_dir = Path(args.model_dir).expanduser().resolve()
    if not model_dir.is_dir():
        raise FileNotFoundError(model_dir)
    if (
        args.mode != "full"
        and args.disk_policy != "rolling"
        and args.min_free_disk_bytes is None
    ):
        # Preserve the historical non-full-mode guard when callers omit the
        # explicit floor. Full mode and rolling preflight choose their floors
        # in the disk policy calculation.
        args.min_free_disk_bytes = 10 * GIB
    output = Path(args.output_dir).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.audit:
        _json_write(output / "loader-audit.json", _audit_full_loader())
    if args.verify_artifact:
        inventory = verify_artifact(model_dir)
    else:
        inventory = {"repo": ARTIFACT_REPO, "revision": ARTIFACT_REVISION, "inventorySHA256": ARTIFACT_INVENTORY_SHA256, "verification": "skipped-by-explicit-option"}
    plan = _plan(model_dir, [args.layer_index, args.attention_layer_index])
    _json_write(output / "allocation-plan.json", plan)
    if args.mode == "boundary":
        result = _run_boundary(args, inventory, output)
        report = {
            "status": result["status"],
            "boundary": str(result["path"]),
            "promptTokenCount": result["boundary"]["promptTokenCount"],
            "boundaryLayerCount": result["boundary"]["boundaryLayerCount"],
            "prefillGroups": len(result["boundary"]["groups"]),
            "recurrentState": result["boundary"]["oracle"]["recurrentState"],
        }
        _json_write(output / "boundary-report.json", report)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    if args.mode == "router-raw":
        result = _run_router_raw_prefix(args, inventory, output)
        _json_write(output / "router-raw-report.json", {
            "status": result["status"],
            "layer": result["layer"],
            "position": result["position"],
            "promptTokenCount": result["promptTokenCount"],
            "prefixLayers": result["oracle"]["prefixLayers"],
        })
        print(json.dumps({
            "status": result["status"],
            "layer": result["layer"],
            "position": result["position"],
            "promptTokenCount": result["promptTokenCount"],
        }, indent=2, sort_keys=True))
        return 0
    if args.mode == "full":
        prompt_ids = _render_primary_prompt(model_dir, args.prompt_text)
        if not prompt_ids:
            raise LayerOracleError("rendered primary prompt is empty")
        args._q215_prompt_ids = prompt_ids
        disk_plan = _prepare_full_disk_policy(args, model_dir, output, prompt_ids)
        run = _run_full_staged(args, inventory, output)
        # A short or interrupted run may leave compact diagnostics, but it is
        # not a fixture package.  Publish an archive only after the coordinator
        # reaches the >=64-token gate; callers can still inspect the bounded
        # output directory and disk report for a failed run.
        package = (
            _write_full_fixture_package(output, run, inventory, args.archive, args)
            if run["status"] == "FULL_GATE_COMPLETE"
            else {"published": False, "reason": "FULL_GATE_SHORT"}
        )
        report = {
            "status": run["status"],
            "generatedTokens": run["generatedTokens"],
            "decodeCalls": run["decodeCalls"],
            "fixtureBytes": run["fixturePath"].stat().st_size,
            "archive": package.get("archive"),
            "archiveBytes": package.get("archiveBytes"),
            "archiveSHA256": package.get("archiveSHA256"),
            "diskPlan": disk_plan,
            "diskUsage": run.get("diskUsage"),
        }
        _json_write(output / "full-oracle-report.json", report)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0 if run["status"] == "FULL_GATE_COMPLETE" else 2
    if args.mode == "estimate":
        if args.disk_policy == "rolling":
            prompt_ids = _render_primary_prompt(model_dir, args.prompt_text)
            if not prompt_ids:
                raise LayerOracleError("rendered primary prompt is empty")
            disk_plan = _prepare_full_disk_policy(args, model_dir, output, prompt_ids)
            print(json.dumps({
                "status": "DISK_PREFLIGHT_ONLY",
                "output": str(output),
                "plan": plan,
                "diskPlan": disk_plan,
            }, indent=2, sort_keys=True))
        else:
            print(json.dumps({"status": "METADATA_ONLY", "output": str(output), "plan": plan}, indent=2, sort_keys=True))
        return 0
    common = ["--input-length", str(args.input_length), "--max-rss-bytes", str(args.max_rss_bytes)]
    results: dict[str, Any] = {"inventory": inventory, "plan": plan, "loaderAudit": _audit_full_loader(), "startedAt": time.time(), "workers": []}
    if args.mode in ("all", "layers"):
        for layer_index, kind in ((args.layer_index, "layer"), (args.attention_layer_index, "layer-attention")):
            args.layer_index = layer_index
            result = _run_worker(args, output, "layer" if kind == "layer" else "layer-attention", common)
            result["requestedLayer"] = layer_index
            results["workers"].append(result)
    if args.mode in ("all", "serialization"):
        args.layer_index = args.linear_layer_index
        state_path = output / "serialization-state.safetensors"
        create = _run_worker(args, output, "serialization-create", ["--state-out", str(state_path), *common])
        resume = _run_worker(args, output, "serialization-resume", ["--state-in", str(state_path), *common])
        results["serialization"] = {"create": create, "resume": resume, "passed": bool(resume.get("passed"))}
    results["completedAt"] = time.time()
    workers_passed = all(item.get("status") == "LAYER_COMPLETE" for item in results["workers"])
    serialization_passed = results.get("serialization", {}).get("passed", False)
    # ``--mode layers`` is intentionally a worker-only gate.  The previous
    # coordinator always required serialization, so successful layer workers
    # were incorrectly reported as incomplete.
    required_passed = workers_passed and (args.mode == "layers" or serialization_passed)
    results["status"] = "LAYER_GATES_PASSED" if required_passed else "LAYER_GATES_INCOMPLETE"
    _json_write(output / "layer-oracle-report.json", results)
    print(json.dumps({"status": results["status"], "output": str(output), "workers": len(results["workers"]), "serialization": results.get("serialization", {}).get("passed")}, indent=2, sort_keys=True))
    return 0 if results["status"] == "LAYER_GATES_PASSED" else 2


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", choices=("parent", "worker"), default="parent")
    parser.add_argument("--worker-kind", choices=("layer", "layer-attention", "layer-forward", "embed", "head", "serialization-create", "serialization-resume"))
    parser.add_argument("--model-dir", type=Path, default=Path("/Users/m/Library/Application Support/BeetCode/Models/qwen3.5-35b-a3b-streaming-4bit"))
    parser.add_argument("--output-dir", type=Path, default=Path("/tmp/qwen35-k8-layer-oracle"))
    parser.add_argument("--mode", choices=("estimate", "layers", "serialization", "all", "full", "boundary", "router-raw"), default="all")
    parser.add_argument("--layer-index", type=int, default=0)
    parser.add_argument("--linear-layer-index", type=int, default=0)
    parser.add_argument("--attention-layer-index", type=int, default=3)
    parser.add_argument("--input-length", type=int, default=2)
    parser.add_argument("--device", choices=("cpu", "metal"), default="cpu")
    parser.add_argument(
        "--attention-strategy",
        choices=("fused", "explicit"),
        default="fused",
        help="full-attention reference contract; explicit is the Q2.14 developer-only path",
    )
    parser.add_argument("--verify-artifact", action="store_true")
    parser.add_argument("--audit", action="store_true", default=True)
    parser.add_argument("--max-rss-bytes", type=int, default=int(1.75 * GIB))
    parser.add_argument("--max-swap-delta-bytes", type=int, default=512 * 1024**2)
    parser.add_argument("--min-free-memory-percent", type=float, default=10.0)
    parser.add_argument(
        "--min-free-disk-bytes",
        type=int,
        default=None,
        help="explicit additional free-disk floor; rolling full mode derives one when omitted",
    )
    parser.add_argument(
        "--disk-policy",
        choices=("legacy", "rolling"),
        default="legacy",
        help="full-oracle disk accounting; rolling uses state-current/state-next peak accounting",
    )
    parser.add_argument(
        "--disk-safety-reserve-bytes",
        type=int,
        default=Q215_DEFAULT_SAFETY_RESERVE_BYTES,
        help="reserve added to the rolling peak estimate",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help=(
            "resume a rolling full run only from a committed prefill/head or "
            "decode/head boundary; never overwrites state implicitly"
        ),
    )
    parser.add_argument("--worker-timeout", type=float, default=300.0)
    parser.add_argument("--rel-l2-tolerance", type=float, default=1e-5)
    parser.add_argument("--max-abs-tolerance", type=float, default=1e-3)
    parser.add_argument("--state-in", type=Path)
    parser.add_argument("--state-out", type=Path)
    parser.add_argument("--result-out", type=Path)
    parser.add_argument("--input-path", type=Path)
    parser.add_argument("--hidden-out", type=Path)
    parser.add_argument("--cache-in", type=Path)
    parser.add_argument("--cache-out", type=Path)
    parser.add_argument("--position", type=int, default=0)
    parser.add_argument("--token-ids", type=int, nargs="*", default=[])
    parser.add_argument("--trace-router", action="store_true")
    parser.add_argument("--trace-positions", type=int, nargs="*", default=[])
    parser.add_argument(
        "--capture-full-router",
        action="store_true",
        help="retain one explicitly keyed router input/logit/selector vector",
    )
    parser.add_argument("--raw-router-layer", type=int, default=None)
    parser.add_argument("--raw-router-position", type=int, default=None)
    parser.add_argument("--capture-components", action="store_true")
    parser.add_argument(
        "--capture-layers",
        type=int,
        nargs="*",
        default=[],
        help="target-position layer outputs/components to retain in router-raw mode",
    )
    parser.add_argument(
        "--capture-full-components",
        action="store_true",
        help="retain complete bounded activation arrays for a diagnostic boundary run",
    )
    parser.add_argument(
        "--capture-cache-before",
        action="store_true",
        help="retain the target worker cache state immediately before its forward pass",
    )
    parser.add_argument(
        "--capture-cache-full",
        action="store_true",
        help="retain complete cache arrays for an explicitly bounded worker",
    )
    parser.add_argument("--prompt-text", default=PRIMARY_PROMPT)
    parser.add_argument("--max-output", type=int, default=1)
    parser.add_argument(
        "--boundary-layer-count",
        type=int,
        default=1,
        help="number of contiguous layers to retain in the compact prefill boundary probe",
    )
    parser.add_argument(
        "--boundary-capture-layer",
        type=int,
        default=-1,
        help="when set, retain component arrays only for this boundary layer",
    )
    parser.add_argument(
        "--boundary-capture-cache-layer",
        type=int,
        default=-1,
        help="when set, retain complete cache arrays only for this boundary layer",
    )
    parser.add_argument(
        "--boundary-max-groups",
        type=int,
        default=0,
        help="limit a boundary probe to the first N four-token groups (0 means all)",
    )
    parser.add_argument("--archive", type=Path)
    parser.add_argument(
        "--reference-fixture",
        type=Path,
        help="frozen matched-core ZIP used by the bounded router-raw teacher-forced probe",
    )
    parser.add_argument(
        "--fixture-format-version",
        default="qwen35-k8-oracle-v1",
        help="version label written to boundary/full fixture metadata",
    )
    parser.add_argument(
        "--runtime-label",
        default=None,
        help="explicit reference runtime label recorded in fixture metadata",
    )
    parser.add_argument("--self-test", action="store_true")
    return parser


def _write_test_safetensor(path: Path) -> None:
    values = np.array([1.0, 2.0, 3.0], dtype="<f4").tobytes()
    header = json.dumps({"tiny": {"dtype": "F32", "shape": [3], "data_offsets": [0, len(values)]}}, separators=(",", ":")).encode()
    path.write_bytes(struct.pack("<Q", len(header)) + header + values)


def _self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="qwen35-layer-oracle-") as directory:
        root = Path(directory)
        shard = root / "model-00001-of-00001.safetensors"
        _write_test_safetensor(shard)
        index = {"weight_map": {"tiny": shard.name}, "metadata": {"total_size": shard.stat().st_size}}
        (root / "model.safetensors.index.json").write_text(json.dumps(index))
        # The reader's production index hash is intentionally not used for the
        # synthetic self-test; it verifies range/header/shape behavior only.
        reader = object.__new__(SelectiveSafeTensorReader)
        reader.model_dir = root.resolve()
        reader.weight_map = index["weight_map"]
        reader._headers = {}
        reader.requested_bytes = 0
        reader.completed_bytes = 0
        reader.read_calls = 0
        entry = reader.entry("tiny")
        assert entry.byte_count == 12
        assert reader.read_raw(entry) == np.array([1.0, 2.0, 3.0], dtype="<f4").tobytes()
        assert reader.requested_bytes == 12 and reader.completed_bytes == 12 and reader.read_calls == 1
        assert _dtype_size("BF16") == 2
        assert _host_identity().get("machine")
    print("qwen35-k8-layer-oracle-self-test=passed")
    return 0


def main() -> int:
    args = _build_parser().parse_args()
    if args.self_test:
        return _self_test()
    if args.role == "worker":
        if not args.worker_kind or args.result_out is None:
            raise SystemExit("worker requires --worker-kind and --result-out")
        if args.worker_kind == "serialization-create" and args.state_out is None:
            raise SystemExit("serialization-create requires --state-out")
        if args.worker_kind == "serialization-resume" and args.state_in is None:
            raise SystemExit("serialization-resume requires --state-in")
        return _worker_main(args)
    return _parent(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (LayerOracleError, ValueError, FileNotFoundError) as error:
        print(f"LAYER_ORACLE_ABORT: {error}", file=sys.stderr)
        raise SystemExit(2)
