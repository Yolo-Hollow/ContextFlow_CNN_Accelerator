import argparse
import json
from pathlib import Path

from summarize_uart_perf import summarize_perf


def by_layer(rows):
    return {row["layer"]: row for row in rows or []}


def cycles_to_ms(cycles, freq_mhz):
    return cycles / (freq_mhz * 1000.0)


def analyze_log(path, freq_mhz):
    summary = summarize_perf(path.read_text(errors="replace"))
    perf = by_layer(summary["layers"])
    hw = by_layer(summary["hardware"]["layers"] if summary["hardware"] else [])
    stage = by_layer(summary["stage"]["layers"] if summary["stage"] else [])
    sub = by_layer(summary["subperf"]["layers"] if summary["subperf"] else [])
    collect = by_layer(summary["collectperf"]["layers"] if summary["collectperf"] else [])
    drain = by_layer(summary["drainperf"]["layers"] if summary["drainperf"] else [])
    psumovl = by_layer(summary["psumovlperf"]["layers"] if summary["psumovlperf"] else [])
    raw = by_layer(summary["rawstat"]["layers"] if summary["rawstat"] else [])
    passperf = by_layer(summary["passperf"]["layers"] if summary["passperf"] else [])

    layers = []
    for layer in perf:
        h = hw.get(layer, {})
        s = stage.get(layer, {})
        u = sub.get(layer, {})
        c = collect.get(layer, {})
        d = drain.get(layer, {})
        p = psumovl.get(layer, {})
        r = raw.get(layer, {})
        a = passperf.get(layer, {})

        busy = h.get("busy_cycles", 0)
        compute_fire = h.get("compute_cycles", 0)
        bias = s.get("bias_cycles", 0)
        weight = s.get("weight_cycles", 0)
        feeder = s.get("feeder_cycles", 0)
        compute_stage = s.get("compute_stage_cycles", 0)
        drain_stage = s.get("drain_cycles", 0)
        ofm_post = s.get("ofm_post_cycles", 0)
        stage_total = bias + weight + feeder + compute_stage + drain_stage + ofm_post

        # Conservative structural model:
        # keep bias/weight/ofm-post as serialized boundaries, but assume feeder,
        # compute stage, and drain can be overlapped within a layer.
        overlap_stage_bound = bias + weight + max(feeder, compute_stage, drain_stage) + ofm_post

        # Aggressive model:
        # additionally assume compute-stage idle bubbles are removed, so compute
        # cost is true array fire cycles plus explicit weight-load/tail cycles.
        comp_floor = (
            compute_fire
            + u.get("comp_wload", 0)
            + u.get("comp_tail", 0)
        )
        overlap_fire_bound = bias + weight + max(feeder, comp_floor, drain_stage) + ofm_post

        layers.append({
            "layer": layer,
            "total_us": perf[layer]["total_us"],
            "busy_cycles": busy,
            "compute_fire_cycles": compute_fire,
            "compute_util_percent": compute_fire * 100.0 / busy if busy else 0.0,
            "stage_total_cycles": stage_total,
            "bias_cycles": bias,
            "weight_cycles": weight,
            "feeder_cycles": feeder,
            "compute_stage_cycles": compute_stage,
            "compute_idle_cycles": max(compute_stage - compute_fire, 0),
            "drain_cycles": drain_stage,
            "ofm_post_cycles": ofm_post,
            "overlap_stage_bound_cycles": overlap_stage_bound,
            "overlap_stage_saving_cycles": max(stage_total - overlap_stage_bound, 0),
            "overlap_fire_bound_cycles": overlap_fire_bound,
            "overlap_fire_saving_cycles": max(stage_total - overlap_fire_bound, 0),
            "comp_wload_cycles": u.get("comp_wload", 0),
            "comp_tail_cycles": u.get("comp_tail", 0),
            "comp_ifm_stall_cycles": u.get("comp_ifm_stall", 0),
            "feed_fill_cycles": u.get("feed_fill", 0),
            "feed_push_cycles": u.get("feed_push", 0),
            "raw_replay_active_cycles": r.get("replay_active", 0),
            "pass_compute_idle_cycles": a.get("compute_idle", max(compute_stage - compute_fire, 0)),
            "collect_column_empty_wait_cycles": c.get("column_empty_wait", 0),
            "drain_empty_wait_cycles": d.get("empty_wait", 0),
            "psum_underflow_cycles": p.get("underflow", 0),
        })

    totals = {}
    for key in (
        "busy_cycles",
        "compute_fire_cycles",
        "stage_total_cycles",
        "bias_cycles",
        "weight_cycles",
        "feeder_cycles",
        "compute_stage_cycles",
        "compute_idle_cycles",
        "drain_cycles",
        "ofm_post_cycles",
        "overlap_stage_bound_cycles",
        "overlap_stage_saving_cycles",
        "overlap_fire_bound_cycles",
        "overlap_fire_saving_cycles",
        "comp_wload_cycles",
        "comp_tail_cycles",
        "comp_ifm_stall_cycles",
        "feed_fill_cycles",
        "feed_push_cycles",
        "raw_replay_active_cycles",
        "pass_compute_idle_cycles",
        "collect_column_empty_wait_cycles",
        "drain_empty_wait_cycles",
        "psum_underflow_cycles",
    ):
        totals[key] = sum(layer[key] for layer in layers)

    totals["total_us"] = summary["total_microseconds"]
    totals["compute_util_percent"] = (
        totals["compute_fire_cycles"] * 100.0 / totals["busy_cycles"]
        if totals["busy_cycles"] else 0.0
    )
    return {"path": str(path), "totals": totals, "layers": layers}


def print_report(result, freq_mhz, top_n):
    t = result["totals"]
    print(f"LOG {result['path']}")
    print(f"total={t['total_us']/1000.0:.3f} ms busy={cycles_to_ms(t['busy_cycles'], freq_mhz):.3f} ms "
          f"compute_fire={cycles_to_ms(t['compute_fire_cycles'], freq_mhz):.3f} ms "
          f"util={t['compute_util_percent']:.2f}%")
    print(
        "stage totals ms: "
        f"bias={cycles_to_ms(t['bias_cycles'], freq_mhz):.3f} "
        f"weight={cycles_to_ms(t['weight_cycles'], freq_mhz):.3f} "
        f"feeder={cycles_to_ms(t['feeder_cycles'], freq_mhz):.3f} "
        f"compute_stage={cycles_to_ms(t['compute_stage_cycles'], freq_mhz):.3f} "
        f"drain={cycles_to_ms(t['drain_cycles'], freq_mhz):.3f} "
        f"ofm_post={cycles_to_ms(t['ofm_post_cycles'], freq_mhz):.3f}"
    )
    print(
        "bounds ms: "
        f"overlap_stage={cycles_to_ms(t['overlap_stage_bound_cycles'], freq_mhz):.3f} "
        f"(save {cycles_to_ms(t['overlap_stage_saving_cycles'], freq_mhz):.3f}) "
        f"overlap_fire={cycles_to_ms(t['overlap_fire_bound_cycles'], freq_mhz):.3f} "
        f"(save {cycles_to_ms(t['overlap_fire_saving_cycles'], freq_mhz):.3f})"
    )
    print(
        "diagnostic ms: "
        f"compute_idle={cycles_to_ms(t['compute_idle_cycles'], freq_mhz):.3f} "
        f"comp_ifm_stall={cycles_to_ms(t['comp_ifm_stall_cycles'], freq_mhz):.3f} "
        f"collect_empty={cycles_to_ms(t['collect_column_empty_wait_cycles'], freq_mhz):.3f} "
        f"drain_empty={cycles_to_ms(t['drain_empty_wait_cycles'], freq_mhz):.3f} "
        f"psum_underflow={cycles_to_ms(t['psum_underflow_cycles'], freq_mhz):.3f}"
    )

    ranked = sorted(
        result["layers"],
        key=lambda item: item["overlap_fire_saving_cycles"],
        reverse=True,
    )
    print("top layer opportunities:")
    for item in ranked[:top_n]:
        print(
            f"  {item['layer']:<26} busy={cycles_to_ms(item['busy_cycles'], freq_mhz):>8.3f} "
            f"fire={cycles_to_ms(item['compute_fire_cycles'], freq_mhz):>8.3f} "
            f"comp_stage={cycles_to_ms(item['compute_stage_cycles'], freq_mhz):>8.3f} "
            f"comp_idle={cycles_to_ms(item['pass_compute_idle_cycles'], freq_mhz):>8.3f} "
            f"feeder={cycles_to_ms(item['feeder_cycles'], freq_mhz):>8.3f} "
            f"feed_fill={cycles_to_ms(item['feed_fill_cycles'], freq_mhz):>8.3f} "
            f"save_fire={cycles_to_ms(item['overlap_fire_saving_cycles'], freq_mhz):>8.3f}"
        )


def main():
    parser = argparse.ArgumentParser(
        description="Estimate structural cycle lower bounds from KV260 UART PERF logs."
    )
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--freq-mhz", type=float, default=100.0)
    parser.add_argument("--top", type=int, default=8)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    results = [analyze_log(path, args.freq_mhz) for path in args.logs]
    for result in results:
        print_report(result, args.freq_mhz, args.top)
        print()

    if args.json:
        args.json.write_text(json.dumps(results, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
