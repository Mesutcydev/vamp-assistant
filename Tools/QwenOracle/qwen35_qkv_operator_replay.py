#!/usr/bin/env python3
"""Replay the layer-0 QKV quantized operator across independent runtimes.

This is a bounded, development-only diagnostic for Q2.6.  ``create`` reads
only the layer-0 QKV Safetensors ranges and two already captured activation
groups.  ``run`` executes the saved operator with the installed Python MLX
core and never constructs a model.  The fixture contains no checkpoint
payload beyond the one QKV projection, and is intentionally small enough to
move between validation hosts.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import struct
import sys
import zipfile
from array import array
from pathlib import Path
from typing import Any


ARTIFACT_REPO = "mlx-community/Qwen3.5-35B-A3B-4bit"
ARTIFACT_REVISION = "1e20fd8d42056f870933bf98ca6211024744f7ec"
ARTIFACT_INVENTORY_SHA256 = "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592"
INDEX_SHA256 = "56f02123353b7fe444b287a46a779a836cb939860502908da4a79e3b43931cdb"
CONFIG_SHA256 = "c0cf317cba802cfb1d2984d4b4afc98ceb3d86450ed757e028383bfb03643964"
ROUTING_K = 8
QKV_WEIGHT = "language_model.model.layers.0.linear_attn.in_proj_qkv.weight"
QKV_SCALES = "language_model.model.layers.0.linear_attn.in_proj_qkv.scales"
QKV_BIASES = "language_model.model.layers.0.linear_attn.in_proj_qkv.biases"
EXPECTED_TENSORS = {
    QKV_WEIGHT: ("U32", (8192, 256)),
    QKV_SCALES: ("BF16", (8192, 32)),
    QKV_BIASES: ("BF16", (8192, 32)),
}
DTYPE_BYTES = {"U32": 4, "BF16": 2}
SAFE_HEADER_LIMIT = 128 * 1024 * 1024


class ReplayError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(json.dumps(value, indent=2, sort_keys=True).encode("utf-8"))
    temporary.replace(path)


def safe_child(root: Path, name: str) -> Path:
    if not name or Path(name).is_absolute() or ".." in Path(name).parts:
        raise ReplayError(f"unsafe shard path: {name!r}")
    root = root.resolve()
    child = (root / name).resolve()
    if child != root and root not in child.parents:
        raise ReplayError(f"shard escapes model directory: {name!r}")
    if child.is_symlink():
        raise ReplayError(f"symlinked shard is not accepted: {name!r}")
    return child


def parse_header(model_dir: Path, shard: str) -> tuple[int, dict[str, Any], int]:
    path = safe_child(model_dir, shard)
    with path.open("rb") as handle:
        prefix = handle.read(8)
        if len(prefix) != 8:
            raise ReplayError(f"truncated Safetensors header prefix: {shard}")
        header_length = struct.unpack("<Q", prefix)[0]
        if header_length > SAFE_HEADER_LIMIT:
            raise ReplayError(f"oversized Safetensors header: {shard}")
        header_bytes = handle.read(header_length)
        if len(header_bytes) != header_length:
            raise ReplayError(f"truncated Safetensors header: {shard}")
    try:
        header = json.loads(header_bytes)
    except json.JSONDecodeError as error:
        raise ReplayError(f"invalid Safetensors header: {shard}") from error
    if not isinstance(header, dict):
        raise ReplayError(f"Safetensors header is not an object: {shard}")
    return int(header_length), header, path.stat().st_size


class IndexedReader:
    """Metadata-only index reader plus bounded range reads."""

    def __init__(self, model_dir: Path):
        self.model_dir = model_dir.resolve()
        index_path = safe_child(self.model_dir, "model.safetensors.index.json")
        index_bytes = index_path.read_bytes()
        if sha256_bytes(index_bytes) != INDEX_SHA256:
            raise ReplayError("model.safetensors.index.json hash does not match the pinned artifact")
        try:
            index = json.loads(index_bytes)
        except json.JSONDecodeError as error:
            raise ReplayError("invalid model.safetensors.index.json") from error
        self.weight_map = index.get("weight_map")
        if not isinstance(self.weight_map, dict):
            raise ReplayError("Safetensors index has no weight_map")
        self.headers: dict[str, tuple[int, dict[str, Any], int]] = {}

    def entry(self, name: str) -> dict[str, Any]:
        shard = self.weight_map.get(name)
        if not isinstance(shard, str):
            raise ReplayError(f"missing tensor in index: {name}")
        if shard not in self.headers:
            self.headers[shard] = parse_header(self.model_dir, shard)
        header_length, header, file_size = self.headers[shard]
        item = header.get(name)
        if not isinstance(item, dict):
            raise ReplayError(f"missing tensor in shard header: {name}")
        dtype = item.get("dtype")
        shape = item.get("shape")
        offsets = item.get("data_offsets")
        # Safetensors uses BF16/U32 spellings in the pinned conversion.
        if dtype not in DTYPE_BYTES or not isinstance(shape, list) or not isinstance(offsets, list) or len(offsets) != 2:
            raise ReplayError(f"unsupported metadata for {name}: {item!r}")
        if any(not isinstance(dimension, int) or dimension < 0 for dimension in shape):
            raise ReplayError(f"invalid shape for {name}: {shape!r}")
        start, end = offsets
        if not isinstance(start, int) or not isinstance(end, int) or start < 0 or end < start:
            raise ReplayError(f"invalid data range for {name}: {offsets!r}")
        elements = math.prod(shape) if shape else 1
        expected = elements * DTYPE_BYTES[dtype]
        if end - start != expected:
            raise ReplayError(f"shape/byte mismatch for {name}: {end - start} != {expected}")
        payload_start = 8 + header_length + start
        payload_end = 8 + header_length + end
        if payload_end > file_size:
            raise ReplayError(f"payload exceeds shard for {name}")
        return {
            "name": name,
            "shard": shard,
            "dtype": dtype,
            "shape": [int(value) for value in shape],
            "relativeStart": start,
            "relativeEnd": end,
            "headerLength": header_length,
            "payloadOffset": payload_start,
            "byteCount": expected,
            "shardBytes": file_size,
        }

    def read(self, entry: dict[str, Any]) -> bytes:
        path = safe_child(self.model_dir, str(entry["shard"]))
        with path.open("rb") as handle:
            handle.seek(int(entry["payloadOffset"]))
            data = handle.read(int(entry["byteCount"]))
        if len(data) != int(entry["byteCount"]):
            raise ReplayError(f"short read for {entry['name']}: {len(data)}")
        return data


def summary_bf16(summary: dict[str, Any], label: str) -> tuple[bytes, list[int]]:
    shape = summary.get("shape")
    raw = summary.get("rawBFloat16Bits")
    if not isinstance(shape, list) or not all(isinstance(x, int) and x >= 0 for x in shape):
        raise ReplayError(f"{label} has no valid shape")
    if not isinstance(raw, list) or not all(isinstance(x, int) and 0 <= x <= 0xFFFF for x in raw):
        raise ReplayError(f"{label} has no complete raw BF16 values")
    expected = math.prod(shape) if shape else 1
    if len(raw) != expected:
        raise ReplayError(f"{label} raw value count {len(raw)} != {expected}")
    return b"".join(struct.pack("<H", int(value)) for value in raw), [int(x) for x in shape]


def boundary_qkv(boundary: dict[str, Any], group_index: int) -> tuple[bytes, list[int], bytes, list[int]]:
    groups = boundary.get("groups")
    if not isinstance(groups, list) or group_index >= len(groups):
        raise ReplayError(f"boundary is missing group {group_index}")
    group = groups[group_index]
    try:
        layer = group["layers"][0]
        components = layer["components"]
        input_summary = components["attentionInput"]
        qkv_summary = components["linearProjections"]["qkv"]
    except (KeyError, IndexError, TypeError) as error:
        raise ReplayError(f"boundary group {group_index} has no layer-0 QKV components") from error
    input_bytes, input_shape = summary_bf16(input_summary, f"group {group_index} attention input")
    qkv_bytes, qkv_shape = summary_bf16(qkv_summary, f"group {group_index} QKV output")
    if input_shape != [1, 4, 2048]:
        raise ReplayError(f"group {group_index} input shape is {input_shape}, expected [1, 4, 2048]")
    if qkv_shape != [1, 4, 8192]:
        raise ReplayError(f"group {group_index} QKV shape is {qkv_shape}, expected [1, 4, 8192]")
    return input_bytes, input_shape, qkv_bytes, qkv_shape


def create_fixture(args: argparse.Namespace) -> None:
    model_dir = Path(args.model_dir).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    if not model_dir.is_dir():
        raise ReplayError(f"model directory does not exist: {model_dir}")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ReplayError(f"refusing to overwrite non-empty fixture directory: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)

    reference_path = Path(args.reference_boundary).expanduser().resolve()
    native_path = Path(args.native_boundary).expanduser().resolve()
    reference = json.loads(reference_path.read_text())
    native = json.loads(native_path.read_text())
    if reference.get("fixtureFormatVersion") != "qwen35-k8-boundary-v1":
        raise ReplayError("reference boundary format is not qwen35-k8-boundary-v1")
    if native.get("fixtureFormatVersion") != "qwen35-k8-boundary-v1":
        raise ReplayError("native boundary format is not qwen35-k8-boundary-v1")
    if reference.get("promptTokenIDs") != native.get("promptTokenIDs"):
        raise ReplayError("reference/native prompt token IDs differ")
    if reference.get("artifact", {}).get("revision") != ARTIFACT_REVISION:
        raise ReplayError("reference boundary has the wrong artifact revision")
    if reference.get("artifact", {}).get("inventorySHA256") != ARTIFACT_INVENTORY_SHA256:
        raise ReplayError("reference boundary has the wrong artifact inventory identity")

    reader = IndexedReader(model_dir)
    entries = {name: reader.entry(name) for name in EXPECTED_TENSORS}
    for name, entry in entries.items():
        expected_dtype, expected_shape = EXPECTED_TENSORS[name]
        if entry["dtype"] != expected_dtype or tuple(entry["shape"]) != expected_shape:
            raise ReplayError(f"unexpected {name} geometry: {entry['dtype']} {entry['shape']}")
    raw_tensors: dict[str, bytes] = {}
    for name, entry in entries.items():
        raw = reader.read(entry)
        if len(raw) != entry["byteCount"]:
            raise ReplayError(f"unexpected payload length for {name}")
        raw_tensors[name] = raw

    files: dict[str, str] = {}
    def save(name: str, data: bytes) -> str:
        path = output_dir / name
        path.write_bytes(data)
        digest = sha256_bytes(data)
        files[name] = digest
        return digest

    for name, raw in raw_tensors.items():
        suffix = {QKV_WEIGHT: "qkv.weight.u32", QKV_SCALES: "qkv.scales.bf16", QKV_BIASES: "qkv.biases.bf16"}[name]
        save(suffix, raw)

    cases = []
    for group_index in range(2):
        ref_input, input_shape, ref_output, output_shape = boundary_qkv(reference, group_index)
        native_input, native_input_shape, native_output, native_output_shape = boundary_qkv(native, group_index)
        if input_shape != native_input_shape or output_shape != native_output_shape:
            raise ReplayError(f"native/reference shape mismatch in group {group_index}")
        input_name = f"input-group-{group_index:03d}.bf16"
        native_input_name = f"native-input-group-{group_index:03d}.bf16"
        reference_name = f"reference-output-group-{group_index:03d}.bf16"
        native_name = f"native-output-group-{group_index:03d}.bf16"
        save(input_name, ref_input)
        save(native_input_name, native_input)
        save(reference_name, ref_output)
        save(native_name, native_output)
        group = reference["groups"][group_index]
        cases.append({
            "groupIndex": group_index,
            "positionBefore": int(group["positionBefore"]),
            "positionAfter": int(group["positionAfter"]),
            "tokenIDs": [int(x) for x in group["tokenIDs"]],
            "inputShape": input_shape,
            "outputShape": output_shape,
            "input": input_name,
            "nativeInput": native_input_name,
            "referenceOutput": reference_name,
            "nativeOutput": native_name,
            "inputSHA256": files[input_name],
            "nativeInputSHA256": files[native_input_name],
            "referenceOutputSHA256": files[reference_name],
            "nativeOutputSHA256": files[native_name],
            "inputMatchesNativeBoundary": ref_input == native_input,
        })

    metadata = {
        "format": "qwen35-k8-qkv-operator-v1",
        "artifact": {
            "repo": ARTIFACT_REPO,
            "revision": ARTIFACT_REVISION,
            "inventorySHA256": ARTIFACT_INVENTORY_SHA256,
            "configSHA256": CONFIG_SHA256,
        },
        "semantics": {
            "layer": 0,
            "module": "linear_attn.in_proj_qkv",
            "routingK": ROUTING_K,
            "transpose": True,
            "bits": 4,
            "groupSize": 64,
            "mode": "affine",
            "inputDType": "bfloat16",
            "weightDType": "uint32",
            "outputDType": "bfloat16",
        },
        "tensors": entries,
        "tensorFiles": {
            "weight": "qkv.weight.u32",
            "scales": "qkv.scales.bf16",
            "biases": "qkv.biases.bf16",
        },
        "cases": cases,
        "sourceBoundaries": {
            "referenceFile": reference_path.name,
            "referenceSHA256": sha256_file(reference_path),
            "nativeFile": native_path.name,
            "nativeSHA256": sha256_file(native_path),
        },
        "promptTokenIDs": [int(x) for x in reference["promptTokenIDs"]],
        "promptTokenCount": int(reference["promptTokenCount"]),
        "promptSHA256": reference.get("promptSHA256"),
        "python": platform.python_version(),
        "files": files,
    }
    write_json(output_dir / "metadata.json", metadata)
    manifest = {"metadataSHA256": sha256_file(output_dir / "metadata.json"), "files": files}
    write_json(output_dir / "manifest.json", manifest)

    if args.archive:
        archive = Path(args.archive).expanduser().resolve()
        if archive.exists():
            raise ReplayError(f"refusing to overwrite archive: {archive}")
        archive.parent.mkdir(parents=True, exist_ok=True)
        temporary = archive.with_name(archive.name + ".tmp")
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as handle:
            for path in sorted(output_dir.iterdir()):
                handle.write(path, path.name)
        temporary.replace(archive)
        print(json.dumps({"archive": str(archive), "archiveBytes": archive.stat().st_size, "archiveSHA256": sha256_file(archive)}, indent=2))
    print(json.dumps({"fixture": str(output_dir), "metadataSHA256": manifest["metadataSHA256"], "cases": cases}, indent=2))


def read_words(path: Path, item_size: int) -> array:
    raw = path.read_bytes()
    if len(raw) % item_size:
        raise ReplayError(f"unaligned raw tensor file: {path}")
    values = array("I" if item_size == 4 else "H")
    values.frombytes(raw)
    if sys.byteorder != "little":
        values.byteswap()
    return values


def flat_float(values: Any) -> list[float]:
    # MLX's flatten().tolist() is a flat list for both supported cores.
    return [float(x) for x in values.flatten().tolist()]


def bf16_values(path: Path) -> list[float]:
    words = read_words(path, 2)
    return [struct.unpack("<f", struct.pack("<I", int(word) << 16))[0] for word in words]


def metric(reference: list[float], actual: list[float]) -> dict[str, Any]:
    if len(reference) != len(actual):
        return {"countReference": len(reference), "countActual": len(actual), "relativeL2": None, "maxAbs": None}
    numerator = sum((float(a) - float(b)) ** 2 for a, b in zip(actual, reference))
    denominator = sum(float(b) ** 2 for b in reference)
    deltas = [abs(float(a) - float(b)) for a, b in zip(actual, reference)]
    worst = max(range(len(deltas)), key=deltas.__getitem__) if deltas else 0
    return {
        "count": len(reference),
        "relativeL2": math.sqrt(numerator) / max(math.sqrt(denominator), 1e-12),
        "maxAbs": max(deltas) if deltas else 0.0,
        "worstIndex": worst,
        "referenceAtWorst": reference[worst] if deltas else None,
        "actualAtWorst": actual[worst] if deltas else None,
    }


def run_operator(args: argparse.Namespace) -> None:
    # Import MLX only in run mode so ``create`` stays usable on a metadata-only
    # environment and the fixture can be produced without installing Python MLX.
    try:
        import mlx.core as mx
    except ImportError as error:
        raise ReplayError("run mode requires the selected Python MLX environment") from error
    fixture_dir = Path(args.fixture_dir).expanduser().resolve()
    metadata = json.loads((fixture_dir / "metadata.json").read_text())
    if metadata.get("format") != "qwen35-k8-qkv-operator-v1":
        raise ReplayError("unsupported operator fixture format")
    if metadata.get("artifact", {}).get("revision") != ARTIFACT_REVISION:
        raise ReplayError("operator fixture has the wrong artifact revision")
    device = mx.cpu if args.device == "cpu" else mx.gpu
    mx.set_default_device(device)

    def mlx_array(path: Path, shape: list[int], dtype: Any, item_size: int) -> Any:
        values = read_words(path, item_size)
        array_value = mx.array(values, dtype=dtype)
        return array_value.reshape(shape)

    tensors = metadata["tensorFiles"]
    weight = mlx_array(fixture_dir / tensors["weight"], metadata["tensors"][QKV_WEIGHT]["shape"], mx.uint32, 4)
    scales = mlx_array(fixture_dir / tensors["scales"], metadata["tensors"][QKV_SCALES]["shape"], mx.uint16, 2).view(mx.bfloat16)
    biases = mlx_array(fixture_dir / tensors["biases"], metadata["tensors"][QKV_BIASES]["shape"], mx.uint16, 2).view(mx.bfloat16)

    selected = metadata["cases"]
    if args.case != "all":
        selected = [case for case in selected if case["groupIndex"] == int(args.case)]
    if not selected:
        raise ReplayError(f"fixture has no selected case {args.case}")
    results = []
    for case in selected:
        input_shape = case["inputShape"]
        input_path = fixture_dir / case["input"]
        input_array = mlx_array(input_path, input_shape, mx.uint16, 2).view(mx.bfloat16)
        if args.tokens is not None:
            tokens = int(args.tokens)
            if tokens < 1 or tokens > input_shape[1]:
                raise ReplayError("--tokens must be within the saved group")
            input_array = input_array[:, :tokens, :]
            expected_shape = [1, tokens, case["outputShape"][2]]
        else:
            expected_shape = case["outputShape"]
        output = mx.quantized_matmul(
            input_array,
            weight,
            scales=scales,
            biases=biases,
            transpose=True,
            group_size=int(metadata["semantics"]["groupSize"]),
            bits=int(metadata["semantics"]["bits"]),
            mode=str(metadata["semantics"]["mode"]),
        )
        mx.eval(output)
        actual = flat_float(output)
        if args.tokens is None:
            reference = bf16_values(fixture_dir / case["referenceOutput"])
            native = bf16_values(fixture_dir / case["nativeOutput"])
        else:
            width = int(case["outputShape"][2])
            reference = bf16_values(fixture_dir / case["referenceOutput"])[: int(args.tokens) * width]
            native = bf16_values(fixture_dir / case["nativeOutput"])[: int(args.tokens) * width]
        raw_output = output.view(mx.uint16).flatten().tolist()
        results.append({
            "groupIndex": case["groupIndex"],
            "inputShape": list(input_array.shape),
            "outputShape": list(output.shape),
            "expectedShape": expected_shape,
            "outputDType": str(output.dtype),
            "outputRawBF16SHA256": sha256_bytes(b"".join(struct.pack("<H", int(x)) for x in raw_output)),
            "metricVsReference": metric(reference, actual),
            "metricVsNativeBoundary": metric(native, actual),
        })

    label = args.runtime_label or f"python-mlx-{importlib.metadata.version('mlx')}"
    report = {
        "format": "qwen35-k8-qkv-operator-result-v1",
        "fixtureFormat": metadata["format"],
        "artifactRevision": ARTIFACT_REVISION,
        "runtimeLabel": label,
        "mlxVersion": importlib.metadata.version("mlx"),
        "device": args.device,
        "python": platform.python_version(),
        "platform": platform.platform(),
        "cases": results,
    }
    output_path = Path(args.output).expanduser().resolve()
    write_json(output_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("create", "run"), required=True)
    parser.add_argument("--model-dir")
    parser.add_argument("--reference-boundary")
    parser.add_argument("--native-boundary")
    parser.add_argument("--output-dir")
    parser.add_argument("--archive")
    parser.add_argument("--fixture-dir")
    parser.add_argument("--output")
    parser.add_argument("--runtime-label")
    parser.add_argument("--device", choices=("cpu", "metal"), default="cpu")
    parser.add_argument("--case", choices=("all", "0", "1"), default="all")
    parser.add_argument("--tokens", type=int)
    args = parser.parse_args()
    try:
        if args.mode == "create":
            required = ("model_dir", "reference_boundary", "native_boundary", "output_dir")
            if any(getattr(args, name) is None for name in required):
                parser.error("create requires --model-dir, --reference-boundary, --native-boundary, and --output-dir")
            create_fixture(args)
        else:
            if args.fixture_dir is None or args.output is None:
                parser.error("run requires --fixture-dir and --output")
            run_operator(args)
    except (ReplayError, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"qwen35_qkv_operator_replay: ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
