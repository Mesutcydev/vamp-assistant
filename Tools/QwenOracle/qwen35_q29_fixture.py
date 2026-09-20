#!/usr/bin/env python3
"""Freeze the Q2.8 router record with its exact teacher-forced history.

The output is a compact diagnostic fixture. It contains no model payloads;
the router inputs/logits/selectors are copied byte-for-byte from the frozen
Q2.8 record and the layer-19 router metadata is recorded by checksum.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import struct
import zipfile
from pathlib import Path
from typing import Any


Q28_FIXTURE_SHA256 = "6aee48b0b7516cee63e9447c4257c49f2045f82070bfd39ec9e59767d728d1c6"
Q28_REPORT_SHA256 = "35534d14736533554c35421e345c1fc0f75f93179572e12b0b692cd68ea22980"
MATCHED_CORE_ARCHIVE_SHA256 = "a1ee403e54fdcd496482bd4af972eebef553d20160b8a721bf2f55f299d53777"
ARTIFACT_REPO = "mlx-community/Qwen3.5-35B-A3B-4bit"
ARTIFACT_REVISION = "1e20fd8d42056f870933bf98ca6211024744f7ec"
ARTIFACT_INVENTORY_SHA256 = "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592"
ROUTING_K = 8


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def prompt_hash(token_ids: list[int]) -> str:
    return hashlib.sha256(str(token_ids).encode("utf-8")).hexdigest()


def header_entry(model_dir: Path, tensor: str) -> dict[str, Any]:
    index = json.loads((model_dir / "model.safetensors.index.json").read_text())
    shard = index["weight_map"][tensor]
    path = model_dir / shard
    with path.open("rb") as handle:
        header_length = struct.unpack("<Q", handle.read(8))[0]
        header = json.loads(handle.read(header_length))
        item = header[tensor]
        relative_start, relative_end = item["data_offsets"]
        payload_offset = 8 + header_length + relative_start
        byte_count = relative_end - relative_start
        handle.seek(payload_offset)
        payload = handle.read(byte_count)
    if len(payload) != byte_count:
        raise ValueError(f"short tensor payload for {tensor}")
    return {
        "name": tensor,
        "shard": shard,
        "dtype": item["dtype"],
        "shape": item["shape"],
        "relativeDataOffsets": [relative_start, relative_end],
        "payloadOffset": payload_offset,
        "byteCount": byte_count,
        "rawSHA256": sha256_bytes(payload),
        "firstBytes": payload[:32].hex(),
        "lastBytes": payload[-32:].hex(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--q28-fixture", type=Path, required=True)
    parser.add_argument("--q28-report", type=Path, required=True)
    parser.add_argument("--matched-core-archive", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    q28_bytes = args.q28_fixture.read_bytes()
    report_bytes = args.q28_report.read_bytes()
    archive_bytes = args.matched_core_archive.read_bytes()
    if sha256_bytes(q28_bytes) != Q28_FIXTURE_SHA256:
        raise SystemExit("Q2.8 fixture hash does not match the frozen record")
    if sha256_bytes(report_bytes) != Q28_REPORT_SHA256:
        raise SystemExit("Q2.8 report hash does not match the frozen record")
    if sha256_bytes(archive_bytes) != MATCHED_CORE_ARCHIVE_SHA256:
        raise SystemExit("matched-core archive hash does not match the frozen record")

    q28 = json.loads(q28_bytes)
    report = json.loads(report_bytes)
    if q28.get("fixtureFormatVersion") != "qwen35-k8-cutoff-tie-v1":
        raise SystemExit("unexpected Q2.8 fixture format")
    if q28.get("artifact", {}).get("revision") != ARTIFACT_REVISION:
        raise SystemExit("Q2.8 fixture has the wrong artifact revision")
    if q28.get("artifact", {}).get("inventorySHA256") != ARTIFACT_INVENTORY_SHA256:
        raise SystemExit("Q2.8 fixture has the wrong artifact inventory")

    with zipfile.ZipFile(args.matched_core_archive) as archive:
        primary = json.loads(archive.read("fixtures/primary.json"))
    prompt_ids = [int(value) for value in primary["promptTokenIDs"]]
    generated_ids = [int(value) for value in primary["generatedTokenIDs"]]
    layer = int(q28["layer"])
    position = int(q28["position"])
    decode_index = position - len(prompt_ids)
    if decode_index < 0 or decode_index >= len(generated_ids):
        raise SystemExit("target position is outside the frozen generated history")
    if prompt_hash(prompt_ids) != q28.get("promptSHA256"):
        raise SystemExit("Q2.8 prompt hash does not match the matched-core prompt")
    if int(q28.get("promptTokenCount", -1)) != len(prompt_ids):
        raise SystemExit("Q2.8 prompt count does not match the matched-core prompt")

    model_dir = args.model_dir.expanduser().resolve()
    tensor_names = [
        f"language_model.model.layers.{layer}.mlp.gate.weight",
        f"language_model.model.layers.{layer}.mlp.gate.scales",
        f"language_model.model.layers.{layer}.mlp.gate.biases",
    ]
    tensors = {name.rsplit(".gate.", 1)[1]: header_entry(model_dir, name) for name in tensor_names}

    value = {
        "fixtureFormatVersion": "qwen35-k8-q29-router-input-v1",
        "artifact": copy.deepcopy(q28["artifact"]),
        "source": {
            "q28FixturePath": str(args.q28_fixture),
            "q28FixtureSHA256": Q28_FIXTURE_SHA256,
            "q28ReportPath": str(args.q28_report),
            "q28ReportSHA256": Q28_REPORT_SHA256,
            "matchedCoreArchivePath": str(args.matched_core_archive),
            "matchedCoreArchiveSHA256": MATCHED_CORE_ARCHIVE_SHA256,
        },
        "layer": layer,
        "position": position,
        "routingK": ROUTING_K,
        "history": {
            "promptTokenIDs": prompt_ids,
            "promptTokenCount": len(prompt_ids),
            "promptSHA256": prompt_hash(prompt_ids),
            "generatedTokenIDs": generated_ids,
            "generatedTokenIDsConsumedBeforePosition": generated_ids[:decode_index],
            "targetInputTokenID": generated_ids[decode_index],
            "targetDecodeStep": decode_index + 1,
            "absolutePosition": position,
            "phase": "cached_decode",
            "prefillGroupSize": 4,
            "cacheBoundary": {
                "positionBefore": position,
                "positionAfter": position + 1,
                "promptPrefillComplete": True,
                "generatedTokensConsumedBeforePosition": decode_index,
            },
        },
        "reference": copy.deepcopy(q28["reference"]),
        "native": copy.deepcopy(q28["native"]),
        "expertProbe": copy.deepcopy(report.get("expertProbe")),
        "routerWeights": {
            "quantization": {
                "bits": 4,
                "groupSize": 64,
                "mode": "affine",
                "transpose": True,
                "inputDType": "bfloat16",
                "outputDType": "bfloat16",
            },
            "tensors": tensors,
        },
    }
    encoded = json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    if args.output.exists():
        raise SystemExit(f"refusing to overwrite {args.output}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    print(json.dumps({"path": str(args.output), "bytes": len(encoded), "sha256": sha256_bytes(encoded)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
