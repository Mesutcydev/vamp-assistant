#!/usr/bin/env python3
"""Compare bounded Qwen K=8 activation boundaries from independent JSON files.

This development-only tool reads the compact full-value boundary captures
produced by ``qwen35_k8_layer_oracle.py`` and the opt-in native XCTest trace.
It never opens checkpoint shards and never calls the Vampire Assistant
runtime.  The comparison is therefore safe to run repeatedly without
allocating another model copy.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path
from typing import Any


def _values(summary: dict[str, Any]) -> list[float]:
    raw = summary.get("rawBFloat16Bits")
    if raw is not None:
        return [
            struct.unpack(">f", (int(value) << 16).to_bytes(4, "big"))[0]
            for value in raw
        ]
    values = summary.get("values", summary.get("fullValues"))
    if values is None:
        raise ValueError(f"summary has no complete values: {summary.get('shape')}")
    return [float(value) for value in values]


def _row(summary: dict[str, Any], token_index: int) -> tuple[list[float], list[int]]:
    shape = [int(value) for value in summary["shape"]]
    values = _values(summary)
    if len(shape) >= 2 and shape[0] == 1:
        row_shape = shape[2:]
        width = math.prod(row_shape) if row_shape else shape[1]
    elif len(shape) >= 2:
        row_shape = shape[1:]
        width = math.prod(row_shape)
    else:
        row_shape = shape
        width = len(values)
    start = token_index * width
    end = start + width
    if end > len(values):
        raise ValueError(
            f"token row {token_index} is outside {shape}: {len(values)} values"
        )
    return values[start:end], row_shape


def _coordinate(flat_index: int, shape: list[int]) -> list[int]:
    if not shape:
        return []
    result = [0] * len(shape)
    value = flat_index
    for index in range(len(shape) - 1, -1, -1):
        dimension = shape[index]
        result[index] = value % dimension if dimension else 0
        value //= dimension if dimension else 1
    return result


def _metric(
    name: str,
    reference: list[float],
    native: list[float],
    row_shape: list[int],
    reference_summary: dict[str, Any],
    native_summary: dict[str, Any],
) -> dict[str, Any]:
    if len(reference) != len(native):
        return {
            "name": name,
            "shape": row_shape,
            "referenceShape": reference_summary.get("shape"),
            "nativeShape": native_summary.get("shape"),
            "referenceDType": reference_summary.get("dtype"),
            "nativeDType": native_summary.get("dtype"),
            "referenceCount": len(reference),
            "nativeCount": len(native),
            "referenceNorm": None,
            "nativeNorm": None,
            "relativeL2": math.inf,
            "maxAbs": math.inf,
            "worstIndex": None,
            "worstCoordinate": None,
        }

    reference_norm = math.sqrt(sum(float(value) ** 2 for value in reference))
    native_norm = math.sqrt(sum(float(value) ** 2 for value in native))
    differences = [float(rhs) - float(lhs) for lhs, rhs in zip(reference, native)]
    difference_norm = math.sqrt(sum(value * value for value in differences))
    worst_index = max(
        range(len(differences)), key=lambda index: abs(differences[index]), default=0
    )
    return {
        "name": name,
        "shape": row_shape,
        "referenceShape": reference_summary.get("shape"),
        "nativeShape": native_summary.get("shape"),
        "referenceDType": reference_summary.get("dtype"),
        "nativeDType": native_summary.get("dtype"),
        "referenceCount": len(reference),
        "nativeCount": len(native),
        "referenceNorm": reference_norm,
        "nativeNorm": native_norm,
        "relativeL2": difference_norm / max(reference_norm, 1e-30),
        "maxAbs": max(map(abs, differences), default=0.0),
        "worstIndex": worst_index,
        "worstCoordinate": _coordinate(worst_index, row_shape),
        "referenceWorst": reference[worst_index] if reference else None,
        "nativeWorst": native[worst_index] if native else None,
    }


def _summary_metric(
    name: str,
    reference_summary: dict[str, Any],
    native_summary: dict[str, Any],
    token_index: int,
) -> dict[str, Any]:
    reference, reference_shape = _row(reference_summary, token_index)
    native, native_shape = _row(native_summary, token_index)
    if reference_shape != native_shape:
        row_shape = reference_shape
    else:
        row_shape = reference_shape
    return _metric(
        name,
        reference,
        native,
        row_shape,
        reference_summary,
        native_summary,
    )


def _get(mapping: dict[str, Any], path: tuple[str, ...]) -> dict[str, Any]:
    value: Any = mapping
    for key in path:
        value = value[key]
    if not isinstance(value, dict):
        raise ValueError(f"{'.'.join(path)} is not an activation summary")
    return value


def _router_score_metric(
    reference_layer: dict[str, Any],
    native_layer: dict[str, Any],
    position: int,
) -> dict[str, Any]:
    reference_records = {
        int(record["position"]): record for record in reference_layer.get("router", [])
    }
    native_records: dict[int, dict[str, Any]] = {}
    for record in native_layer.get("router", []):
        positions = record.get("positions", [])
        expert_ids = record.get("expertIDs", [])
        scores = record.get("scores", [])
        for index, item in enumerate(positions):
            if index < len(expert_ids) and index < len(scores):
                native_records[int(item)] = {
                    "expertIDs": expert_ids[index],
                    "scores": scores[index],
                }
    reference_record = reference_records.get(position)
    native_record = native_records.get(position)
    if reference_record is None or native_record is None:
        return {
            "name": "selectionScores",
            "position": position,
            "missing": True,
            "selectedSetEqual": False,
            "selectedOrderEqual": False,
        }
    reference_ids = [int(value) for value in reference_record["expertIDs"]]
    native_ids = [int(value) for value in native_record["expertIDs"]]
    reference_by_id = dict(zip(reference_ids, reference_record["scores"]))
    native_by_id = dict(zip(native_ids, native_record["scores"]))
    common_ids = [value for value in reference_ids if value in native_by_id]
    reference_scores = [float(reference_by_id[value]) for value in common_ids]
    native_scores = [float(native_by_id[value]) for value in common_ids]
    metric = _metric(
        "selectionScores",
        reference_scores,
        native_scores,
        [len(common_ids)],
        {"shape": [len(common_ids)], "dtype": "bfloat16"},
        {"shape": [len(common_ids)], "dtype": "bfloat16"},
    )
    metric.update(
        {
            "position": position,
            "referenceExpertIDs": reference_ids,
            "nativeExpertIDs": native_ids,
            "commonExpertIDs": common_ids,
            "selectedSetEqual": set(reference_ids) == set(native_ids),
            "selectedOrderEqual": reference_ids == native_ids,
        }
    )
    return metric


def compare(reference: dict[str, Any], native: dict[str, Any]) -> dict[str, Any]:
    if reference.get("promptTokenIDs") != native.get("promptTokenIDs"):
        raise ValueError("reference/native prompt token IDs differ")
    if reference.get("prefillGroupSize") != native.get("prefillGroupSize"):
        raise ValueError("reference/native prefill group sizes differ")

    activation_paths: list[tuple[str, tuple[str, ...]]] = [
        ("embedding", ("embedding", "output")),
        ("inputNormalization", ("layers", "components", "attentionInput")),
        ("attentionOutput", ("layers", "components", "attentionOutput")),
        (
            "postAttentionResidual",
            ("layers", "components", "postAttentionResidual"),
        ),
        ("postAttentionNormalization", ("layers", "components", "postAttentionInput")),
        ("routerLogits", ("layers", "components", "routerLogits")),
    ]
    subpath_paths: list[tuple[str, tuple[str, ...]]] = [
        ("qkv", ("layers", "components", "linearProjections", "qkv")),
        ("z", ("layers", "components", "linearProjections", "z")),
        ("b", ("layers", "components", "linearProjections", "b")),
        ("a", ("layers", "components", "linearProjections", "a")),
        ("convOutput", ("layers", "components", "linearAttention", "convOutput")),
        ("qNormed", ("layers", "components", "linearAttention", "qNormed")),
        ("kNormed", ("layers", "components", "linearAttention", "kNormed")),
        ("v", ("layers", "components", "linearAttention", "v")),
        ("gatedOutput", ("layers", "components", "linearAttention", "gatedOutput")),
        (
            "normalizedOutput",
            ("layers", "components", "linearAttention", "normalizedOutput"),
        ),
        ("attentionOutput", ("layers", "components", "attentionOutput")),
    ]

    groups: list[dict[str, Any]] = []
    for reference_group, native_group in zip(
        reference.get("groups", []), native.get("groups", [])
    ):
        group_index = int(reference_group["groupIndex"])
        if reference_group.get("tokenIDs") != native_group.get("tokenIDs"):
            raise ValueError(f"token IDs differ in group {group_index}")
        reference_layer = reference_group["layers"][0]
        native_layer = native_group["layers"][0]
        rows: list[dict[str, Any]] = []
        for token_index, position in enumerate(
            range(
                int(reference_group["positionBefore"]),
                int(reference_group["positionAfter"]),
            )
        ):
            activation: list[dict[str, Any]] = []
            for name, path in activation_paths:
                reference_summary = (
                    reference_group["embedding"]["output"]
                    if name == "embedding"
                    else _get(reference_layer, path[1:])
                )
                native_summary = (
                    native_group["embedding"]
                    if name == "embedding"
                    else _get(native_layer, path[1:])
                )
                metric = _summary_metric(
                    name,
                    reference_summary,
                    native_summary,
                    token_index,
                )
                metric["position"] = position
                activation.append(metric)
            selection = _router_score_metric(reference_layer, native_layer, position)
            first_activation = next(
                (
                    item["name"]
                    for item in activation
                    if item.get("relativeL2", 0.0) > 1e-7
                ),
                None,
            )
            subpath: list[dict[str, Any]] = []
            for name, path in subpath_paths:
                reference_summary = _get(reference_layer, path[1:])
                native_summary = _get(native_layer, path[1:])
                metric = _summary_metric(
                    name,
                    reference_summary,
                    native_summary,
                    token_index,
                )
                metric["position"] = position
                subpath.append(metric)
            first_subpath = next(
                (
                    item["name"]
                    for item in subpath
                    if item.get("relativeL2", 0.0) > 1e-7
                ),
                None,
            )
            rows.append(
                {
                    "position": position,
                    "tokenID": reference_group["tokenIDs"][token_index],
                    "firstDifferingActivation": first_activation,
                    "firstDifferingLinearAttentionOperation": first_subpath,
                    "activation": activation,
                    "linearAttentionSubpath": subpath,
                    "selectionScores": selection,
                }
            )
        groups.append({"groupIndex": group_index, "rows": rows})

    return {
        "format": "qwen35-k8-q26-activation-comparison-v1",
        "referenceFixtureFormat": reference.get("fixtureFormatVersion"),
        "nativeFixtureFormat": native.get("fixtureFormatVersion"),
        "promptTokenIDs": reference.get("promptTokenIDs"),
        "promptSHA256": reference.get("promptSHA256"),
        "groups": groups,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = compare(
        json.loads(args.reference.read_text()),
        json.loads(args.native.read_text()),
    )
    encoded = json.dumps(result, indent=2, sort_keys=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_name(args.output.name + ".tmp")
        temporary.write_text(encoded + "\n")
        temporary.replace(args.output)
    else:
        print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
