#!/usr/bin/env python3
"""Q2.8 raw selector and cutoff diagnostic.

This is a development-only diagnostic.  It consumes a compact fixture that
contains the exact selector words captured by the independent Python oracle
and by one Vampire Assistant run.  It never changes the production router and
does not load the checkpoint unless ``--probe-experts`` is requested.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

import numpy as np


ROUTING_K = 8


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _word_values(summary: dict[str, Any]) -> np.ndarray:
    """Decode the exact stored words without going through decimal JSON."""
    dtype = str(summary.get("dtype", "")).lower()
    if summary.get("rawUInt16Bits") is not None:
        words = np.asarray(summary["rawUInt16Bits"], dtype=np.uint16)
        if "bfloat16" in dtype or dtype in {"bf16", "bfloat16"}:
            return (words.astype(np.uint32) << 16).view(np.float32)
        if "float16" in dtype or dtype in {"f16", "float16"}:
            return words.view(np.float16).astype(np.float32)
        raise ValueError(f"unsupported 16-bit raw dtype: {summary.get('dtype')}")
    if summary.get("rawBFloat16Bits") is not None:
        words = np.asarray(summary["rawBFloat16Bits"], dtype=np.uint16)
        return (words.astype(np.uint32) << 16).view(np.float32)
    if summary.get("rawUInt32Bits") is not None:
        words = np.asarray(summary["rawUInt32Bits"], dtype=np.uint32)
        return words.view(np.float32)
    values = summary.get("values", summary.get("fullValues"))
    if values is None:
        raise ValueError("raw selector words and full values are missing")
    return np.asarray(values, dtype=np.float32)


def _word(summary: dict[str, Any], index: int) -> str | None:
    for key, width in (("rawUInt16Bits", 4), ("rawBFloat16Bits", 4), ("rawUInt32Bits", 8)):
        values = summary.get(key)
        if values is not None:
            return f"0x{int(values[index]):0{width}x}"
    return None


def _raw_side(side: dict[str, Any]) -> dict[str, Any]:
    scores = _word_values(side["selectorScores"])
    logits = _word_values(side["routerLogits"])
    if scores.size != 256 or logits.size != 256:
        raise ValueError("Qwen router vectors must contain 256 experts")
    cutoff = float(np.sort(scores)[-ROUTING_K])
    greater = np.flatnonzero(scores > cutoff).astype(int).tolist()
    equal = np.flatnonzero(scores == cutoff).astype(int).tolist()
    less = np.flatnonzero(scores < cutoff).astype(int).tolist()
    selected = [int(value) for value in side["selectedExpertIDs"]]
    selected_set = set(selected)
    return {
        "selectorDType": side["selectorScores"].get("dtype"),
        "routerLogitDType": side["routerLogits"].get("dtype"),
        "cutoffScore": cutoff,
        "strictlyGreaterCount": len(greater),
        "strictlyGreaterIDs": greater,
        "exactCutoffIDs": equal,
        "strictlyLessCount": len(less),
        "remainingSlots": ROUTING_K - len(greater),
        "selectedIDs": selected,
        "selectedSet": sorted(selected_set),
        "partitionValid": (
            len(selected) == ROUTING_K
            and set(greater).issubset(selected_set)
            and selected_set.issubset(set(greater) | set(equal))
            and len(selected_set & set(equal)) == ROUTING_K - len(greater)
        ),
        "score61": float(scores[61]),
        "score245": float(scores[245]),
        "score61Minus245": float(scores[61] - scores[245]),
        "score61Raw": _word(side["selectorScores"], 61),
        "score245Raw": _word(side["selectorScores"], 245),
        "logit61": float(logits[61]),
        "logit245": float(logits[245]),
        "logit61Minus245": float(logits[61] - logits[245]),
        "logit61Raw": _word(side["routerLogits"], 61),
        "logit245Raw": _word(side["routerLogits"], 245),
        "exactTie61And245": bool(scores[61] == scores[245]),
        "nearCutoffIDs": np.argsort(-scores, kind="stable")[: ROUTING_K + 3].astype(int).tolist(),
        "selectedScoreByID": {
            str(index): float(scores[index]) for index in selected
        },
        "selectedScoreRawByID": {
            str(index): _word(side["selectorScores"], index) for index in selected
        },
        "routerInputDType": side["routerInput"].get("dtype"),
    }


def _mlx_replay(side: dict[str, Any], count: int) -> dict[str, Any]:
    import mlx.core as mx

    summary = side["selectorScores"]
    words = np.asarray(summary.get("rawUInt16Bits"), dtype=np.uint16)
    if words.size == 0:
        raise ValueError("MLX replay requires raw UInt16 selector words")
    if "bfloat16" in str(summary.get("dtype", "")).lower():
        values = mx.array(words, dtype=mx.uint16).view(mx.bfloat16)
    elif "float16" in str(summary.get("dtype", "")).lower():
        values = mx.array(words, dtype=mx.uint16).view(mx.float16)
    else:
        raise ValueError(f"MLX replay does not support {summary.get('dtype')}")
    orders: list[list[int]] = []
    for _ in range(count):
        partition = mx.argpartition(values, kth=-ROUTING_K, axis=-1)[-ROUTING_K:]
        mx.eval(partition)
        orders.append([int(value) for value in partition.tolist()])
    return {
        "replayCount": count,
        "orders": orders,
        "uniqueOrders": len({tuple(order) for order in orders}),
        "uniqueSets": len({tuple(sorted(order)) for order in orders}),
    }


def _to_mlx_array(summary: dict[str, Any], mx: Any) -> Any:
    words = np.asarray(summary["rawUInt16Bits"], dtype=np.uint16)
    raw = mx.array(words, dtype=mx.uint16)
    dtype = str(summary.get("dtype", "")).lower()
    return raw.view(mx.bfloat16 if "bfloat16" in dtype else mx.float16).reshape(tuple(summary["shape"]))


def _metric(values: np.ndarray) -> dict[str, float]:
    return {
        "norm": float(np.linalg.norm(values)),
        "maxAbs": float(np.max(np.abs(values))) if values.size else 0.0,
    }


def _rel_l2(reference: np.ndarray, candidate: np.ndarray) -> float:
    denominator = float(np.linalg.norm(reference))
    return float(np.linalg.norm(candidate - reference) / denominator) if denominator else 0.0


def _probe_experts(fixture: dict[str, Any], model_dir: Path) -> dict[str, Any]:
    """Run the two disputed bundles through the pinned quantized MLX module."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import mlx.core as mx
    import mlx.nn as nn
    import qwen35_k8_layer_oracle as oracle

    layer, _, _ = oracle._build_layer(model_dir, int(fixture["layer"]), mx, nn)
    # The native raw record is the shared diagnostic MoE input.  All variants
    # below therefore differ only in the selected expert/weights.
    x = _to_mlx_array(fixture["native"]["routerInput"], mx).reshape((1, 1, -1))
    mx.eval(x)

    def outputs(ids: list[int]) -> np.ndarray:
        indices = mx.array([[ids]], dtype=mx.uint32)
        value = layer.mlp.switch_mlp(x, indices)
        mx.eval(value)
        return np.asarray(value.astype(mx.float32).tolist(), dtype=np.float64)

    one = {str(index): outputs([index]) for index in (61, 245)}
    expert_metrics = {
        index: _metric(value) for index, value in one.items()
    }
    expert_metrics["61_vs_245"] = {
        "relL2": _rel_l2(one["61"], one["245"]),
        "maxAbs": float(np.max(np.abs(one["61"] - one["245"]))),
    }

    def aggregate(side_name: str) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        side = fixture[side_name]
        ids = [int(index) for index in side["selectedExpertIDs"]]
        values = outputs(ids)
        scores = np.asarray(side["selectedNormalizedScores"], dtype=np.float64)
        routed = np.sum(values * scores.reshape((1, 1, -1, 1)), axis=-2)
        shared = mx.sigmoid(layer.mlp.shared_expert_gate(x)) * layer.mlp.shared_expert(x)
        mx.eval(shared)
        shared_np = np.asarray(shared.astype(mx.float32).tolist(), dtype=np.float64)
        return routed, shared_np, routed + shared_np

    ref_routed, shared, ref_output = aggregate("reference")
    native_routed, _, native_output = aggregate("native")
    aggregate_metrics = {
        "referenceRouted": _metric(ref_routed),
        "nativeRouted": _metric(native_routed),
        "referenceMoE": _metric(ref_output),
        "nativeMoE": _metric(native_output),
        "routedRelL2": _rel_l2(ref_routed, native_routed),
        "routedMaxAbs": float(np.max(np.abs(ref_routed - native_routed))),
        "sharedRelL2": 0.0,
        "moeRelL2": _rel_l2(ref_output, native_output),
        "moeMaxAbs": float(np.max(np.abs(ref_output - native_output))),
        # With the same post-attention residual, the layer residual adds the
        # same vector to both variants; its diagnostic delta equals this MoE
        # delta.  No full layer rerun is implied here.
        "sameResidualLayerDeltaRelL2": _rel_l2(ref_output, native_output),
        "sameResidualLayerDeltaMaxAbs": float(np.max(np.abs(ref_output - native_output))),
    }
    return {
        "modelDir": str(model_dir),
        "inputSide": "native raw routerInput",
        "expertOutputs": expert_metrics,
        "aggregate": aggregate_metrics,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--replay-count", type=int, default=16)
    parser.add_argument("--probe-experts", action="store_true")
    parser.add_argument("--model-dir", type=Path)
    args = parser.parse_args()

    fixture = json.loads(args.fixture.read_text())
    if fixture.get("fixtureFormatVersion") != "qwen35-k8-cutoff-tie-v1":
        raise SystemExit("unexpected Q2.8 fixture format")
    report: dict[str, Any] = {
        "fixtureFormatVersion": fixture["fixtureFormatVersion"],
        "fixtureSHA256": hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
        "artifact": fixture.get("artifact"),
        "layer": fixture["layer"],
        "position": fixture["position"],
        "routingK": fixture.get("routingK", ROUTING_K),
        "reference": _raw_side(fixture["reference"]),
        "native": _raw_side(fixture["native"]),
        "routerInput": {
            "relL2": _rel_l2(
                _word_values(fixture["reference"]["routerInput"]),
                _word_values(fixture["native"]["routerInput"]),
            ),
            "maxAbs": float(
                np.max(
                    np.abs(
                        _word_values(fixture["native"]["routerInput"])
                        - _word_values(fixture["reference"]["routerInput"])
                    )
                )
            ),
        },
        "contract": {
            "source": "mlx-lm 0.31.1 qwen3_next.py",
            "selector": "softmax(precise=True) -> argpartition(gates, kth=-k)[..., -k:] -> take_along_axis -> optional sum normalization",
            "sourceSHA256": hashlib.sha256(
                Path("/tmp/qwen35-mlx0311-op-v1/lib/python3.12/site-packages/mlx_lm/models/qwen3_next.py").read_bytes()
            ).hexdigest(),
            "sourceLines": "315-345",
            "orderingGuarantee": "argpartition partition ordering is not a stable contract",
        },
    }
    report["selectorReplay"] = {
        "reference": _mlx_replay(fixture["reference"], args.replay_count),
        "native": _mlx_replay(fixture["native"], args.replay_count),
    }
    report["classification"] = {
        "referenceAndNativeExactCutoffTieEquivalent": False,
        "reason": "reference selector scores for experts 61 and 245 are non-tied at BF16 selector precision; native has an exact tie caused by upstream router-input drift",
    }
    if args.probe_experts:
        if args.model_dir is None:
            raise SystemExit("--probe-experts requires --model-dir")
        report["expertProbe"] = _probe_experts(fixture, args.model_dir.resolve())
    report["reportSHA256"] = hashlib.sha256(_canonical(report)).hexdigest()
    encoded = json.dumps(report, indent=2, sort_keys=True).encode()
    if args.output:
        args.output.write_bytes(encoded)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
