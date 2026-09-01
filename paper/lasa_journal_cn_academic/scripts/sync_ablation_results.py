#!/usr/bin/env python3
"""Freeze verified A3 ablation summaries into compact paper tables."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Any


SUMMARY_FORMAT = "kv260-lasa-ablation-summary"
RUNTIME_CONFIGS = ("0x2B", "0x3B", "0x3F", "0xBF")
SECONDARY_CASES = (
    ("m14", "release", "sparse3x3"),
    ("m16", "release", "sparse3x3"),
    ("p4_detect", "release", "sparse3x3"),
    ("p5_detect", "release", "sparse3x3"),
    ("m13", "tile_h8", "tile_h4"),
    ("m19", "tile_h6", "tile_h3"),
)


class FreezeError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_summary(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise FreezeError(f"{label} summary is missing or symbolic: {path}")
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if (
        not isinstance(value, dict)
        or value.get("format") != SUMMARY_FORMAT
        or value.get("version") != 1
        or value.get("status") != "PASS"
        or value.get("failed_hardware") != []
    ):
        raise FreezeError(f"{label} summary identity/status is invalid")
    return value


def check_case(case: dict[str, Any], timed_images: int) -> None:
    if (
        case.get("variant") != "a3"
        or case.get("hardware_profile") != "abi_v2_release_200"
        or case.get("timed_images") != timed_images
        or case.get("hardware_metrics", {}).get("status") != "PASS"
    ):
        raise FreezeError("ablation case identity, sample count, or gate is invalid")


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8", newline="\n")
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-summary", required=True, type=Path)
    parser.add_argument("--secondary-summary", required=True, type=Path)
    parser.add_argument("--output-json", required=True, type=Path)
    parser.add_argument("--output-tex", required=True, type=Path)
    args = parser.parse_args()

    runtime = load_summary(args.runtime_summary, "runtime")
    secondary = load_summary(args.secondary_summary, "secondary")
    runtime_cases = runtime.get("cases", [])
    secondary_cases = secondary.get("cases", [])
    if len(runtime_cases) != 4 or len(runtime.get("paired_comparisons", [])) != 3:
        raise FreezeError("runtime summary must contain four ordered paired cases")
    if len(secondary_cases) != 12 or len(secondary.get("paired_comparisons", [])) != 6:
        raise FreezeError("secondary summary must contain six ordered pairs")

    runtime_rows: list[dict[str, Any]] = []
    previous_mean = None
    for expected_cfg, case in zip(RUNTIME_CONFIGS, runtime_cases):
        check_case(case, 3000)
        if case.get("stream_config") != expected_cfg or len(case.get("layers_selected", [])) != 13:
            raise FreezeError("runtime configuration order or layer coverage is invalid")
        mean_ms = float(case["resident_us"]["mean"]) / 1000.0
        runtime_rows.append({
            "stream_config": expected_cfg,
            "resident_mean_ms": mean_ms,
            "resident_p95_ms": float(case["resident_us"]["p95"]) / 1000.0,
            "pl_mean_ms": float(case["pl_us"]["mean"]) / 1000.0,
            "fps": float(case["resident_fps_from_mean"]),
            "speedup_over_previous": 1.0 if previous_mean is None else previous_mean / mean_ms,
        })
        previous_mean = mean_ms

    secondary_rows: list[dict[str, Any]] = []
    for pair_index, (layer, preferred_label, baseline_label) in enumerate(SECONDARY_CASES):
        preferred = secondary_cases[2 * pair_index]
        baseline = secondary_cases[2 * pair_index + 1]
        check_case(preferred, 300)
        check_case(baseline, 300)
        if (
            preferred.get("layers_selected") != [layer]
            or baseline.get("layers_selected") != [layer]
            or preferred.get("case_label") != preferred_label
            or baseline.get("case_label") != baseline_label
        ):
            raise FreezeError(f"secondary pair identity mismatch for {layer}")
        p_metrics = preferred["layers"][layer]
        b_metrics = baseline["layers"][layer]
        p_mean = float(p_metrics["latency_us"]["mean"])
        b_mean = float(b_metrics["latency_us"]["mean"])
        secondary_rows.append({
            "layer": layer,
            "preferred": preferred_label,
            "baseline": baseline_label,
            "preferred_mean_us": p_mean,
            "baseline_mean_us": b_mean,
            "preferred_p95_us": float(p_metrics["latency_us"]["p95"]),
            "baseline_p95_us": float(b_metrics["latency_us"]["p95"]),
            "speedup": b_mean / p_mean,
            "preferred_contexts": int(p_metrics["expected_contexts"]["mean"]),
            "baseline_contexts": int(b_metrics["expected_contexts"]["mean"]),
            "preferred_weight_bytes": int(p_metrics["weight_dma_bytes"]["mean"]),
            "baseline_weight_bytes": int(b_metrics["weight_dma_bytes"]["mean"]),
        })

    full_speedup = runtime_rows[0]["resident_mean_ms"] / runtime_rows[-1]["resident_mean_ms"]
    snapshot = {
        "format": "lasa-academic-a3-ablation-snapshot",
        "version": 1,
        "status": "PASS",
        "source": {
            "runtime_summary_sha256": sha256(args.runtime_summary),
            "secondary_summary_sha256": sha256(args.secondary_summary),
        },
        "runtime": runtime_rows,
        "runtime_full_speedup": full_speedup,
        "runtime_latency_reduction_percent": (1.0 - 1.0 / full_speedup) * 100.0,
        "secondary": secondary_rows,
    }
    atomic_text(
        args.output_json,
        json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    )

    mechanisms = ("基础流水", "+部分和重叠", "+提前反馈", "+计算期预取")
    tex = [
        "% Generated by scripts/sync_ablation_results.py; do not edit.",
        f"\\newcommand{{\\AblRuntimeFullSpeedup}}{{{full_speedup:.3f}}}",
        f"\\newcommand{{\\AblRuntimeReductionPct}}{{{snapshot['runtime_latency_reduction_percent']:.2f}}}",
    ]
    macro_names = ("MFourteen", "MSixteen", "PFour", "PFive", "MThirteen", "MNineteen")
    for macro, row in zip(macro_names, secondary_rows):
        tex.append(f"\\newcommand{{\\Abl{macro}Speedup}}{{{row['speedup']:.2f}}}")
    tex += [
        "",
        "\\begin{table*}[t]",
        "\\centering",
        "\\caption{同一A3网表下的运行时流水机制消融。每档包含3个独立会话、3000张正式计时图像。}",
        "\\label{tab:a3-runtime-ablation}",
        "\\small",
        "\\setlength{\\tabcolsep}{6pt}",
        "\\begin{tabular}{llrrrr}",
        "\\toprule",
        "配置 & 相对基础增加的机制 & Resident均值/ms & P95/ms & PL均值/ms & 相对前档加速 \\\\",
        "\\midrule",
    ]
    for mechanism, row in zip(mechanisms, runtime_rows):
        tex.append(
            f"{row['stream_config']} & {mechanism} & "
            f"{row['resident_mean_ms']:.3f} & {row['resident_p95_ms']:.3f} & "
            f"{row['pl_mean_ms']:.3f} & {row['speedup_over_previous']:.3f}$\\times$ \\\\"
        )
    tex += [
        "\\bottomrule",
        "\\end{tabular}",
        "\\end{table*}",
        "",
        "\\begin{table*}[t]",
        "\\centering",
        "\\caption{A3原生1$\\times$1路径与层自适应tile的次级消融。每组包含3个独立会话、300条正式计时记录。}",
        "\\label{tab:a3-secondary-ablation}",
        "\\small",
        "\\setlength{\\tabcolsep}{4.5pt}",
        "\\resizebox{\\textwidth}{!}{%",
        "\\begin{tabular}{lllrrrrr}",
        "\\toprule",
        "层 & 优选配置 & 对照配置 & 优选均值/$\\mu$s & 对照均值/$\\mu$s & 加速比 & 上下文数(优选/对照) & 权重字节(优选/对照) \\\\",
        "\\midrule",
    ]
    labels = {
        "release": "原生1$\\times$1",
        "sparse3x3": "等价稀疏3$\\times$3",
        "tile_h8": "$h=8$",
        "tile_h4": "$h=4$",
        "tile_h6": "$h=6$",
        "tile_h3": "$h=3$",
    }
    for row in secondary_rows:
        tex.append(
            f"{row['layer'].replace('_', r'\_')} & {labels[row['preferred']]} & "
            f"{labels[row['baseline']]} & {row['preferred_mean_us']:.1f} & "
            f"{row['baseline_mean_us']:.1f} & {row['speedup']:.2f}$\\times$ & "
            f"{row['preferred_contexts']}/{row['baseline_contexts']} & "
            f"{row['preferred_weight_bytes']}/{row['baseline_weight_bytes']} \\\\"
        )
    tex += [
        "\\bottomrule",
        "\\end{tabular}}",
        "\\end{table*}",
        "",
    ]
    atomic_text(args.output_tex, "\n".join(tex))
    print(json.dumps({
        "status": "PASS",
        "runtime_cases": len(runtime_rows),
        "secondary_cases": len(secondary_rows),
        "output_json": str(args.output_json),
        "output_tex": str(args.output_tex),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
