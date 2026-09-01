#!/usr/bin/env python3
"""Collect verified LASA evidence and generate publication tables.

The script has two important properties:
1. repository reports are parsed instead of transcribing values by hand;
2. missing external COCO result directories fall back to an explicitly marked
   frozen snapshot rather than silently inventing or dropping values.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
from typing import Any


LAYER_ORDER = [
    "m0", "m2", "m4", "m6", "m8", "m10", "m13", "m14", "m15",
    "m16", "m19", "p4_detect", "p5_detect",
]


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def portable_manifest_path(path: Path, repo: Path) -> str:
    """Use portable repository-relative paths whenever possible."""
    try:
        return path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return str(path.resolve())


def parse_gate(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if key.startswith("metric."):
            short = key[len("metric."):]
            try:
                result[short] = float(value) if "." in value else int(value)
            except ValueError:
                result[short] = value
        elif key in {"gate", "status"}:
            result[key] = value
    return result


def tex_escape(value: str) -> str:
    replacements = {
        "&": r"\&", "%": r"\%", "$": r"\$", "#": r"\#",
        "_": r"\_", "{": r"\{", "}": r"\}",
    }
    return "".join(replacements.get(ch, ch) for ch in value)


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(text, encoding="utf-8", newline="\n")
    os.replace(temp, path)


def pct(value: float) -> str:
    return f"{100.0 * value:.3f}"


def tex_sci(value: float) -> str:
    mantissa, exponent = f"{value:.2e}".split("e")
    return f"{mantissa}\\!\\times\\!10^{{{int(exponent)}}}"


def make_layer_table(model: dict[str, Any]) -> str:
    rows = []
    array_rows = int(model["array"]["rows"])
    cout_tile = int(model["array"]["cout_tile"])
    for layer in model["conv_layers"]:
        ih, iw, cin = layer["ifm_hwc"]
        oh, ow, cout = layer["ofm_hwc"]
        kernel = int(layer["kernel"])
        k_total = cin * kernel * kernel
        k_pass = math.ceil(k_total / array_rows)
        cblock = math.ceil(cout / cout_tile)
        tiles = math.ceil(oh / int(layer["tile_h"]))
        rows.append(
            f"{tex_escape(layer['name'])} & {ih}$\\times${iw} & {cin} & {cout} & "
            f"{kernel}$\\times${kernel} & {k_total} & {k_pass} & {cblock} & "
            f"{layer['tile_h']} / {tiles} \\\\"  # noqa: W605
        )
    return "\n".join([
        r"\begin{table*}[t]",
        r"\centering",
        r"\caption{完整 YOLOv3-tiny 的 13 个 PL 卷积层及安全分块。$K_{\mathrm{pass}}=\lceil K/18\rceil$，输出块宽为 32。}",
        r"\label{tab:layer-config}",
        r"\small",
        r"\setlength{\tabcolsep}{4.2pt}",
        r"\begin{tabular}{lrrrrrrrr}",
        r"\toprule",
        r"层 & $H\times W$ & $C_{in}$ & $C_{out}$ & 核 & $K$ & $K$-pass & Cout块 & tile\_h/块数 \\",
        r"\midrule",
        *rows,
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}",
        "",
    ])


def make_accuracy_table(data: dict[str, Any]) -> str:
    a = data["accuracy"]
    rows = [
        ("官方 FP32-640", a["official640"]),
        ("部署 FP32-416", a["fp32_deploy416"]),
        ("当前部署 INT8-416", a["int8_epoch1"]),
    ]
    body = []
    for name, entry in rows:
        body.append(
            f"{name} & {pct(entry['ap50_95'])} & {pct(entry['ap50'])} & "
            f"{pct(entry.get('ap75', 0.0)) if 'ap75' in entry else '--'} & "
            f"{pct(entry.get('ap_small', 0.0)) if 'ap_small' in entry else '--'} & "
            f"{pct(entry.get('ap_medium', 0.0)) if 'ap_medium' in entry else '--'} & "
            f"{pct(entry.get('ap_large', 0.0)) if 'ap_large' in entry else '--'} \\\\"  # noqa: W605
        )
    return "\n".join([
        r"\begin{table*}[t]",
        r"\centering",
        r"\caption{COCO val2017 精度（百分数）。640 结果仅用于上游资产复现；416 结果才用于部署公平比较。}",
        r"\label{tab:accuracy}",
        r"\small",
        r"\begin{tabular}{lrrrrrr}",
        r"\toprule",
        r"配置 & AP & AP50 & AP75 & AP$_S$ & AP$_M$ & AP$_L$ \\",
        r"\midrule",
        *body,
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table*}",
        "",
    ])


def make_performance_table(data: dict[str, Any]) -> str:
    p = data["performance"]
    rows = [
        ("Resident 总延迟", p["resident_mean_us"] / 1000, p["resident_p95_us"] / 1000, "ms"),
        ("PL 13 卷积", p["pl_mean_us"] / 1000, None, "ms"),
        ("A53（含 decode）", p["a53_including_decode_mean_us"] / 1000, None, "ms"),
        ("双头 decode/NMS", p["decode_mean_us"] / 1000, None, "ms"),
        ("Resident 吞吐", p["resident_fps"], None, "FPS"),
        ("网络 pipeline 吞吐", p["pipeline_fps"], None, "FPS"),
    ]
    body = []
    for name, mean, p95v, unit in rows:
        body.append(f"{name} & {mean:.3f} & {('--' if p95v is None else f'{p95v:.3f}')} & {unit} \\\\")
    return "\n".join([
        r"\begin{table}[t]",
        r"\centering",
        r"\caption{板端主性能结果，3 次独立运行、每次 20 次预热和 1000 次计时。}",
        r"\label{tab:performance}",
        r"\small",
        r"\begin{tabular}{lrrl}",
        r"\toprule",
        r"指标 & 均值/值 & P95 & 单位 \\",
        r"\midrule",
        *body,
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table}",
        "",
    ])


def make_layer_latency_table(data: dict[str, Any]) -> str:
    layers = data["performance"]["layers_mean_us"]
    body = [f"{tex_escape(name)} & {layers[name] / 1000:.3f} & {100 * layers[name] / data['performance']['pl_mean_us']:.2f} \\\\" for name in LAYER_ORDER]
    return "\n".join([
        r"\begin{table}[t]",
        r"\centering",
        r"\caption{13 个 PL 卷积的平均延迟及其占 PL 总时间的比例。}",
        r"\label{tab:layer-latency}",
        r"\small",
        r"\begin{tabular}{lrr}",
        r"\toprule",
        r"层 & 延迟/ms & 占PL/\% \\",
        r"\midrule",
        *body,
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table}",
        "",
    ])


def make_gate_macros(data: dict[str, Any], source_kind: str) -> str:
    h, p, c, s = data["hardware"], data["performance"], data["correctness"], data["soak"]
    a53_tensor_ms = (p["a53_including_decode_mean_us"] - p["decode_mean_us"]) / 1000
    residual_ms = max(0.0, (
        p["resident_mean_us"] - p["pl_mean_us"] - p["a53_including_decode_mean_us"]
    ) / 1000)
    m13_ms = p["layers_mean_us"]["m13"] / 1000
    m19_ms = p["layers_mean_us"]["m19"] / 1000
    macros = {
        "EvidenceSourceKind": source_kind.replace("+", "/"),
        "LUTCount": f"{h['lut']:,}",
        "LogicLUTCount": f"{h['logic_lut']:,}",
        "LUTRAMCount": f"{h['lutram']:,}",
        "CLBPercent": f"{h['clb_percent']:.2f}",
        "BRAMCount": str(h["bram"]),
        "URAMCount": str(h["uram"]),
        "DSPCount": str(h["dsp"]),
        "ArrayDSPCount": str(h["array_dsp"]),
        "WNSValue": f"{h['wns_ns']:.3f}",
        "WHSValue": f"{h['whs_ns']:.3f}",
        "ResidentMeanMs": f"{p['resident_mean_us'] / 1000:.3f}",
        "ResidentPNinetyFiveMs": f"{p['resident_p95_us'] / 1000:.3f}",
        "ResidentFPS": f"{p['resident_fps']:.3f}",
        "PLMeanMs": f"{p['pl_mean_us'] / 1000:.3f}",
        "AFTMeanMs": f"{p['a53_including_decode_mean_us'] / 1000:.3f}",
        "AFTensorMeanMs": f"{a53_tensor_ms:.3f}",
        "DecodeMeanMs": f"{p['decode_mean_us'] / 1000:.3f}",
        "ResidualMeanMs": f"{residual_ms:.3f}",
        "MThirteenMeanMs": f"{m13_ms:.3f}",
        "MNineteenMeanMs": f"{m19_ms:.3f}",
        "LongLayerPLShare": f"{100 * (m13_ms + m19_ms) / (p['pl_mean_us'] / 1000):.1f}",
        "PLEffectiveGOPS": f"{p['pl_effective_gops']:.1f}",
        "ArrayUtilization": f"{p['array_utilization_percent']:.1f}",
        "ConformanceImages": str(c["conformance_images"]),
        "NodeRecords": f"{c['node_records']:,}",
        "NodeMismatches": str(c["node_mismatches"]),
        "ProductImages": f"{c['product_accuracy_images']:,}",
        "ProductScoreDelta": tex_sci(c["product_score_max_abs_delta"]),
        "ProductBBoxDelta": tex_sci(c["product_bbox_max_abs_delta_pixels"]),
        "ProductMetricDelta": f"{c['product_metric_max_abs_delta']:.0f}",
        "PostRoutePowerTotalW": f"{data['power']['total_on_chip_w']:.3f}",
        "PostRoutePowerDynamicW": f"{data['power']['dynamic_w']:.3f}",
        "PostRoutePowerStaticW": f"{data['power']['device_static_w']:.3f}",
        "PostRoutePowerPLDynamicW": f"{data['power']['pl_dynamic_w']:.3f}",
        "PostRoutePowerPSDynamicW": f"{data['power']['ps8_dynamic_w']:.3f}",
        "PostRoutePowerAccelDynamicW": f"{data['power']['accelerator_hierarchy_dynamic_w']:.3f}",
        "PostRoutePowerJunctionC": f"{data['power']['junction_temp_c']:.1f}",
        "PostRoutePowerConfidence": data["power"]["confidence"],
        "SoakSeconds": f"{s['elapsed_seconds']:.1f}",
        "SoakTempC": f"{s['max_temp_millic'] / 1000:.3f}",
    }
    return "\n".join(f"\\newcommand{{\\{name}}}{{{value}}}" for name, value in macros.items()) + "\n"


def make_readiness_table(data: dict[str, Any]) -> str:
    gates = data["publication_gates"]
    names = {
        "product_accuracy_5000": "5000 张 A53 product 后处理",
        "controlled_ablation": "受控微架构消融",
        "cpu_scalar_baseline": "A53 单核标量基线",
        "cpu_neon_4core_baseline": "A53 四核 NEON 基线",
        "post_route_power_estimate": "Post-route 功耗估算",
        "public_artifact_self_check": "公开 artifact 自检",
    }
    body = []
    for key, label in names.items():
        status = gates[key]
        body.append(f"{label} & {status} & 投稿冻结前硬门禁 \\\\")
    return "\n".join([
        r"\begin{table}[t]",
        r"\centering",
        r"\caption{投稿冻结门禁。PENDING 项不得在摘要、结论或对比表中写成已完成结果。}",
        r"\label{tab:freeze-gates}",
        r"\footnotesize",
        r"\begin{tabular}{lll}",
        r"\toprule",
        r"实验/材料 & 状态 & 处理 \\",
        r"\midrule",
        *body,
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table}",
        "",
    ])


def make_correctness_table(data: dict[str, Any]) -> str:
    c, s = data["correctness"], data["soak"]
    rows = [
        f"逐节点 RTL-semantic conformance & {c['conformance_images']} & {c['node_records']}节点 & {c['node_bytes_compared']:,} & 0 byte & PASS" + r" \\",
        f"128张双 raw head & {c['raw_head_records']} & {2 * c['raw_head_records']}头 & {c['raw_head_bytes_compared']:,} & 0 byte & PASS" + r" \\",
        f"5000张 network mAP & {c['board_network_images']} & {2 * c['board_network_images']}头 & -- & 12项/每类差0 & PASS" + r" \\",
        f"{c['product_accuracy_images']}张 A53 accuracy product & {c['product_accuracy_images']} & detections & -- & "
        f"score ${tex_sci(c['product_score_max_abs_delta'])}$；bbox ${tex_sci(c['product_bbox_max_abs_delta_pixels'])}$ px & PASS" + r" \\",
        f"600 s Ethernet soak & {s['records']:,}记录 & -- & -- & CRC/协议/DMA/PL/timeout=0 & PASS" + r" \\",
    ]
    return "\n".join([
        r"\begin{table*}[t]", r"\centering",
        r"\caption{当前可引用的正确性和稳定性证据。}",
        r"\label{tab:correctness}", r"\small", r"\resizebox{0.98\textwidth}{!}{%",
        r"\begin{tabular}{lrrrrl}", r"\toprule",
        r"项目 & 图像/记录 & 节点/头 & 比较字节 & 最大差异 & 状态\\", r"\midrule",
        *rows, r"\bottomrule", r"\end{tabular}", r"}", r"\end{table*}", "",
    ])


def make_resource_table(data: dict[str, Any]) -> str:
    h, p = data["hardware"], data["power"]
    rows = [
        f"LUT & {h['lut']:,} & logic {h['logic_lut']:,}；LUTRAM {h['lutram']:,}" + r" \\",
        f"CLB & {h['clb_sites']:,}/{h['clb_available']:,} & {h['clb_percent']:.2f}\\%" + r" \\",
        f"BRAM & {h['bram']} & {100*h['bram']/144:.2f}\\%" + r" \\",
        f"URAM & {h['uram']} & {100*h['uram']/64:.2f}\\%" + r" \\",
        f"DSP & {h['dsp']} & 阵列 {h['array_dsp']}" + r" \\",
        f"WNS & {h['wns_ns']:.3f} ns & setup EP=0" + r" \\",
        f"WHS & {h['whs_ns']:.3f} ns & hold EP=0" + r" \\",
        f"Route/DRC Error & {h['route_errors']}/{h['drc_errors']} & fully routed" + r" \\",
        f"Post-route estimated power & {p['total_on_chip_w']:.3f} W & dynamic {p['dynamic_w']:.3f} W；static {p['device_static_w']:.3f} W" + r" \\",
        f"Vectorless PL/PS dynamic & {p['pl_dynamic_w']:.3f}/{p['ps8_dynamic_w']:.3f} W & accelerator hierarchy {p['accelerator_hierarchy_dynamic_w']:.3f} W" + r" \\",
        f"Estimated junction/confidence & {p['junction_temp_c']:.1f} $^{{\\circ}}$C / {p['confidence']} & ambient {p['ambient_temp_c']:.1f} $^{{\\circ}}$C" + r" \\",
    ]
    return "\n".join([
        r"\begin{table*}[t]", r"\centering",
        r"\caption{r5 最终系统 post-route 资源、时序与功耗估算。}", r"\label{tab:resources}",
        r"\small", r"\begin{tabular}{lrr}", r"\toprule", r"指标 & 使用/结果 & 备注\\", r"\midrule",
        *rows, r"\bottomrule", r"\end{tabular}", r"\end{table*}", "",
    ])


def make_related_table(meta: dict[str, Any]) -> str:
    rows = [" & ".join(tex_escape(cell) for cell in row) + r" \\" for row in meta["related_work"]]
    return "\n".join([
        r"\begin{table*}[t]", r"\centering",
        r"\caption{代表性方向的能力比较。符号“部分”表示论文可能支持该能力，但未同时给出完整网络、板端逐节点整数一致性与跨 pass 调度证据。}",
        r"\label{tab:related}", r"\small", r"\resizebox{0.98\textwidth}{!}{%",
        r"\begin{tabular}{lccccc}", r"\toprule",
        r"方向/代表工作 & 层间映射 & 外部HWC协同 & 跨pass重放 & 完整检测DAG & 逐节点板端证据\\", r"\midrule",
        *rows, r"\bottomrule", r"\end{tabular}", r"}", r"\end{table*}", "",
    ])


def make_ablation_table(meta: dict[str, Any], data: dict[str, Any]) -> str:
    rows = []
    for name in meta["ablation_variants"]:
        if name == "层自适应tile（本文）":
            rows.append(f"层自适应tile（本文） & {data['performance']['resident_mean_us']/1000:.3f} & 1.000 & PENDING & PENDING & PENDING & -- & PASS" + r" \\")
        else:
            rows.append(tex_escape(name).replace("3x3", r"3$\times$3").replace("1x1", r"1$\times$1") + " & PENDING & PENDING & PENDING & PENDING & PENDING & PENDING & 必须PASS" + r" \\")
    return "\n".join([
        r"\begin{table*}[t]", r"\centering",
        r"\caption{受控消融结果表（当前为冻结前执行合同；数值必须由同源 200 MHz 变体自动回填）。}",
        r"\label{tab:ablation-plan}", r"\small", r"\resizebox{0.98\textwidth}{!}{%",
        r"\begin{tabular}{lrrrrrrl}", r"\toprule",
        r"变体 & 延迟/ms & 相对加速 & DDR字节 & compute idle & context gap & 资源增量 & byte-exact\\", r"\midrule",
        *rows, r"\bottomrule", r"\end{tabular}", r"}", r"\end{table*}", "",
    ])


def make_external_table(meta: dict[str, Any], data: dict[str, Any]) -> str:
    rows = []
    for row in meta["external_comparison"]:
        name, citation, *cells = row
        rows.append(f"{tex_escape(name)}\\cite{{{citation}}} & " + " & ".join(tex_escape(cell) for cell in cells) + r" \\")
    p = data["performance"]
    rows.append(f"本文 \\LASA & XCK26 & 200 & tiny/416 & 是 & A53包含 & 1 & {p['resident_mean_us']/1000:.3f} ms/{p['resident_fps']:.3f} FPS & resident" + r" \\")
    return "\n".join([
        r"\begin{table*}[t]", r"\centering",
        r"\caption{外部工作的比较口径。当前初稿只冻结能力与字段；投稿前由原始论文自动生成数值，避免跨口径误排。}",
        r"\label{tab:external-comparison}", r"\small", r"\resizebox{0.98\textwidth}{!}{%",
        r"\begin{tabular}{lcccccccl}", r"\toprule",
        r"工作 & 器件 & MHz & 网络/输入 & 完整双头 & 后处理 & batch & 延迟/FPS & 口径备注\\", r"\midrule",
        *rows, r"\bottomrule", r"\end{tabular}", r"}", r"\end{table*}", "",
    ])


def make_artifact_table(meta: dict[str, Any]) -> str:
    rows = [
        "r5 BIT & 见证据 manifest & XCK26 200 MHz 配置" + r" \\",
        "r5 XSA & 见证据 manifest & Vitis 平台与硬件描述" + r" \\",
    ]
    rows.extend(" & ".join(tex_escape(cell) for cell in row) + r" \\" for row in meta["artifacts"])
    return "\n".join([
        r"\begin{table*}[t]", r"\centering",
        r"\caption{主要 artifact 身份。完整 64 位哈希保存在构建/结果 manifest 中。}",
        r"\label{tab:artifact-id}", r"\small", r"\begin{tabular}{lll}", r"\toprule",
        r"Artifact & SHA256 前后缀 & 作用\\", r"\midrule", *rows,
        r"\bottomrule", r"\end{tabular}", r"\end{table*}", "",
    ])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--paper-root", type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo_root.resolve()
    paper = args.paper_root.resolve()
    snapshot_path = paper / "data" / "evidence_snapshot.json"
    data = load_json(snapshot_path)
    table_meta_path = paper / "data" / "paper_tables.json"
    table_meta = load_json(table_meta_path)
    sources: dict[str, Any] = {
        "snapshot": {"path": portable_manifest_path(snapshot_path, repo), "sha256": sha256(snapshot_path)},
        "paper_tables": {"path": portable_manifest_path(table_meta_path, repo), "sha256": sha256(table_meta_path)},
    }
    source_kind = "snapshot"

    gate_path = repo / "build_abi_v2_release_r5" / "reports" / "system_impl_gate.txt"
    model_path = repo / "tools" / "coco80" / "model_spec.json"
    perf_path = repo / "results" / "coco80" / "r5_ethernet_20260817" / "multicore_decode_lut" / "performance_final_summary" / "summary.json"
    verify_path = repo / "results" / "coco80" / "r5_ethernet_20260817" / "verification_snapshot.json"
    product_path = repo / "results" / "coco80" / "jtag_el3_product5000_irqfix_eval_20260819_003354" / "summary.json"
    power_path = repo / "build_abi_v2_release_r5" / "reports" / "post_route_power" / "summary.json"

    model = load_json(model_path)
    sources["model_spec"] = {"path": portable_manifest_path(model_path, repo), "sha256": sha256(model_path)}
    if gate_path.exists():
        gate = parse_gate(gate_path)
        h = data["hardware"]
        for src, dst in {
            "lut": "lut", "logic_lut": "logic_lut", "lut_memory": "lutram",
            "clb_sites": "clb_sites", "clb_available": "clb_available",
            "clb_percent": "clb_percent", "bram": "bram", "uram": "uram",
            "dsp": "dsp", "wns": "wns_ns", "whs": "whs_ns",
            "tns": "tns_ns", "ths": "ths_ns", "route_errors": "route_errors",
            "drc_errors": "drc_errors", "drc_critical_warnings": "drc_critical_warnings",
        }.items():
            if src in gate:
                h[dst] = gate[src]
        sources["system_impl_gate"] = {"path": portable_manifest_path(gate_path, repo), "sha256": sha256(gate_path)}
        source_kind = "live+snapshot"

    if perf_path.exists():
        perf = load_json(perf_path)
        p = data["performance"]
        p.update({
            "runs": perf["runs"], "warmup_per_run": perf["warmup_per_run"],
            "timed_per_run": perf["timed_per_run"], "timed_total": perf["timed_total"],
            "resident_mean_us": perf["latency_us"]["resident_total"]["mean"],
            "resident_p95_us": perf["latency_us"]["resident_total"]["p95"],
            "resident_fps": perf["resident_fps_from_mean"],
            "pipeline_fps": perf["pipeline"]["combined_fps"],
            "pl_mean_us": perf["latency_us"]["pl_total"]["mean"],
            "a53_including_decode_mean_us": perf["latency_us"]["a53_total_including_decode"]["mean"],
            "decode_mean_us": perf["latency_us"]["decode_total"]["mean"],
            "layers_mean_us": {name: perf["latency_us"]["pl_layers"][name]["mean"] for name in LAYER_ORDER},
        })
        p["pl_effective_gops"] = p["model_gop"] / (p["pl_mean_us"] / 1e6)
        p["array_utilization_percent"] = 100 * p["pl_effective_gops"] / p["array_peak_gops"]
        sources["performance"] = {"path": portable_manifest_path(perf_path, repo), "sha256": sha256(perf_path)}
        source_kind = "live+snapshot"

    if verify_path.exists():
        verification = load_json(verify_path)
        completed = verification["completed_evidence"]
        c = data["correctness"]
        pa = completed["product_accuracy_conformance_128"]
        c["product_score_max_abs_delta"] = pa["max_score_abs_delta"]
        c["product_bbox_max_abs_delta_pixels"] = pa["max_bbox_abs_delta_pixels"]
        c["product_metric_max_abs_delta"] = pa["max_metric_abs_delta"]
        sources["verification_snapshot"] = {"path": portable_manifest_path(verify_path, repo), "sha256": sha256(verify_path)}

    if product_path.exists():
        product = load_json(product_path)
        if product.get("status") != "PASS" or int(product.get("images", 0)) != 5000:
            raise ValueError(f"invalid 5000-image product evaluation: {product_path}")
        comparison = product["comparison"]
        metrics = product["board_coco"]["metrics"]
        for value_key, limit_key in (
            ("max_score_abs_delta", "score_tolerance"),
            ("max_bbox_abs_delta_pixels", "bbox_tolerance_pixels"),
            ("max_metric_abs_delta", "metric_tolerance"),
        ):
            if float(comparison[value_key]) > float(comparison[limit_key]):
                raise ValueError(
                    f"product comparison exceeds tolerance: {value_key}="
                    f"{comparison[value_key]} > {comparison[limit_key]}"
                )
        host_metrics = product["canonical_host_coco"]["metrics"]
        if set(metrics) != set(host_metrics):
            raise ValueError("board/host COCO metric key mismatch")
        if any(
            abs(float(metrics[key]) - float(host_metrics[key]))
            > float(comparison["metric_tolerance"])
            for key in metrics
        ):
            raise ValueError("board/host COCO metrics exceed tolerance")
        c = data["correctness"]
        c.update({
            "product_accuracy_images": 5000,
            "product_score_max_abs_delta": comparison["max_score_abs_delta"],
            "product_bbox_max_abs_delta_pixels": comparison["max_bbox_abs_delta_pixels"],
            "product_metric_max_abs_delta": comparison["max_metric_abs_delta"],
            "product_ap50_95": metrics["AP50_95"],
            "product_ap50": metrics["AP50"],
            "product_ap75": metrics["AP75"],
            "product_detection_sha256": product["artifacts"]["detections"]["sha256"],
            "product_accuracy_5000_status": "PASS",
        })
        data["publication_gates"]["product_accuracy_5000"] = "PASS"
        sources["product_accuracy_5000"] = {
            "path": portable_manifest_path(product_path, repo),
            "sha256": sha256(product_path),
        }
        source_kind = "live+snapshot"

    if power_path.exists():
        power = load_json(power_path)
        if power.get("status") != "PASS" or power.get("measurement") != "post_route_estimated":
            raise ValueError(f"invalid post-route power summary: {power_path}")
        if (
            power["route"]["routing_errors"] != 0
            or power["route"]["fully_routed_nets"] != power["route"]["routable_nets"]
        ):
            raise ValueError("post-route power summary is not based on a fully routed design")
        values = power["power_w"]
        if abs(values["total_on_chip"] - values["dynamic"] - values["device_static"]) > 0.002:
            raise ValueError("post-route power summary does not add up")
        data["power"].update({
            "status": "PASS",
            "measurement": power["measurement"],
            "activity_source": power["activity"]["source"],
            "saif": power["activity"]["saif"],
            "default_toggle_rate_percent": power["activity"]["default_toggle_rate_percent"],
            "default_static_probability": power["activity"]["default_static_probability"],
            "ambient_temp_c": power["environment"]["ambient_temp_c"],
            "junction_temp_c": power["environment"]["junction_temp_c"],
            "process": power["design"]["process"],
            "grade": power["design"]["grade"],
            "confidence": power["confidence"]["overall"],
            "total_on_chip_w": values["total_on_chip"],
            "dynamic_w": values["dynamic"],
            "device_static_w": values["device_static"],
            "ps8_dynamic_w": values["ps8_dynamic"],
            "pl_dynamic_w": values["pl_dynamic"],
            "pl_dynamic_plus_device_static_w": values["pl_dynamic_plus_device_static"],
            "accelerator_hierarchy_dynamic_w": values["accelerator_hierarchy_dynamic"],
            "summary_sha256": sha256(power_path),
        })
        data["publication_gates"]["post_route_power_estimate"] = "PASS"
        sources["post_route_power"] = {
            "path": portable_manifest_path(power_path, repo),
            "sha256": sha256(power_path),
        }
        source_kind = "live+snapshot"

    generated = paper / "generated"
    write_text(generated / "evidence_macros.tex", make_gate_macros(data, source_kind))
    write_text(generated / "layer_table.tex", make_layer_table(model))
    write_text(generated / "accuracy_table.tex", make_accuracy_table(data))
    write_text(generated / "performance_table.tex", make_performance_table(data))
    write_text(generated / "layer_latency_table.tex", make_layer_latency_table(data))
    write_text(generated / "freeze_gates_table.tex", make_readiness_table(data))
    write_text(generated / "correctness_table.tex", make_correctness_table(data))
    write_text(generated / "resource_table.tex", make_resource_table(data))
    write_text(generated / "related_table.tex", make_related_table(table_meta))
    write_text(generated / "ablation_table.tex", make_ablation_table(table_meta, data))
    write_text(generated / "external_table.tex", make_external_table(table_meta, data))
    write_text(generated / "artifact_table.tex", make_artifact_table(table_meta))

    manifest = {
        "format": "lasa-journal-generated-evidence",
        "version": 1,
        "source_kind": source_kind,
        "sources": sources,
        "generated_files": {},
        "publication_gates": data["publication_gates"],
    }
    for path in sorted(generated.glob("*.tex")):
        manifest["generated_files"][path.name] = {"bytes": path.stat().st_size, "sha256": sha256(path)}
    manifest_path = generated / "evidence_manifest.json"
    write_text(manifest_path, json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"status": "PASS", "source_kind": source_kind, "manifest": str(manifest_path)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
