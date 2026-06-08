import argparse
import json
from pathlib import Path


PERF_PREFIX = "PERF "
HWPERF_PREFIX = "HWPERF "
DMASTAT_PREFIX = "DMASTAT "
VECTORSTAT_PREFIX = "VECTORSTAT "
STAGEPERF_PREFIX = "STAGEPERF "
SUBPERF_PREFIX = "SUBPERF "


def parse_metric_line(line, prefix):
    fields = {}
    for token in line[len(prefix):].split():
        key, value = token.split("=", 1)
        fields[key] = value

    layer = fields.pop("layer")
    metrics = {}
    for key, value in fields.items():
        metrics[key] = int(value)
    return {"layer": layer, **metrics}


def summarize_perf(log_text):
    layers = [
        parse_metric_line(line.strip(), PERF_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(PERF_PREFIX)
    ]
    if not layers:
        raise ValueError("UART log contains no PERF lines")

    metric_names = tuple(key for key in layers[0] if key not in ("layer", "total_us"))
    category_us = {
        name: sum(layer.get(name, 0) for layer in layers)
        for name in metric_names
    }
    total_us = sum(layer["total_us"] for layer in layers)
    categories = [
        {
            "name": name,
            "microseconds": value,
            "seconds": value / 1_000_000.0,
            "percent": value * 100.0 / total_us,
        }
        for name, value in category_us.items()
    ]
    categories.sort(key=lambda item: item["microseconds"], reverse=True)

    hardware_layers = [
        parse_metric_line(line.strip(), HWPERF_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(HWPERF_PREFIX)
    ]
    hardware = None
    if hardware_layers:
        busy_cycles = sum(layer["busy_cycles"] for layer in hardware_layers)
        wait_cycles = sum(layer["wait_cycles"] for layer in hardware_layers)
        nonwait_cycles = sum(layer["nonwait_cycles"] for layer in hardware_layers)
        compute_cycles = sum(layer["compute_cycles"] for layer in hardware_layers)
        hardware = {
            "layers": hardware_layers,
            "busy_cycles": busy_cycles,
            "wait_cycles": wait_cycles,
            "nonwait_cycles": nonwait_cycles,
            "compute_cycles": compute_cycles,
            "compute_percent": (
                compute_cycles * 100.0 / busy_cycles if busy_cycles else 0.0
            ),
            "wait_percent": (
                wait_cycles * 100.0 / busy_cycles if busy_cycles else 0.0
            ),
            "bias_wait_cycles": sum(
                layer["bias_wait_cycles"] for layer in hardware_layers
            ),
            "weight_wait_cycles": sum(
                layer["weight_wait_cycles"] for layer in hardware_layers
            ),
            "ifm_wait_cycles": sum(
                layer["ifm_wait_cycles"] for layer in hardware_layers
            ),
            "ofm_wait_cycles": sum(
                layer["ofm_wait_cycles"] for layer in hardware_layers
            ),
        }

    dma_layers = [
        parse_metric_line(line.strip(), DMASTAT_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(DMASTAT_PREFIX)
    ]
    dma = None
    if dma_layers:
        dma = {
            "layers": dma_layers,
            "bias_starts": sum(layer["bias_starts"] for layer in dma_layers),
            "weight_starts": sum(layer["weight_starts"] for layer in dma_layers),
            "ifm_starts": sum(layer["ifm_starts"] for layer in dma_layers),
            "ofm_starts": sum(layer["ofm_starts"] for layer in dma_layers),
        }

    stage_layers = [
        parse_metric_line(line.strip(), STAGEPERF_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(STAGEPERF_PREFIX)
    ]
    stage = None
    if stage_layers:
        totals = {
            "bias_cycles": sum(layer["bias_cycles"] for layer in stage_layers),
            "weight_cycles": sum(layer["weight_cycles"] for layer in stage_layers),
            "feeder_cycles": sum(layer["feeder_cycles"] for layer in stage_layers),
            "compute_stage_cycles": sum(
                layer["compute_stage_cycles"] for layer in stage_layers
            ),
            "drain_cycles": sum(layer["drain_cycles"] for layer in stage_layers),
            "ofm_post_cycles": sum(layer["ofm_post_cycles"] for layer in stage_layers),
        }
        total_cycles = sum(totals.values())
        stage = {
            "layers": stage_layers,
            **totals,
            "total_cycles": total_cycles,
        }
        if hardware:
            stage["coverage_percent"] = (
                total_cycles * 100.0 / hardware["busy_cycles"]
                if hardware["busy_cycles"]
                else 0.0
            )

    vector_layers = [
        parse_metric_line(line.strip(), VECTORSTAT_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(VECTORSTAT_PREFIX)
    ]
    vector = None
    if vector_layers:
        vector = {
            "layers": vector_layers,
            "packets": sum(layer["packets"] for layer in vector_layers),
            "pixels": sum(layer["pixels"] for layer in vector_layers),
            "beats": sum(layer["beats"] for layer in vector_layers),
            "fifo_stall_cycles": sum(
                layer["fifo_stall_cycles"] for layer in vector_layers
            ),
        }

    subperf_layers = [
        parse_metric_line(line.strip(), SUBPERF_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(SUBPERF_PREFIX)
    ]
    subperf = None
    if subperf_layers:
        totals = {
            "feed_fill_cycles": sum(layer["feed_fill"] for layer in subperf_layers),
            "feed_push_cycles": sum(layer["feed_push"] for layer in subperf_layers),
            "feed_fifo_stall_cycles": sum(
                layer["feed_fifo_stall"] for layer in subperf_layers
            ),
            "feed_win_not_ready_cycles": sum(
                layer["feed_win_not_ready"] for layer in subperf_layers
            ),
            "comp_wload_cycles": sum(layer["comp_wload"] for layer in subperf_layers),
            "comp_active_cycles": sum(layer["comp_active"] for layer in subperf_layers),
            "comp_fire_cycles": sum(layer["comp_fire"] for layer in subperf_layers),
            "comp_ifm_stall_cycles": sum(
                layer["comp_ifm_stall"] for layer in subperf_layers
            ),
            "comp_tail_cycles": sum(layer["comp_tail"] for layer in subperf_layers),
        }
        subperf = {
            "layers": subperf_layers,
            **totals,
            "version": max(layer.get("version", 0) for layer in subperf_layers),
        }
        if stage:
            feed_explained = (
                totals["feed_fill_cycles"]
                + totals["feed_push_cycles"]
                + totals["feed_fifo_stall_cycles"]
                + totals["feed_win_not_ready_cycles"]
            )
            comp_explained = (
                totals["comp_wload_cycles"]
                + totals["comp_active_cycles"]
                + totals["comp_tail_cycles"]
            )
            subperf["feed_residual_cycles"] = (
                stage["feeder_cycles"] - feed_explained
            )
            subperf["comp_residual_cycles"] = (
                stage["compute_stage_cycles"] - comp_explained
            )

    return {
        "layer_count": len(layers),
        "total_microseconds": total_us,
        "total_seconds": total_us / 1_000_000.0,
        "layers": layers,
        "categories": categories,
        "hardware": hardware,
        "dma": dma,
        "stage": stage,
        "vector": vector,
        "subperf": subperf,
    }


def print_summary(summary):
    print(
        f"PERF summary: layers={summary['layer_count']} "
        f"total={summary['total_seconds']:.6f} s"
    )
    for category in summary["categories"]:
        print(
            f"  {category['name']:<16} "
            f"{category['seconds']:>10.6f} s "
            f"{category['percent']:>6.2f}%"
        )
    if summary["hardware"]:
        hardware = summary["hardware"]
        print(
            "HWPERF summary: "
            f"busy={hardware['busy_cycles']} cycles "
            f"compute={hardware['compute_percent']:.2f}% "
            f"wait={hardware['wait_percent']:.2f}%"
        )
    if summary["dma"]:
        dma = summary["dma"]
        print(
            "DMASTAT summary: "
            f"bias={dma['bias_starts']} weight={dma['weight_starts']} "
            f"ifm={dma['ifm_starts']} ofm={dma['ofm_starts']}"
        )
    if summary["stage"]:
        stage = summary["stage"]
        coverage = stage.get("coverage_percent")
        coverage_text = (
            f" coverage={coverage:.2f}%" if coverage is not None else ""
        )
        print(
            "STAGEPERF summary: "
            f"total={stage['total_cycles']} cycles{coverage_text} "
            f"bias={stage['bias_cycles']} weight={stage['weight_cycles']} "
            f"feeder={stage['feeder_cycles']} "
            f"compute_stage={stage['compute_stage_cycles']} "
            f"drain={stage['drain_cycles']} ofm_post={stage['ofm_post_cycles']}"
        )
    if summary["vector"]:
        vector = summary["vector"]
        print(
            "VECTORSTAT summary: "
            f"packets={vector['packets']} pixels={vector['pixels']} "
            f"beats={vector['beats']} stalls={vector['fifo_stall_cycles']}"
        )
    if summary["subperf"]:
        subperf = summary["subperf"]
        residual = ""
        if "feed_residual_cycles" in subperf:
            residual = (
                f" feed_residual={subperf['feed_residual_cycles']} "
                f"comp_residual={subperf['comp_residual_cycles']}"
            )
        print(
            "SUBPERF summary: "
            f"version={subperf['version']} "
            f"feed_fill={subperf['feed_fill_cycles']} "
            f"feed_push={subperf['feed_push_cycles']} "
            f"feed_fifo_stall={subperf['feed_fifo_stall_cycles']} "
            f"feed_win_not_ready={subperf['feed_win_not_ready_cycles']} "
            f"comp_wload={subperf['comp_wload_cycles']} "
            f"comp_active={subperf['comp_active_cycles']} "
            f"comp_fire={subperf['comp_fire_cycles']} "
            f"comp_ifm_stall={subperf['comp_ifm_stall_cycles']} "
            f"comp_tail={subperf['comp_tail_cycles']}{residual}"
        )


def main():
    parser = argparse.ArgumentParser(description="Summarize KV260 UART PERF lines.")
    parser.add_argument("uart_log", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    summary = summarize_perf(
        args.uart_log.read_text(encoding="utf-8", errors="replace")
    )
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print_summary(summary)


if __name__ == "__main__":
    main()
