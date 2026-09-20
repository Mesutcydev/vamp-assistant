"""Pure storage accounting for the disk-bounded Q2.15 oracle.

This module intentionally has no MLX dependency.  It describes the bytes that
can coexist when the layer oracle keeps one committed continuation checkpoint
and one bounded replacement checkpoint.  Historical stage outputs are not
part of the peak calculation.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
from typing import Any


MIB = 1024 * 1024
GIB = 1024 * MIB
Q215_STORAGE_FORMAT_VERSION = "qwen35-k8-q215-rolling-disk-v1"
Q215_LEGACY_Q214_FLOOR_BYTES = 3_758_096_384
Q215_DEFAULT_SAFETY_RESERVE_BYTES = 512 * MIB
Q215_COMPACT_FIXTURE_RESERVE_BYTES = 8 * MIB
Q215_METADATA_RESERVE_BYTES = 2 * MIB
Q215_WORKER_OUTPUT_RESERVE_BYTES = 2 * MIB
Q215_ATOMIC_METADATA_RESERVE_BYTES = 64 * 1024
Q215_BUILD_LOG_RESERVE_BYTES = 1 * MIB
Q215_HIDDEN_MAX_TOKENS = 4
Q215_SAFETENSORS_HEADER_RESERVE_BYTES = 4096


@dataclass(frozen=True)
class RollingDiskBudget:
    """A simultaneous peak estimate, with every category kept separate."""

    committed_continuation_bytes: int
    next_continuation_bytes: int
    diagnostic_snapshot_bytes: int
    temporary_worker_output_bytes: int
    atomic_write_duplicate_bytes: int
    persistent_fixture_bytes: int
    metadata_bytes: int
    build_log_overhead_bytes: int
    safety_reserve_bytes: int

    @property
    def peak_working_bytes(self) -> int:
        return sum(
            (
                self.committed_continuation_bytes,
                self.next_continuation_bytes,
                self.diagnostic_snapshot_bytes,
                self.temporary_worker_output_bytes,
                self.atomic_write_duplicate_bytes,
                self.persistent_fixture_bytes,
                self.metadata_bytes,
                self.build_log_overhead_bytes,
            )
        )

    @property
    def required_free_bytes(self) -> int:
        return self.peak_working_bytes + self.safety_reserve_bytes

    def as_dict(self) -> dict[str, int]:
        result = asdict(self)
        result["peak_working_bytes"] = self.peak_working_bytes
        result["required_free_bytes"] = self.required_free_bytes
        return result


def _text_config(config: dict[str, Any]) -> dict[str, Any]:
    value = config.get("text_config", config)
    if not isinstance(value, dict):
        raise ValueError("config text_config is not an object")
    return value


def _layer_counts(text_config: dict[str, Any]) -> tuple[int, int, list[int]]:
    layer_types = text_config.get("layer_types")
    if isinstance(layer_types, list) and layer_types:
        linear = sum(value == "linear_attention" for value in layer_types)
        full_indices = [
            index for index, value in enumerate(layer_types)
            if value == "full_attention"
        ]
        if linear + len(full_indices) != len(layer_types):
            raise ValueError("config layer_types contains an unsupported kind")
        return len(layer_types), linear, full_indices
    layers = int(text_config.get("num_hidden_layers", 0))
    interval = int(text_config.get("full_attention_interval", 0))
    if layers <= 0 or interval <= 0:
        raise ValueError("config has no usable layer layout")
    full_indices = [index for index in range(layers) if (index + 1) % interval == 0]
    return layers, layers - len(full_indices), full_indices


def continuation_state_bytes(
    config: dict[str, Any],
    *,
    prompt_tokens: int,
    output_tokens: int,
    batch: int = 1,
) -> dict[str, int]:
    """Derive the state payload from the actual config and target position.

    The layer worker stores GatedDeltaNet convolution state as BF16 and its
    recurrent matrix in the config-declared recurrent dtype.  Full-attention
    K/V caches are BF16.  The result is payload bytes plus a bounded
    per-file Safetensors/header allowance, rather than checkpoint bytes.
    """

    text = _text_config(config)
    layer_count, linear_count, full_indices = _layer_counts(text)
    del layer_count  # kept in the return below for audit readability
    value_heads = int(text.get("linear_num_value_heads", 0))
    key_heads = int(text.get("linear_num_key_heads", 0))
    key_dim = int(text.get("linear_key_head_dim", 0))
    value_dim = int(text.get("linear_value_head_dim", 0))
    conv_kernel = int(text.get("linear_conv_kernel_dim", 0))
    hidden_size = int(text.get("hidden_size", 0))
    full_kv_heads = int(text.get("num_key_value_heads", 0))
    head_dim = int(text.get("head_dim") or (hidden_size // max(int(text.get("num_attention_heads", 1)), 1)))
    recurrent_dtype = str(text.get("mamba_ssm_dtype", "float32")).lower()
    recurrent_bytes = 4 if "32" in recurrent_dtype else 2
    bf16_bytes = 2
    position_count = max(1, int(prompt_tokens) + max(0, int(output_tokens)))

    convolution_payload = (
        linear_count * batch * max(conv_kernel - 1, 0) * key_heads * key_dim * bf16_bytes
    )
    recurrent_payload = (
        linear_count * batch * value_heads * value_dim * key_dim * recurrent_bytes
    )
    kv_payload = (
        len(full_indices)
        * 2  # K and V
        * batch
        * full_kv_heads
        * position_count
        * head_dim
        * bf16_bytes
    )
    layer_file_count = linear_count + len(full_indices)
    safetensors_overhead = (layer_file_count * Q215_SAFETENSORS_HEADER_RESERVE_BYTES)
    # Each cache file has one small JSON sidecar carrying position/type.
    metadata_overhead = layer_file_count * 512
    payload = convolution_payload + recurrent_payload + kv_payload
    return {
        "positionCount": position_count,
        "linearLayerCount": linear_count,
        "fullAttentionLayerCount": len(full_indices),
        "convolutionPayloadBytes": convolution_payload,
        "recurrentPayloadBytes": recurrent_payload,
        "kvPayloadBytes": kv_payload,
        "payloadBytes": payload,
        "safetensorsHeaderReserveBytes": safetensors_overhead,
        "cacheMetadataReserveBytes": metadata_overhead,
        "continuationStateBytes": payload + safetensors_overhead + metadata_overhead,
    }


def estimate_rolling_disk_budget(
    config: dict[str, Any],
    *,
    prompt_tokens: int,
    output_tokens: int,
    safety_reserve_bytes: int = Q215_DEFAULT_SAFETY_RESERVE_BYTES,
) -> tuple[RollingDiskBudget, dict[str, int]]:
    """Return the simultaneous rolling peak and its state-size breakdown."""

    state = continuation_state_bytes(
        config,
        prompt_tokens=prompt_tokens,
        output_tokens=output_tokens,
    )
    text = _text_config(config)
    _, linear_count, full_indices = _layer_counts(text)
    value_heads = int(text.get("linear_num_value_heads", 0))
    key_heads = int(text.get("linear_num_key_heads", 0))
    key_dim = int(text.get("linear_key_head_dim", 0))
    value_dim = int(text.get("linear_value_head_dim", 0))
    recurrent_dtype = str(text.get("mamba_ssm_dtype", "float32")).lower()
    recurrent_bytes = 4 if "32" in recurrent_dtype else 2
    bf16_bytes = 2
    head_dim = int(text.get("head_dim") or (
        int(text.get("hidden_size", 0))
        // max(int(text.get("num_attention_heads", 1)), 1)
    ))
    layer_cache_candidates = [
        max(0, (max(int(text.get("linear_conv_kernel_dim", 0)) - 1, 0)
               * key_heads * key_dim * bf16_bytes
               + value_heads * value_dim * key_dim * recurrent_bytes
               + Q215_SAFETENSORS_HEADER_RESERVE_BYTES + 512)),
        max(0, (2 * int(text.get("num_key_value_heads", 0))
               * state["positionCount"]
               * head_dim
               * bf16_bytes
               + Q215_SAFETENSORS_HEADER_RESERVE_BYTES + 512)),
    ]
    largest_layer_state = max(layer_cache_candidates, default=0)
    hidden_bytes = Q215_HIDDEN_MAX_TOKENS * int(text.get("hidden_size", 0)) * bf16_bytes
    hidden_file_reserve = hidden_bytes + Q215_SAFETENSORS_HEADER_RESERVE_BYTES
    committed = state["continuationStateBytes"] + hidden_file_reserve
    # The coordinator now publishes at a whole prefill/decode boundary.  All
    # replacement layer caches therefore coexist below state-next until the
    # directory swap, rather than only the current layer's cache.  Historical
    # stage outputs are still deleted before the next worker is launched.
    next_state = committed
    budget = RollingDiskBudget(
        committed_continuation_bytes=committed,
        next_continuation_bytes=next_state,
        diagnostic_snapshot_bytes=Q215_COMPACT_FIXTURE_RESERVE_BYTES,
        temporary_worker_output_bytes=Q215_WORKER_OUTPUT_RESERVE_BYTES,
        atomic_write_duplicate_bytes=Q215_ATOMIC_METADATA_RESERVE_BYTES,
        persistent_fixture_bytes=Q215_COMPACT_FIXTURE_RESERVE_BYTES,
        metadata_bytes=Q215_METADATA_RESERVE_BYTES,
        build_log_overhead_bytes=Q215_BUILD_LOG_RESERVE_BYTES,
        safety_reserve_bytes=max(0, int(safety_reserve_bytes)),
    )
    state["hiddenCurrentBytes"] = hidden_file_reserve
    state["largestLayerReplacementBytes"] = largest_layer_state
    state["replacementContinuationBytes"] = next_state
    state["nextContinuationBytes"] = next_state
    state["committedContinuationBytes"] = committed
    state["linearLayerCount"] = linear_count
    state["fullAttentionLayerCount"] = len(full_indices)
    return budget, state


def directory_size(path: Path) -> int:
    """Return regular-file bytes below path without following symlinks."""

    if not path.exists():
        return 0
    if path.is_file() or path.is_symlink():
        return path.stat().st_size if path.is_file() else 0
    total = 0
    for child in path.rglob("*"):
        try:
            if child.is_file() and not child.is_symlink():
                total += child.stat().st_size
        except OSError:
            continue
    return total


def load_config(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("config is not an object")
    return value
