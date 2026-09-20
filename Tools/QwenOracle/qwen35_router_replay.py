#!/usr/bin/env python3
"""Replay captured Qwen3.5 K=8 router logits without loading model weights.

This is a development-only diagnostic.  It reads the bounded ``routerLogits``
summaries emitted by the layer-isolated oracle and by the native boundary
probe, then runs the pinned MLX softmax/argpartition selector on each captured
row.  No checkpoint payloads, hidden states, or expert weights are read.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path
from typing import Any, Iterable


ROUTING_K = 8


def _bfloat16_bits(values: Iterable[float]) -> list[int]:
    """Return the captured BF16 bit patterns without an FP32 re-quantize."""
    bits: list[int] = []
    for value in values:
        raw = struct.unpack("<I", struct.pack("<f", float(value)))[0]
        # Boundary summaries are emitted from BF16 arrays as Float.  A
        # nonzero low half would mean the source was already rounded through
        # an FP32-only value and is unsafe for this raw replay fixture.
        if raw & 0xFFFF:
            raise ValueError(f"captured value is not an exact BF16 scalar: {value!r}")
        bits.append(raw >> 16)
    return bits


def _product(shape: Iterable[int]) -> int:
    result = 1
    for value in shape:
        result *= int(value)
    return result


def _summary_values(summary: dict[str, Any]) -> list[float]:
    """Return a complete captured tensor, rejecting truncated summaries."""
    expected = _product(summary.get("shape", []))
    sample = [float(value) for value in summary.get("sample", [])]
    tail = [float(value) for value in summary.get("tailSample", [])]
    if expected <= 0:
        raise ValueError("router summary has an empty shape")
    # Q2.5 captures the entire small router tensors.  Older summaries only
    # contain a prefix/suffix and are intentionally not accepted here: using
    # them would make a selector replay appear complete when its middle rows
    # are unavailable.
    if len(sample) >= expected:
        return sample[:expected]
    if len(sample) + len(tail) >= expected and not tail:
        return (sample + tail)[:expected]
    raise ValueError(
        f"router summary is truncated: shape={summary.get('shape')} "
        f"sample={len(sample)} tail={len(tail)} expected={expected}"
    )


def _rel_l2(left: list[float], right: list[float]) -> float:
    if len(left) != len(right):
        return math.inf
    numerator = math.sqrt(sum((a - b) ** 2 for a, b in zip(left, right)))
    denominator = math.sqrt(sum(value * value for value in right))
    return numerator / max(denominator, 1e-12)


def _max_abs(left: list[float], right: list[float]) -> float:
    if len(left) != len(right):
        return math.inf
    return max((abs(a - b) for a, b in zip(left, right)), default=0.0)


def _records(boundary: dict[str, Any]) -> dict[tuple[int, int], dict[str, Any]]:
    result: dict[tuple[int, int], dict[str, Any]] = {}
    for group in boundary.get("groups", []):
        for layer in group.get("layers", []):
            layer_index = int(layer["layer"])
            for record in layer.get("router", []):
                # The independent oracle emits one scalar record per token;
                # the native trace groups a prefill batch into one record.
                grouped = "positions" in record
                positions = record.get("positions", [record.get("position")])
                ids = record.get("expertIDs", [])
                scores = record.get("scores", [])
                top_ids = record.get("topLogitIDs", [])
                top_logits = record.get("topLogits", [])
                for index, position in enumerate(positions):
                    if position is None or index >= len(ids) or index >= len(scores):
                        continue
                    selected = ids[index] if grouped else ids
                    selected_scores = scores[index] if grouped else scores
                    result[(layer_index, int(position))] = {
                        "expertIDs": [int(value) for value in selected],
                        "scores": [float(value) for value in selected_scores],
                        "topLogitIDs": (
                            [int(value) for value in (top_ids[index] if grouped else top_ids)]
                            if (index < len(top_ids) if grouped else bool(top_ids))
                            else []
                        ),
                        "topLogits": (
                            [float(value) for value in (top_logits[index] if grouped else top_logits)]
                            if (index < len(top_logits) if grouped else bool(top_logits))
                            else []
                        ),
                    }
    return result


def _logit_rows(boundary: dict[str, Any]) -> dict[tuple[int, int], list[float]]:
    result: dict[tuple[int, int], list[float]] = {}
    for group in boundary.get("groups", []):
        for layer in group.get("layers", []):
            components = layer.get("components") or {}
            summary = components.get("routerLogits")
            if not summary:
                continue
            values = _summary_values(summary)
            shape = [int(value) for value in summary["shape"]]
            if len(shape) < 2 or shape[-1] != 256:
                raise ValueError(f"unsupported router shape: {shape}")
            row_width = shape[-1]
            token_count = _product(shape[:-1])
            position = int(layer["positionBefore"])
            layer_index = int(layer["layer"])
            for token in range(token_count):
                result[(layer_index, position + token)] = values[
                    token * row_width : (token + 1) * row_width
                ]
    return result


def _component_rows(
    boundary: dict[str, Any], component_name: str, width: int
) -> dict[tuple[int, int], list[float]]:
    """Extract complete rows from a small component summary."""
    result: dict[tuple[int, int], list[float]] = {}
    for group in boundary.get("groups", []):
        for layer in group.get("layers", []):
            components = layer.get("components") or {}
            summary = components.get(component_name)
            if not summary:
                continue
            values = _summary_values(summary)
            shape = [int(value) for value in summary["shape"]]
            if len(shape) < 2 or shape[-1] != width:
                raise ValueError(f"unsupported {component_name} shape: {shape}")
            token_count = _product(shape[:-1])
            position = int(layer["positionBefore"])
            layer_index = int(layer["layer"])
            for token in range(token_count):
                result[(layer_index, position + token)] = values[
                    token * width : (token + 1) * width
                ]
    return result


def _select_row(row: list[float], selector: str) -> dict[str, Any]:
    """Run one explicitly named upstream selector expression.

    ``reference`` uses the negative-kth spelling used by the pinned Python
    implementations.  ``native`` uses the spelling in the Swift Qwen seam:
    ``width - K`` followed by a suffix slice.  They are mathematically
    equivalent for a non-tied row, but keeping both expressions here makes
    identical-input replay observable rather than assumed.
    """
    try:
        import mlx.core as mx
    except ImportError as error:  # pragma: no cover - environment diagnostic
        raise SystemExit("This replay requires the pinned mlx package.") from error

    # The captured router logits are BF16 in both the Python oracle and the
    # native path.  Keep that boundary here; promoting them to FP32 before
    # softmax would turn this into a different selector input.
    logits = mx.array(row, dtype=mx.bfloat16).reshape(1, 1, len(row))
    probabilities = mx.softmax(logits, axis=-1, precise=True)
    if selector == "reference":
        # mlx-lm's Qwen implementation uses the negative-kth form.
        selected = mx.argpartition(probabilities, kth=-ROUTING_K, axis=-1)[..., -ROUTING_K:]
        partitionKth = -ROUTING_K
        finalSliceStart = -ROUTING_K
    elif selector == "native":
        # QwenStreamModel.swift uses a positive partition index and suffix.
        partitionKth = len(row) - ROUTING_K
        finalSliceStart = partitionKth
        selected = mx.argpartition(probabilities, kth=partitionKth, axis=-1)[..., partitionKth:]
    else:  # pragma: no cover - internal programming error
        raise ValueError(f"unknown selector expression: {selector}")
    selectedScores = mx.take_along_axis(probabilities, selected, axis=-1)
    mx.eval(selected, selectedScores, probabilities)
    selectedIDs = [int(value) for value in selected.reshape(-1).tolist()]
    scores = [float(value) for value in selectedScores.reshape(-1).tolist()]
    selectionScores = [float(value) for value in probabilities.reshape(-1).tolist()]
    return {
        "expertIDs": selectedIDs,
        "scores": scores,
        "selectionScores": selectionScores,
        "selectionDType": str(probabilities.dtype),
        "selector": selector,
        "partitionKth": partitionKth,
        "finalSliceStart": finalSliceStart,
        "axis": -1,
        "softmaxPrecise": True,
    }


def _replay(
    rows: dict[tuple[int, int], list[float]],
    selector: str = "native",
) -> dict[tuple[int, int], dict[str, Any]]:
    return {key: _select_row(row, selector) for key, row in rows.items()}


def _top9(row: list[float]) -> tuple[list[int], list[float]]:
    ids = sorted(range(len(row)), key=lambda index: row[index], reverse=True)[: ROUTING_K + 1]
    return ids, [row[index] for index in ids]


def _rank_window(
    row: list[float],
    selection_scores: list[float],
    selected_ids: list[int],
    start_rank: int = 6,
    end_rank: int = 10,
) -> dict[str, Any]:
    """Return a deterministic presentation table around the K/K+1 cutoff."""
    ranked = sorted(range(len(row)), key=lambda index: (-row[index], index))
    window = ranked[start_rank - 1 : end_rank]
    kth_logit = row[ranked[ROUTING_K - 1]]
    next_logit = row[ranked[ROUTING_K]]
    kth_score = selection_scores[ranked[ROUTING_K - 1]]
    next_score = selection_scores[ranked[ROUTING_K]]
    cutoff_tied = [index for index, value in enumerate(row) if value == kth_logit]
    selection_cutoff_tied = [
        index for index, value in enumerate(selection_scores) if value == kth_score
    ]
    return {
        "rank6To10": [
            {
                "rank": rank,
                "expert": expert,
                "logit": row[expert],
                "selectionScore": selection_scores[expert],
                "selected": expert in set(selected_ids),
            }
            for rank, expert in zip(range(start_rank, end_rank + 1), window)
        ],
        "cutoff": {
            "kthRank": ROUTING_K,
            "nextRank": ROUTING_K + 1,
            "kthExpert": ranked[ROUTING_K - 1],
            "nextExpert": ranked[ROUTING_K],
            "kthLogit": kth_logit,
            "nextLogit": next_logit,
            "logitGap": kth_logit - next_logit,
            "kthSelectionScore": kth_score,
            "nextSelectionScore": next_score,
            "selectionScoreGap": kth_score - next_score,
            "exactCutoffTie": kth_logit == next_logit,
            "exactSelectionCutoffTie": kth_score == next_score,
            "expertsEqualToCutoff": cutoff_tied,
            "expertsEqualToSelectionCutoff": selection_cutoff_tied,
            "selectionDType": "bfloat16",
        },
    }


def _load(path: Path) -> dict[str, Any]:
    with path.open() as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"fixture root is not an object: {path}")
    return value


def _record_for(
    records: dict[tuple[int, int], dict[str, Any]], key: tuple[int, int]
) -> dict[str, Any]:
    value = records.get(key, {})
    return {
        "expertIDs": [int(item) for item in value.get("expertIDs", [])],
        "scores": [float(item) for item in value.get("scores", [])],
    }


def write_selector_fixture(
    reference_path: Path, native_path: Path, output_path: Path
) -> None:
    """Write only the complete BF16 router rows needed for tiny replay.

    The boundary probes expose BF16 values as Float scalars.  They are exact
    representations of the captured BF16 values; retaining the dtype and
    shape metadata prevents a later consumer from treating them as an
    arbitrary FP32 fixture.  The full 256-value rows are kept for positions
    1 (control), 2, and 7 from both sides, rather than another model copy.
    """
    reference = _load(reference_path)
    native = _load(native_path)
    reference_rows = _logit_rows(reference)
    native_rows = _logit_rows(native)
    reference_inputs = _component_rows(reference, "routerInput", 2048)
    native_inputs = _component_rows(native, "routerInput", 2048)
    reference_records = _records(reference)
    native_records = _records(native)
    keys = [(0, 1), (0, 2), (0, 7)]
    vectors: list[dict[str, Any]] = []
    for source_name, rows, records in (
        ("reference", reference_rows, reference_records),
        ("native", native_rows, native_records),
    ):
        for layer, position in keys:
            key = (layer, position)
            if key not in rows:
                raise ValueError(f"missing complete router row for {source_name} {key}")
            input_rows = reference_inputs if source_name == "reference" else native_inputs
            if key not in input_rows:
                raise ValueError(f"missing complete router input for {source_name} {key}")
            record = _record_for(records, key)
            selection = _select_row(rows[key], "native")
            vectors.append(
                {
                    "name": f"{source_name}-layer{layer}-position{position}",
                    "source": source_name,
                    "layer": layer,
                    "position": position,
                    "shape": [1, 1, len(rows[key])],
                    "dtype": "bfloat16",
                    "values": rows[key],
                    "rawBFloat16Bits": _bfloat16_bits(rows[key]),
                    "routerInputShape": [1, 1, len(input_rows[key])],
                    "routerInputDType": "bfloat16",
                    "routerInputValues": input_rows[key],
                    "routerInputRawBFloat16Bits": _bfloat16_bits(input_rows[key]),
                    "selectionScores": selection["selectionScores"],
                    "selectionDType": "bfloat16",
                    "selectionRawBFloat16Bits": _bfloat16_bits(selection["selectionScores"]),
                    "recordedExpertIDs": record["expertIDs"],
                    "recordedScores": record["scores"],
                }
            )
    payload = {
        "format": "qwen35-k8-router-selector-input-v1",
        "routingK": ROUTING_K,
        "artifact": reference.get("artifact", {}),
        "configSHA256": reference.get("configSHA256"),
        "tokenizerSHA256": reference.get("tokenizerSHA256"),
        "tokenizerConfigSHA256": reference.get("tokenizerConfigSHA256"),
        "templateSHA256": reference.get("templateSHA256"),
        "referenceBoundary": str(reference_path),
        "nativeBoundary": str(native_path),
        "selection": {
            "expertAxis": -1,
            "softmaxPrecise": True,
            "normTopkProb": True,
            "referenceExpression": "argpartition(softmax(logits, precise=True), kth=-8, axis=-1)[..., -8:]",
            "nativeExpression": "argPartition(gates, kth=width-8, axis=-1)[..., width-8...]",
            "referencePartitionKth": -8,
            "nativePartitionKth": 248,
            "finalSliceLength": ROUTING_K,
        },
        "control": {"layer": 0, "position": 1, "positionIsZeroBased": True},
        "mismatches": [
            {"layer": 0, "position": 2, "positionIsZeroBased": True},
            {"layer": 0, "position": 7, "positionIsZeroBased": True},
        ],
        "vectors": vectors,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _compare_native_selector_output(
    output_path: Path,
    reference_rows: dict[tuple[int, int], list[float]],
    native_rows: dict[tuple[int, int], list[float]],
) -> dict[str, Any]:
    """Compare the actual Swift/MLX tiny-test output with this replay."""
    output = _load(output_path)
    rows_by_source = {"reference": reference_rows, "native": native_rows}
    comparisons: list[dict[str, Any]] = []
    for actual in output.get("results", []):
        source = str(actual.get("source", ""))
        key = (int(actual["layer"]), int(actual["position"]))
        rows = rows_by_source.get(source, {})
        if key not in rows:
            comparisons.append(
                {"name": actual.get("name"), "error": "missing source row"}
            )
            continue
        expected = _select_row(rows[key], "native")
        expected_scores = expected["scores"]
        actual_scores = [float(value) for value in actual.get("selectionScores", [])]
        # The Swift output stores the eight scores before norm_topk_prob.  Its
        # separate ``scores`` field is the normalized execution weight.
        expected_execution = expected_scores
        total = sum(expected_execution)
        if total:
            expected_execution = [value / total for value in expected_execution]
        actual_execution = [float(value) for value in actual.get("scores", [])]
        comparisons.append(
            {
                "name": actual.get("name"),
                "source": source,
                "layer": key[0],
                "position": key[1],
                "device": actual.get("device", output.get("device")),
                "setEqual": sorted(actual.get("expertIDs", []))
                == sorted(expected["expertIDs"]),
                "orderEqual": actual.get("expertIDs", []) == expected["expertIDs"],
                "selectionScoresRelL2": _rel_l2(actual_scores, expected_scores),
                "selectionScoresMaxAbs": _max_abs(actual_scores, expected_scores),
                "executionScoresRelL2": _rel_l2(actual_execution, expected_execution),
                "executionScoresMaxAbs": _max_abs(actual_execution, expected_execution),
                "actualExpertIDs": [int(value) for value in actual.get("expertIDs", [])],
                "expectedExpertIDs": expected["expertIDs"],
            }
        )
    return {
        "path": str(output_path),
        "device": output.get("device", "unavailable"),
        "positionsCompared": len(comparisons),
        "allSetsEqual": all(item.get("setEqual", False) for item in comparisons),
        "allOrdersEqual": all(item.get("orderEqual", False) for item in comparisons),
        "allSelectionScoresWithinTolerance": all(
            item.get("selectionScoresRelL2", math.inf) <= 0.03
            and item.get("selectionScoresMaxAbs", math.inf) <= 0.05
            for item in comparisons
        ),
        "allExecutionScoresWithinTolerance": all(
            item.get("executionScoresRelL2", math.inf) <= 0.03
            and item.get("executionScoresMaxAbs", math.inf) <= 0.05
            for item in comparisons
        ),
        "comparisons": comparisons,
    }


def replay(
    reference_path: Path,
    native_path: Path,
    native_selector_output_path: Path | None = None,
) -> dict[str, Any]:
    reference = _load(reference_path)
    native = _load(native_path)
    reference_rows = _logit_rows(reference)
    native_rows = _logit_rows(native)
    reference_inputs = _component_rows(reference, "routerInput", 2048)
    native_inputs = _component_rows(native, "routerInput", 2048)
    reference_replay = _replay(reference_rows, "reference")
    native_replay = _replay(native_rows, "native")
    reference_records = _records(reference)
    native_records = _records(native)

    keys = sorted(set(reference_rows) | set(native_rows))
    comparisons: list[dict[str, Any]] = []
    for key in keys:
        reference_row = reference_rows.get(key)
        native_row = native_rows.get(key)
        expected_record = reference_records.get(key, {})
        native_record = native_records.get(key, {})
        expected_ids = expected_record.get("expertIDs", [])
        actual_ids = native_record.get("expertIDs", [])
        expected_replay = reference_replay.get(key, {}).get("expertIDs", [])
        actual_replay = native_replay.get(key, {}).get("expertIDs", [])
        item: dict[str, Any] = {
            "layer": key[0],
            "position": key[1],
            "recordedSetEqual": sorted(expected_ids) == sorted(actual_ids),
            "recordedOrderEqual": expected_ids == actual_ids,
            "referenceReplayMatchesRecord": sorted(expected_replay) == sorted(expected_ids),
            "nativeReplayMatchesRecord": sorted(actual_replay) == sorted(actual_ids),
            "referenceReplayIDs": expected_replay,
            "nativeReplayIDs": actual_replay,
            "referenceRecordedIDs": expected_ids,
            "nativeRecordedIDs": actual_ids,
        }
        # Identical-input A/B: both selector spellings consume each side's
        # complete score/logit row.  This separates changed inputs from a
        # changed partition/slice operation.
        if reference_row is not None:
            referenceInputReference = _select_row(reference_row, "reference")
            referenceInputNative = _select_row(reference_row, "native")
            item["referenceInputSelectorAB"] = {
                "reference": referenceInputReference["expertIDs"],
                "native": referenceInputNative["expertIDs"],
                "sameSet": sorted(referenceInputReference["expertIDs"])
                == sorted(referenceInputNative["expertIDs"]),
                "sameOrder": referenceInputReference["expertIDs"]
                == referenceInputNative["expertIDs"],
            }
        if native_row is not None:
            nativeInputReference = _select_row(native_row, "reference")
            nativeInputNative = _select_row(native_row, "native")
            item["nativeInputSelectorAB"] = {
                "reference": nativeInputReference["expertIDs"],
                "native": nativeInputNative["expertIDs"],
                "sameSet": sorted(nativeInputReference["expertIDs"])
                == sorted(nativeInputNative["expertIDs"]),
                "sameOrder": nativeInputReference["expertIDs"]
                == nativeInputNative["expertIDs"],
            }
        if reference_row is not None:
            ref_top_ids, ref_top_logits = _top9(reference_row)
            ref_selector = _select_row(reference_row, "reference")
            item["referenceTop9"] = [
                {"expert": expert, "logit": value}
                for expert, value in zip(ref_top_ids, ref_top_logits)
            ]
            item["referenceKthLogit"] = ref_top_logits[ROUTING_K - 1]
            item["referenceKPlusOneLogit"] = ref_top_logits[ROUTING_K]
            item["referenceKGap"] = ref_top_logits[ROUTING_K - 1] - ref_top_logits[ROUTING_K]
            item["referenceSelectionDType"] = ref_selector["selectionDType"]
            item["referenceRankWindow"] = _rank_window(
                reference_row,
                ref_selector["selectionScores"],
                ref_selector["expertIDs"],
            )
        if native_row is not None:
            native_top_ids, native_top_logits = _top9(native_row)
            native_selector = _select_row(native_row, "native")
            item["nativeTop9"] = [
                {"expert": expert, "logit": value}
                for expert, value in zip(native_top_ids, native_top_logits)
            ]
            item["nativeKthLogit"] = native_top_logits[ROUTING_K - 1]
            item["nativeKPlusOneLogit"] = native_top_logits[ROUTING_K]
            item["nativeKGap"] = native_top_logits[ROUTING_K - 1] - native_top_logits[ROUTING_K]
            item["nativeSelectionDType"] = native_selector["selectionDType"]
            item["nativeRankWindow"] = _rank_window(
                native_row,
                native_selector["selectionScores"],
                native_selector["expertIDs"],
            )
        if reference_row is not None and native_row is not None:
            item["routerLogitRelL2"] = _rel_l2(native_row, reference_row)
            item["routerLogitMaxAbs"] = _max_abs(native_row, reference_row)
        reference_input = reference_inputs.get(key)
        native_input = native_inputs.get(key)
        if reference_input is not None and native_input is not None:
            item["routerInputRelL2"] = _rel_l2(native_input, reference_input)
            item["routerInputMaxAbs"] = _max_abs(native_input, reference_input)
        comparisons.append(item)

    mismatches = [item for item in comparisons if not item["recordedSetEqual"]]
    result = {
        "format": "qwen35-k8-router-replay-v2",
        "routingK": ROUTING_K,
        "reference": str(reference_path),
        "native": str(native_path),
        "positionsCompared": len(comparisons),
        "recordedSetMismatches": len(mismatches),
        "recordedOrderOnly": sum(
            1 for item in comparisons
            if item["recordedSetEqual"] and not item["recordedOrderEqual"]
        ),
        "allReplaySelectorsMatchTheirOwnRecords": all(
            item["referenceReplayMatchesRecord"] and item["nativeReplayMatchesRecord"]
            for item in comparisons
        ),
        "allIdenticalInputSelectorSetsAgree": all(
            item.get("referenceInputSelectorAB", {}).get("sameSet", True)
            and item.get("nativeInputSelectorAB", {}).get("sameSet", True)
            for item in comparisons
        ),
        "allIdenticalInputSelectorOrdersAgree": all(
            item.get("referenceInputSelectorAB", {}).get("sameOrder", True)
            and item.get("nativeInputSelectorAB", {}).get("sameOrder", True)
            for item in comparisons
        ),
        "comparisons": comparisons,
    }
    if native_selector_output_path:
        result["nativeBackendSelector"] = _compare_native_selector_output(
            native_selector_output_path, reference_rows, native_rows
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--native-selector-output",
        type=Path,
        help="compare the actual Swift tiny-selector test output",
    )
    parser.add_argument(
        "--selector-fixture",
        type=Path,
        help="also write the compact complete rows for positions 1, 2, and 7",
    )
    args = parser.parse_args()
    if args.selector_fixture:
        write_selector_fixture(args.reference, args.native, args.selector_fixture)
    result = replay(args.reference, args.native, args.native_selector_output)
    payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload)
    print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
