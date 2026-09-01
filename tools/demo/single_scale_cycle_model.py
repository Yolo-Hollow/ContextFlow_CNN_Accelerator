"""Cycle and traffic model for the ten-layer single-scale accelerator path.

The model is deliberately independent of UART telemetry.  It describes the
amount of useful array work and the logical layer-to-layer HWC traffic that a
correct implementation must perform.  This makes it useful both before RTL
exists and as a hard reference when checking future performance counters.

Examples:

    python tools/demo/single_scale_cycle_model.py
    python tools/demo/single_scale_cycle_model.py --rows 18 --cols 8
    python tools/demo/single_scale_cycle_model.py --metrics-json metrics.json
    python tools/demo/single_scale_cycle_model.py --json
"""

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


DEFAULT_FREQUENCY_MHZ = 100.0
DEFAULT_AXIS_BYTES = 8
OUTPUTS_PER_COLUMN = 2
MATERIALIZER_STORE_BYTES_PER_CYCLE = 4
MATERIALIZER_3X3_ENTRY_CYCLES = 1
MATERIALIZER_1X1_ENTRY_CYCLES = 5

TARGET_ROWS = 18
TARGET_COLS = 16
TARGET_COUT_TILE = 32

TARGET_PL_BUSY_CYCLES = 7_000_000
TARGET_FEEDER_CYCLES = 2_000_000
TARGET_CONTEXT_PSUM_GAP_CYCLES = 300_000
TARGET_DRAIN_OFM_POST_CYCLES = 600_000
TARGET_BIAS_WEIGHT_WAIT_CYCLES = 200_000
TARGET_UNCLASSIFIED_CYCLES = 10_000
TARGET_SOFTWARE_PACK_PARSE_US = 1_000
TARGET_DMA_STARTS = 10
TARGET_IFM_BYTES_LIMIT = 2_500_000

ZERO_ERROR_METRICS = (
    "prefetch_miss_count",
    "ifm_underflow_count",
    "psum_underflow_count",
    "fifo_drop_count",
    "epoch_mismatch_count",
    "context_full_stall_cycles",
)


def ceil_div(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise ValueError("denominator must be positive")
    return (numerator + denominator - 1) // denominator


@dataclass(frozen=True)
class ArrayConfig:
    rows: int = TARGET_ROWS
    cols: int = TARGET_COLS
    cout_tile: Optional[int] = None

    def __post_init__(self) -> None:
        if self.rows <= 0:
            raise ValueError("ROWS must be positive")
        if self.cols <= 0:
            raise ValueError("COLS must be positive")

        cout_tile = self.cols * OUTPUTS_PER_COLUMN if self.cout_tile is None else self.cout_tile
        if cout_tile <= 0:
            raise ValueError("COUT_TILE must be positive")
        if cout_tile > self.cols * OUTPUTS_PER_COLUMN:
            raise ValueError(
                "COUT_TILE cannot exceed two output lanes per physical column "
                f"({self.cols * OUTPUTS_PER_COLUMN})"
            )
        object.__setattr__(self, "cout_tile", cout_tile)


@dataclass(frozen=True)
class LayerSpec:
    index: int
    name: str
    ifm_h: int
    ifm_w: int
    cin: int
    cout: int
    kernel: int
    stored_ofm_h: int
    stored_ofm_w: int
    pl_busy_budget_cycles: int

    @property
    def conv_pixels(self) -> int:
        # Every layer in this path uses same-size convolution.  Pooling, when
        # enabled, happens after convolution and therefore does not reduce MACs.
        return self.ifm_h * self.ifm_w

    @property
    def k_total(self) -> int:
        return self.cin * self.kernel * self.kernel

    @property
    def ifm_bytes(self) -> int:
        return self.ifm_h * self.ifm_w * self.cin

    @property
    def ofm_bytes(self) -> int:
        return self.stored_ofm_h * self.stored_ofm_w * self.cout


# Names match the stable UART PERF layer names so model and telemetry can be
# joined without a translation table.
SINGLE_SCALE_LAYERS: Tuple[LayerSpec, ...] = (
    LayerSpec(0, "conv0_pool", 416, 416, 3, 16, 3, 208, 208, 750_000),
    LayerSpec(1, "conv1_pool", 208, 208, 16, 32, 3, 104, 104, 750_000),
    LayerSpec(2, "conv2_pool", 104, 104, 32, 64, 3, 52, 52, 700_000),
    LayerSpec(3, "conv3_pool", 52, 52, 64, 128, 3, 26, 26, 650_000),
    LayerSpec(4, "conv4_pool", 26, 26, 128, 256, 3, 13, 13, 550_000),
    LayerSpec(5, "conv5", 13, 13, 256, 512, 3, 13, 13, 550_000),
    LayerSpec(6, "conv6", 13, 13, 512, 1024, 3, 13, 13, 2_100_000),
    LayerSpec(7, "conv7_native1x1", 13, 13, 1024, 256, 1, 13, 13, 350_000),
    LayerSpec(8, "conv8", 13, 13, 256, 512, 3, 13, 13, 550_000),
    LayerSpec(9, "conv9_detect_native1x1", 13, 13, 512, 24, 1, 13, 13, 50_000),
)


def cycles_to_ms(cycles: int, frequency_mhz: float) -> float:
    if frequency_mhz <= 0:
        raise ValueError("frequency must be positive")
    return cycles / (frequency_mhz * 1000.0)


def layer_model(layer: LayerSpec, config: ArrayConfig, axis_bytes: int) -> Dict[str, Any]:
    if axis_bytes <= 0:
        raise ValueError("AXIS beat width must be positive")

    k_passes = ceil_div(layer.k_total, config.rows)
    cout_blocks = ceil_div(layer.cout, config.cout_tile)
    compute_fire_cycles = layer.conv_pixels * k_passes * cout_blocks
    materialized_passes = (
        ceil_div(layer.cin, config.rows)
        if layer.kernel == 1
        else ceil_div(layer.cin, 2)
    )
    materialized_entries = layer.conv_pixels * materialized_passes
    entry_service_cycles = (
        MATERIALIZER_1X1_ENTRY_CYCLES
        if layer.kernel == 1
        else MATERIALIZER_3X3_ENTRY_CYCLES
    )
    materializer_store_cycles = ceil_div(
        layer.ifm_bytes, MATERIALIZER_STORE_BYTES_PER_CYCLE
    )
    materializer_entry_cycles = materialized_entries * entry_service_cycles
    return {
        "index": layer.index,
        "layer": layer.name,
        "ifm_shape": [layer.ifm_h, layer.ifm_w, layer.cin],
        "stored_ofm_shape": [layer.stored_ofm_h, layer.stored_ofm_w, layer.cout],
        "kernel": layer.kernel,
        "k_total": layer.k_total,
        "k_passes": k_passes,
        "cout_blocks": cout_blocks,
        "conv_pixels": layer.conv_pixels,
        "compute_fire_cycles": compute_fire_cycles,
        "materialized_passes": materialized_passes,
        "materialized_entries": materialized_entries,
        "materializer_store_cycles": materializer_store_cycles,
        "materializer_entry_cycles": materializer_entry_cycles,
        "materializer_serial_cycles": (
            materializer_store_cycles + materializer_entry_cycles
        ),
        "ifm_bytes": layer.ifm_bytes,
        "ifm_beats": ceil_div(layer.ifm_bytes, axis_bytes),
        "ofm_bytes": layer.ofm_bytes,
        "ofm_beats": ceil_div(layer.ofm_bytes, axis_bytes),
        "pl_busy_budget_cycles": layer.pl_busy_budget_cycles,
    }


def build_model(
    config: ArrayConfig = ArrayConfig(),
    frequency_mhz: float = DEFAULT_FREQUENCY_MHZ,
    axis_bytes: int = DEFAULT_AXIS_BYTES,
) -> Dict[str, Any]:
    if frequency_mhz <= 0:
        raise ValueError("frequency must be positive")
    if axis_bytes <= 0:
        raise ValueError("AXIS beat width must be positive")

    layers = [layer_model(layer, config, axis_bytes) for layer in SINGLE_SCALE_LAYERS]
    compute_fire_cycles = sum(layer["compute_fire_cycles"] for layer in layers)
    ifm_bytes = sum(layer["ifm_bytes"] for layer in layers)
    ofm_bytes = sum(layer["ofm_bytes"] for layer in layers)
    ifm_beats = sum(layer["ifm_beats"] for layer in layers)
    ofm_beats = sum(layer["ofm_beats"] for layer in layers)
    materialized_entries = sum(layer["materialized_entries"] for layer in layers)
    materializer_store_cycles = sum(
        layer["materializer_store_cycles"] for layer in layers
    )
    materializer_entry_cycles = sum(
        layer["materializer_entry_cycles"] for layer in layers
    )
    materializer_serial_cycles = (
        materializer_store_cycles + materializer_entry_cycles
    )

    overhead_allocation = {
        "feeder_cycles": TARGET_FEEDER_CYCLES,
        "context_psum_gap_cycles": TARGET_CONTEXT_PSUM_GAP_CYCLES,
        "drain_ofm_post_cycles": TARGET_DRAIN_OFM_POST_CYCLES,
        "bias_weight_wait_cycles": TARGET_BIAS_WEIGHT_WAIT_CYCLES,
        "unclassified_cycles": TARGET_UNCLASSIFIED_CYCLES,
    }
    allocated_cycles = compute_fire_cycles + sum(overhead_allocation.values())
    budget_slack_cycles = TARGET_PL_BUSY_CYCLES - allocated_cycles

    return {
        "array": {
            "rows": config.rows,
            "cols": config.cols,
            "cout_tile": config.cout_tile,
            "outputs_per_column": OUTPUTS_PER_COLUMN,
        },
        "frequency_mhz": frequency_mhz,
        "axis_bytes": axis_bytes,
        "layers": layers,
        "totals": {
            "compute_fire_cycles": compute_fire_cycles,
            "compute_fire_ms": cycles_to_ms(compute_fire_cycles, frequency_mhz),
            "ifm_bytes": ifm_bytes,
            "ifm_beats": ifm_beats,
            "ofm_bytes": ofm_bytes,
            "ofm_beats": ofm_beats,
            "axis_bytes": ifm_bytes + ofm_bytes,
            "axis_beats": ifm_beats + ofm_beats,
            "ideal_axis_ms_at_one_beat_per_cycle": cycles_to_ms(
                ifm_beats + ofm_beats, frequency_mhz
            ),
            "materializer_store_bytes_per_cycle": (
                MATERIALIZER_STORE_BYTES_PER_CYCLE
            ),
            "materialized_entries": materialized_entries,
            "materializer_store_cycles": materializer_store_cycles,
            "materializer_entry_cycles": materializer_entry_cycles,
            "materializer_serial_cycles": materializer_serial_cycles,
            "materializer_serial_ms": cycles_to_ms(
                materializer_serial_cycles, frequency_mhz
            ),
        },
        "acceptance_budget": {
            "pl_busy_cycles": TARGET_PL_BUSY_CYCLES,
            **overhead_allocation,
            "software_pack_parse_us": TARGET_SOFTWARE_PACK_PARSE_US,
            "ifm_dma_starts": TARGET_DMA_STARTS,
            "ofm_dma_starts": TARGET_DMA_STARTS,
            "logical_ifm_bytes": ifm_bytes,
            "ifm_bytes_limit": TARGET_IFM_BYTES_LIMIT,
            "ofm_bytes": ofm_bytes,
            "ofm_beats": ofm_beats,
            "allocated_cycles": allocated_cycles,
            "slack_cycles": budget_slack_cycles,
            "feasible": budget_slack_cycles >= 0,
        },
    }


def _canonical_layer_name(name: str) -> Optional[str]:
    lowered = name.strip().lower()
    for layer in SINGLE_SCALE_LAYERS:
        if lowered in (layer.name.lower(), f"conv{layer.index}"):
            return layer.name
    return None


def _layer_busy_map(raw_layers: Any) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    if isinstance(raw_layers, Mapping):
        iterable: Iterable[Tuple[Any, Any]] = raw_layers.items()
        for raw_name, raw_value in iterable:
            name = _canonical_layer_name(str(raw_name))
            if name is None:
                continue
            if isinstance(raw_value, Mapping):
                result[name] = raw_value.get("busy_cycles")
            else:
                result[name] = raw_value
        return result

    if isinstance(raw_layers, Sequence) and not isinstance(raw_layers, (str, bytes)):
        for row in raw_layers:
            if not isinstance(row, Mapping) or "layer" not in row:
                continue
            name = _canonical_layer_name(str(row["layer"]))
            if name is not None:
                result[name] = row.get("busy_cycles")
    return result


def evaluate_acceptance(metrics: Mapping[str, Any], model: Mapping[str, Any]) -> Dict[str, Any]:
    """Evaluate final 100 MHz acceptance counters against the locked budget.

    Missing counters fail closed.  The input is intentionally a small, stable
    JSON contract rather than a UART-specific format; both RTL simulation and
    board runtime can emit it.
    """

    checks: List[Dict[str, Any]] = []

    def add_check(name: str, actual: Any, relation: str, expected: Any) -> None:
        passed = False
        if isinstance(actual, (int, float)) and not isinstance(actual, bool):
            if relation == "==":
                passed = actual == expected
            elif relation == "<=":
                passed = actual <= expected
            elif relation == ">=":
                passed = actual >= expected
            else:
                raise ValueError(f"unsupported relation: {relation}")
        checks.append(
            {
                "name": name,
                "actual": actual,
                "relation": relation,
                "expected": expected,
                "passed": passed,
            }
        )

    totals = model["totals"]
    budget = model["acceptance_budget"]

    add_check(
        "compute_fire_cycles",
        metrics.get("compute_fire_cycles"),
        "==",
        totals["compute_fire_cycles"],
    )
    add_check("pl_busy_cycles", metrics.get("pl_busy_cycles"), "<=", budget["pl_busy_cycles"])
    add_check(
        "feeder_unhidden_cycles",
        metrics.get("feeder_unhidden_cycles"),
        "<=",
        budget["feeder_cycles"],
    )
    add_check(
        "context_psum_gap_cycles",
        metrics.get("context_psum_gap_cycles"),
        "<=",
        budget["context_psum_gap_cycles"],
    )
    add_check(
        "drain_ofm_post_cycles",
        metrics.get("drain_ofm_post_cycles"),
        "<=",
        budget["drain_ofm_post_cycles"],
    )
    add_check(
        "bias_weight_wait_cycles",
        metrics.get("bias_weight_wait_cycles"),
        "<=",
        budget["bias_weight_wait_cycles"],
    )
    add_check(
        "unclassified_cycles",
        metrics.get("unclassified_cycles"),
        "<=",
        budget["unclassified_cycles"],
    )

    for metric_name in ZERO_ERROR_METRICS:
        add_check(metric_name, metrics.get(metric_name), "==", 0)

    pack_us = metrics.get("ifm_pack_us")
    parse_us = metrics.get("ofm_parse_us")
    pack_parse_us = (
        pack_us + parse_us
        if isinstance(pack_us, (int, float))
        and not isinstance(pack_us, bool)
        and isinstance(parse_us, (int, float))
        and not isinstance(parse_us, bool)
        else None
    )
    add_check(
        "ifm_pack_us+ofm_parse_us",
        pack_parse_us,
        "<=",
        budget["software_pack_parse_us"],
    )
    add_check("ifm_dma_starts", metrics.get("ifm_dma_starts"), "<=", budget["ifm_dma_starts"])
    add_check("ofm_dma_starts", metrics.get("ofm_dma_starts"), "<=", budget["ofm_dma_starts"])

    add_check("ifm_bytes_minimum", metrics.get("ifm_bytes"), ">=", budget["logical_ifm_bytes"])
    add_check("ifm_bytes_limit", metrics.get("ifm_bytes"), "<=", budget["ifm_bytes_limit"])
    add_check("ofm_bytes", metrics.get("ofm_bytes"), "==", budget["ofm_bytes"])
    add_check("ofm_beats", metrics.get("ofm_beats"), "==", budget["ofm_beats"])

    layer_busy = _layer_busy_map(metrics.get("layers"))
    for layer in model["layers"]:
        add_check(
            f"{layer['layer']}.busy_cycles",
            layer_busy.get(layer["layer"]),
            "<=",
            layer["pl_busy_budget_cycles"],
        )

    if len(layer_busy) == len(model["layers"]) and all(
        isinstance(value, (int, float)) and not isinstance(value, bool)
        for value in layer_busy.values()
    ):
        layer_busy_sum: Any = sum(layer_busy.values())
    else:
        layer_busy_sum = None
    add_check(
        "layer_busy_sum",
        layer_busy_sum,
        "==",
        metrics.get("pl_busy_cycles"),
    )

    failed = [check for check in checks if not check["passed"]]
    return {
        "passed": not failed,
        "checks": checks,
        "failed_checks": failed,
    }


def print_model(model: Mapping[str, Any]) -> None:
    array = model["array"]
    totals = model["totals"]
    budget = model["acceptance_budget"]
    frequency_mhz = model["frequency_mhz"]

    print(
        f"ARRAY ROWS={array['rows']} COLS={array['cols']} "
        f"COUT_TILE={array['cout_tile']} frequency={frequency_mhz:g} MHz"
    )
    print("layer                         Kpass Cblk compute_fire   fire_ms  busy_budget")
    for layer in model["layers"]:
        print(
            f"{layer['layer']:<29} "
            f"{layer['k_passes']:>5} {layer['cout_blocks']:>4} "
            f"{layer['compute_fire_cycles']:>12,} "
            f"{cycles_to_ms(layer['compute_fire_cycles'], frequency_mhz):>9.3f} "
            f"{layer['pl_busy_budget_cycles']:>12,}"
        )
    print(
        f"TOTAL compute_fire={totals['compute_fire_cycles']:,} cycles "
        f"({totals['compute_fire_ms']:.3f} ms)"
    )
    print(
        f"TRAFFIC IFM={totals['ifm_bytes']:,} B/{totals['ifm_beats']:,} beats "
        f"OFM={totals['ofm_bytes']:,} B/{totals['ofm_beats']:,} beats "
        f"ideal_axis={totals['ideal_axis_ms_at_one_beat_per_cycle']:.3f} ms"
    )
    print(
        "MATERIALIZER "
        f"entries={totals['materialized_entries']:,} "
        f"store={totals['materializer_store_cycles']:,} cycles "
        f"entry={totals['materializer_entry_cycles']:,} cycles "
        f"serial={totals['materializer_serial_cycles']:,} cycles "
        f"({totals['materializer_serial_ms']:.3f} ms)"
    )
    print(
        f"BUDGET allocated={budget['allocated_cycles']:,}/{budget['pl_busy_cycles']:,} cycles "
        f"slack={budget['slack_cycles']:,} feasible={'yes' if budget['feasible'] else 'no'}"
    )


def print_acceptance(result: Mapping[str, Any]) -> None:
    print(f"ACCEPTANCE {'PASS' if result['passed'] else 'FAIL'}")
    for check in result["failed_checks"]:
        print(
            f"  {check['name']}: actual={check['actual']!r} "
            f"required {check['relation']} {check['expected']!r}"
        )


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Model Conv0-Conv9 useful cycles, HWC traffic, and 100 ms acceptance budgets."
    )
    parser.add_argument("--rows", type=int, default=TARGET_ROWS)
    parser.add_argument("--cols", type=int, default=TARGET_COLS)
    parser.add_argument(
        "--cout-tile",
        type=int,
        help="output channels per COUT block (default: two per physical column)",
    )
    parser.add_argument("--freq-mhz", type=float, default=DEFAULT_FREQUENCY_MHZ)
    parser.add_argument("--axis-bytes", type=int, default=DEFAULT_AXIS_BYTES)
    parser.add_argument(
        "--metrics-json",
        type=Path,
        help="check a JSON counter snapshot; exits nonzero when any hard gate fails",
    )
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    config = ArrayConfig(rows=args.rows, cols=args.cols, cout_tile=args.cout_tile)
    model = build_model(config, frequency_mhz=args.freq_mhz, axis_bytes=args.axis_bytes)

    acceptance = None
    if args.metrics_json:
        metrics = json.loads(args.metrics_json.read_text(encoding="utf-8"))
        if not isinstance(metrics, Mapping):
            raise ValueError("metrics JSON root must be an object")
        acceptance = evaluate_acceptance(metrics, model)

    if args.json:
        payload: Dict[str, Any] = {"model": model}
        if acceptance is not None:
            payload["acceptance"] = acceptance
        print(json.dumps(payload, indent=2))
    else:
        print_model(model)
        if acceptance is not None:
            print_acceptance(acceptance)

    return 0 if acceptance is None or acceptance["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
