#!/usr/bin/env python3
"""Small dependency-free regression tests for Q2.15 peak accounting."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from qwen35_k8_layer_oracle import (
    LayerOracleError,
    RollingContinuation,
    _decode_boundary_phase,
)
from qwen35_q215_storage import GIB, estimate_rolling_disk_budget


CONFIG = {
    "text_config": {
        "hidden_size": 2048,
        "num_hidden_layers": 40,
        "num_attention_heads": 16,
        "num_key_value_heads": 2,
        "head_dim": 256,
        "linear_num_value_heads": 32,
        "linear_num_key_heads": 16,
        "linear_key_head_dim": 128,
        "linear_value_head_dim": 128,
        "linear_conv_kernel_dim": 4,
        "mamba_ssm_dtype": "float32",
        "layer_types": [
            "full_attention" if (index + 1) % 4 == 0 else "linear_attention"
            for index in range(40)
        ],
    }
}


class Q215StorageTests(unittest.TestCase):
    def test_provisional_output_limit_remains_resumable(self) -> None:
        self.assertEqual(
            _decode_boundary_phase("output_limit", generated_count=2, max_output=64),
            "decode-ready",
        )
        self.assertEqual(
            _decode_boundary_phase("output_limit", generated_count=64, max_output=64),
            "complete",
        )
        self.assertEqual(
            _decode_boundary_phase("eos", generated_count=2, max_output=64),
            "complete",
        )

    def test_rolling_peak_does_not_sum_historical_stages(self) -> None:
        budget, state = estimate_rolling_disk_budget(
            CONFIG, prompt_tokens=186, output_tokens=64
        )
        cumulative_stage_total = budget.peak_working_bytes * 40
        self.assertLess(budget.peak_working_bytes, 1.5 * GIB)
        self.assertLess(budget.required_free_bytes, 2 * GIB)
        self.assertLess(budget.peak_working_bytes, cumulative_stage_total)
        self.assertEqual(
            budget.committed_continuation_bytes,
            state["committedContinuationBytes"],
        )
        self.assertEqual(
            budget.next_continuation_bytes,
            budget.committed_continuation_bytes,
        )
        self.assertEqual(
            state["replacementContinuationBytes"],
            state["nextContinuationBytes"],
        )
        self.assertGreater(state["largestLayerReplacementBytes"], 0)

    def test_state_growth_is_monotonic_with_output_reservation(self) -> None:
        short, short_state = estimate_rolling_disk_budget(
            CONFIG, prompt_tokens=186, output_tokens=1
        )
        long, long_state = estimate_rolling_disk_budget(
            CONFIG, prompt_tokens=186, output_tokens=128
        )
        self.assertLessEqual(short.required_free_bytes, long.required_free_bytes)
        self.assertLessEqual(
            short_state["continuationStateBytes"],
            long_state["continuationStateBytes"],
        )

    def test_resume_requires_explicit_opt_in_and_keeps_one_committed_state(self) -> None:
        identity = {
            "storageFormatVersion": "test",
            "artifactRevision": "revision",
        }
        with tempfile.TemporaryDirectory(prefix="qwen35-q215-rolling-") as directory:
            root = Path(directory)
            fresh = RollingContinuation(root, identity)
            with self.assertRaises(LayerOracleError):
                RollingContinuation(root / "missing", identity, resume=True)
            fresh.hidden_current.write_bytes(b"committed")
            fresh.write_progress({"phase": "prefill-head", "position": 4})

            with self.assertRaises(LayerOracleError):
                RollingContinuation(root, identity)

            resumed = RollingContinuation(root, identity, resume=True)
            self.assertTrue(resumed.resumed)
            self.assertEqual(resumed.hidden_current.read_bytes(), b"committed")
            self.assertEqual(resumed.read_progress(), {"phase": "prefill-head", "position": 4})
            self.assertFalse(any(resumed.next.iterdir()))

            with self.assertRaises(LayerOracleError):
                resumed.write_metadata("../outside.json", {})

    def test_partial_replacement_never_exposes_mixed_step_state(self) -> None:
        identity = {
            "storageFormatVersion": "test",
            "artifactRevision": "revision",
        }
        with tempfile.TemporaryDirectory(prefix="qwen35-q215-boundary-") as directory:
            root = Path(directory)
            rolling = RollingContinuation(root, identity)
            rolling.hidden_current.write_bytes(b"old-hidden")
            for layer in range(40):
                rolling.cache_current(layer).write_bytes(f"old-{layer}".encode())
            rolling.write_progress({"phase": "decode-ready", "step": 0})

            # A cancellation after the first replacement cache must leave the
            # previously committed state intact.
            rolling.hidden_next.write_bytes(b"new-hidden")
            rolling.cache_next(0).write_bytes(b"new-0")
            with self.assertRaises(LayerOracleError):
                rolling.commit_boundary(
                    progress={"phase": "decode-ready", "step": 1},
                    cache_layers=range(40),
                )
            self.assertEqual(rolling.hidden_current.read_bytes(), b"old-hidden")
            self.assertEqual(rolling.cache_current(0).read_bytes(), b"old-0")

            for layer in range(1, 40):
                rolling.cache_next(layer).write_bytes(f"new-{layer}".encode())
            rolling.commit_boundary(
                progress={"phase": "decode-ready", "step": 1},
                cache_layers=range(40),
            )
            self.assertEqual(rolling.hidden_current.read_bytes(), b"new-hidden")
            self.assertEqual(rolling.cache_current(39).read_bytes(), b"new-39")
            self.assertEqual(rolling.read_progress(), {"phase": "decode-ready", "step": 1})
            self.assertFalse(any(rolling.next.iterdir()))

    def test_interrupted_directory_swap_restores_old_committed_state(self) -> None:
        identity = {"storageFormatVersion": "test", "artifactRevision": "revision"}
        with tempfile.TemporaryDirectory(prefix="qwen35-q215-recovery-") as directory:
            root = Path(directory)
            rolling = RollingContinuation(root, identity)
            rolling.hidden_current.write_bytes(b"old")
            rolling.hidden_next.write_bytes(b"replacement")
            retired = root / "state-retired"
            rolling.current.replace(retired)

            recovered = RollingContinuation(root, identity, resume=True)
            self.assertTrue(recovered.resumed)
            self.assertEqual(recovered.hidden_current.read_bytes(), b"old")
            self.assertFalse(any(recovered.next.iterdir()))


if __name__ == "__main__":
    unittest.main()
