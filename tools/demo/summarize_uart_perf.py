import argparse
import json
from pathlib import Path


PERF_PREFIX = "PERF "
HWPERF_PREFIX = "HWPERF "
DMASTAT_PREFIX = "DMASTAT "
VECTORSTAT_PREFIX = "VECTORSTAT "


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

    return {
        "layer_count": len(layers),
        "total_microseconds": total_us,
        "total_seconds": total_us / 1_000_000.0,
        "layers": layers,
        "categories": categories,
        "hardware": hardware,
        "dma": dma,
        "vector": vector,
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
    if summary["vector"]:
        vector = summary["vector"]
        print(
            "VECTORSTAT summary: "
            f"packets={vector['packets']} pixels={vector['pixels']} "
            f"beats={vector['beats']} stalls={vector['fifo_stall_cycles']}"
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
