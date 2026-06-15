import argparse
import json
from pathlib import Path


PERF_PREFIX = "PERF "
HWPERF_PREFIX = "HWPERF "
DMASTAT_PREFIX = "DMASTAT "
VECTORSTAT_PREFIX = "VECTORSTAT "
STAGEPERF_PREFIX = "STAGEPERF "
SUBPERF_PREFIX = "SUBPERF "
TAILSTAT_PREFIX = "TAILSTAT "
RAWSTAT_PREFIX = "RAWSTAT "
DRAINPERF_PREFIX = "DRAINPERF "
PREFETCHPERF_PREFIX = "PREFETCHPERF "
PSUMOVLPERF_PREFIX = "PSUMOVLPERF "
COLLECTPERF_PREFIX = "COLLECTPERF "


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

    tail_layers = [
        parse_metric_line(line.strip(), TAILSTAT_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(TAILSTAT_PREFIX)
    ]
    tailstat = None
    if tail_layers:
        tailstat = {
            "layers": tail_layers,
            "tail_config_cycles": max(
                layer["tail_config"] for layer in tail_layers
            ),
            "raw_compute_start_level": max(
                layer.get("raw_start_level", 0) for layer in tail_layers
            ),
            "tail_elapsed_cycles": sum(
                layer["tail_elapsed"] for layer in tail_layers
            ),
            "drain_empty_wait_cycles": sum(
                layer["drain_empty_wait"] for layer in tail_layers
            ),
            "drain_empty_sticky": max(
                layer["drain_empty_sticky"] for layer in tail_layers
            ),
        }

    raw_layers = [
        parse_metric_line(line.strip(), RAWSTAT_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(RAWSTAT_PREFIX)
    ]
    rawstat = None
    if raw_layers:
        rawstat = {
            "layers": raw_layers,
            "load_active_cycles": sum(layer["load_active"] for layer in raw_layers),
            "load_unpack_cycles": sum(layer["load_unpack"] for layer in raw_layers),
            "replay_active_cycles": sum(layer["replay_active"] for layer in raw_layers),
            "replay_wait_ready_cycles": sum(
                layer["replay_wait_ready"] for layer in raw_layers
            ),
            "compute_wait_ifm_cycles": sum(
                layer.get("compute_wait_ifm", 0) for layer in raw_layers
            ),
        }

    drainperf_layers = [
        parse_metric_line(line.strip(), DRAINPERF_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(DRAINPERF_PREFIX)
    ]
    drainperf = None
    if drainperf_layers:
        drainperf = {
            "layers": drainperf_layers,
            "read_fire_cycles": sum(layer["read_fire"] for layer in drainperf_layers),
            "packet_fire_cycles": sum(layer["packet_fire"] for layer in drainperf_layers),
            "ready_stall_cycles": sum(layer["ready_stall"] for layer in drainperf_layers),
            "internal_full_cycles": sum(layer["internal_full"] for layer in drainperf_layers),
            "empty_wait_cycles": sum(layer["empty_wait"] for layer in drainperf_layers),
            "version": max(layer.get("version", 0) for layer in drainperf_layers),
        }
        if stage:
            explained = (
                drainperf["packet_fire_cycles"]
                + drainperf["ready_stall_cycles"]
                + drainperf["internal_full_cycles"]
                + drainperf["empty_wait_cycles"]
            )
            drainperf["drain_residual_cycles"] = stage["drain_cycles"] - explained

    prefetch_layers = [
        parse_metric_line(line.strip(), PREFETCHPERF_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(PREFETCHPERF_PREFIX)
    ]
    prefetchperf = None
    if prefetch_layers:
        hits = sum(layer["hit"] for layer in prefetch_layers)
        misses = sum(layer["miss"] for layer in prefetch_layers)
        prefetchperf = {
            "layers": prefetch_layers,
            "start_cycles": sum(layer["start"] for layer in prefetch_layers),
            "weight_done_cycles": sum(layer["weight_done"] for layer in prefetch_layers),
            "feed_done_cycles": sum(layer["feed_done"] for layer in prefetch_layers),
            "hit_cycles": hits,
            "miss_cycles": misses,
            "stall_cycles": sum(layer["stall"] for layer in prefetch_layers),
            "hit_percent": hits * 100.0 / (hits + misses) if (hits + misses) else 0.0,
            "version": max(layer.get("version", 0) for layer in prefetch_layers),
        }

    psumovl_layers = [
        parse_metric_line(line.strip(), PSUMOVLPERF_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(PSUMOVLPERF_PREFIX)
    ]
    psumovlperf = None
    if psumovl_layers:
        starts = sum(layer["start"] for layer in psumovl_layers)
        hits = sum(layer["hit"] for layer in psumovl_layers)
        psumovlperf = {
            "layers": psumovl_layers,
            "start_cycles": starts,
            "hit_cycles": hits,
            "wait_psum_cycles": sum(layer["wait_psum"] for layer in psumovl_layers),
            "underflow_cycles": sum(layer["underflow"] for layer in psumovl_layers),
            "hit_percent": hits * 100.0 / starts if starts else 0.0,
            "version": max(layer.get("version", 0) for layer in psumovl_layers),
        }

    collect_layers = [
        parse_metric_line(line.strip(), COLLECTPERF_PREFIX)
        for line in log_text.splitlines()
        if line.strip().startswith(COLLECTPERF_PREFIX)
    ]
    collectperf = None
    if collect_layers:
        collectperf = {
            "layers": collect_layers,
            "packet_fire_cycles": sum(layer["packet_fire"] for layer in collect_layers),
            "partial_write_cycles": sum(layer["partial_write"] for layer in collect_layers),
            "final_write_cycles": sum(layer["final_write"] for layer in collect_layers),
            "context_push_cycles": sum(layer["context_push"] for layer in collect_layers),
            "context_pop_cycles": sum(layer["context_pop"] for layer in collect_layers),
            "context_full_stall_cycles": sum(
                layer["context_full_stall"] for layer in collect_layers
            ),
            "column_empty_wait_cycles": sum(
                layer["column_empty_wait"] for layer in collect_layers
            ),
            "version": max(layer.get("version", 0) for layer in collect_layers),
        }

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
        "tailstat": tailstat,
        "rawstat": rawstat,
        "drainperf": drainperf,
        "prefetchperf": prefetchperf,
        "psumovlperf": psumovlperf,
        "collectperf": collectperf,
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
    if summary["tailstat"]:
        tailstat = summary["tailstat"]
        print(
            "TAILSTAT summary: "
            f"tail_config={tailstat['tail_config_cycles']} "
            f"raw_start_level={tailstat['raw_compute_start_level']} "
            f"tail_elapsed={tailstat['tail_elapsed_cycles']} "
            f"drain_empty_wait={tailstat['drain_empty_wait_cycles']} "
            f"drain_empty_sticky={tailstat['drain_empty_sticky']}"
        )
    if summary["rawstat"]:
        rawstat = summary["rawstat"]
        print(
            "RAWSTAT summary: "
            f"load_active={rawstat['load_active_cycles']} "
            f"load_unpack={rawstat['load_unpack_cycles']} "
            f"replay_active={rawstat['replay_active_cycles']} "
            f"replay_wait_ready={rawstat['replay_wait_ready_cycles']} "
            f"compute_wait_ifm={rawstat['compute_wait_ifm_cycles']}"
        )
    if summary["drainperf"]:
        drainperf = summary["drainperf"]
        residual = ""
        if "drain_residual_cycles" in drainperf:
            residual = f" residual={drainperf['drain_residual_cycles']}"
        print(
            "DRAINPERF summary: "
            f"version={drainperf['version']} "
            f"read_fire={drainperf['read_fire_cycles']} "
            f"packet_fire={drainperf['packet_fire_cycles']} "
            f"ready_stall={drainperf['ready_stall_cycles']} "
            f"internal_full={drainperf['internal_full_cycles']} "
            f"empty_wait={drainperf['empty_wait_cycles']}{residual}"
        )
    if summary["prefetchperf"]:
        prefetchperf = summary["prefetchperf"]
        print(
            "PREFETCHPERF summary: "
            f"version={prefetchperf['version']} "
            f"start={prefetchperf['start_cycles']} "
            f"weight_done={prefetchperf['weight_done_cycles']} "
            f"feed_done={prefetchperf['feed_done_cycles']} "
            f"hit={prefetchperf['hit_cycles']} "
            f"miss={prefetchperf['miss_cycles']} "
            f"stall={prefetchperf['stall_cycles']} "
            f"hit_percent={prefetchperf['hit_percent']:.2f}%"
        )
    if summary["psumovlperf"]:
        psumovlperf = summary["psumovlperf"]
        print(
            "PSUMOVLPERF summary: "
            f"version={psumovlperf['version']} "
            f"start={psumovlperf['start_cycles']} "
            f"hit={psumovlperf['hit_cycles']} "
            f"wait_psum={psumovlperf['wait_psum_cycles']} "
            f"underflow={psumovlperf['underflow_cycles']} "
            f"hit_percent={psumovlperf['hit_percent']:.2f}%"
        )
    if summary["collectperf"]:
        collectperf = summary["collectperf"]
        print(
            "COLLECTPERF summary: "
            f"version={collectperf['version']} "
            f"packet_fire={collectperf['packet_fire_cycles']} "
            f"partial_write={collectperf['partial_write_cycles']} "
            f"final_write={collectperf['final_write_cycles']} "
            f"context_push={collectperf['context_push_cycles']} "
            f"context_pop={collectperf['context_pop_cycles']} "
            f"context_full_stall={collectperf['context_full_stall_cycles']} "
            f"column_empty_wait={collectperf['column_empty_wait_cycles']}"
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
