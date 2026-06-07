import argparse
import json
from pathlib import Path


PERF_PREFIX = "PERF "


def parse_perf_line(line):
    fields = {}
    for token in line[len(PERF_PREFIX):].split():
        key, value = token.split("=", 1)
        fields[key] = value

    layer = fields.pop("layer")
    metrics = {}
    for key, value in fields.items():
        if not key.endswith("_us"):
            raise ValueError(f"unexpected PERF field: {key}")
        metrics[key] = int(value)
    if "total_us" not in metrics:
        raise ValueError("PERF line is missing total_us")
    return {"layer": layer, **metrics}


def summarize_perf(log_text):
    layers = [
        parse_perf_line(line.strip())
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

    return {
        "layer_count": len(layers),
        "total_microseconds": total_us,
        "total_seconds": total_us / 1_000_000.0,
        "layers": layers,
        "categories": categories,
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
