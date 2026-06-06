import argparse
import json
import os
from pathlib import Path

import numpy as np
import torch


DEFAULT_EXTERNAL_PROJECT = Path(os.environ.get("PYTHON_PRJ", r"D:\MPSoC\python_prj"))
DEFAULT_SPEC = Path(__file__).resolve().parent / "single_scale_yolov3tiny_layers.json"


def scalar(x):
    return x.item() if hasattr(x, "item") else x


def clamp_int8(x):
    return np.clip(x, -128, 127).astype(np.int8)


def requantize_psum(psum, mult, shift, zp):
    effective_shift = int(shift) + 15
    v = psum.astype(np.int64) * int(mult)
    v = v + (1 << (effective_shift - 1))
    v = np.right_shift(v, effective_shift) + int(zp)
    return clamp_int8(v)


def maxpool2d_u8_2x2_stride2(hwc_u8):
    h, w, c = hwc_u8.shape
    if (h % 2) != 0 or (w % 2) != 0:
        raise RuntimeError(f"2x2 stride-2 pool requires even H/W, got {hwc_u8.shape}")
    out = np.empty((h // 2, w // 2, c), dtype=np.uint8)
    for y in range(h // 2):
        for x in range(w // 2):
            out[y, x, :] = hwc_u8[y * 2 : y * 2 + 2, x * 2 : x * 2 + 2, :].max(axis=(0, 1))
    return out


def conv2d_i32(ifm_s8_hwc, weight_s8_oihw, bias_i32, kernel, stride, pad):
    h, w, cin = ifm_s8_hwc.shape
    cout, w_cin, kh, kw = weight_s8_oihw.shape
    if w_cin != cin or kh != kernel or kw != kernel:
        raise RuntimeError(f"Weight shape {weight_s8_oihw.shape} does not match IFM {ifm_s8_hwc.shape}")
    out_h = (h + 2 * pad - kernel) // stride + 1
    out_w = (w + 2 * pad - kernel) // stride + 1
    padded = np.pad(ifm_s8_hwc.astype(np.int32), ((pad, pad), (pad, pad), (0, 0)), mode="constant")
    psum = np.broadcast_to(bias_i32.reshape(1, cout), (out_h * out_w, cout)).astype(np.int64).copy()
    out_idx = 0
    for oy in range(out_h):
        fy = oy * stride
        for ox in range(out_w):
            fx = ox * stride
            for ky in range(kernel):
                for kx in range(kernel):
                    window = padded[fy + ky, fx + kx, :].astype(np.int32)
                    kernel_vec = weight_s8_oihw[:, :, ky, kx].T.astype(np.int32)
                    psum[out_idx, :] += window @ kernel_vec
            out_idx += 1
    return psum.reshape(out_h, out_w, cout).astype(np.int32)


def write_bin(path, array):
    path.parent.mkdir(parents=True, exist_ok=True)
    np.ascontiguousarray(array).tofile(path)


def read_cfg(infer_dir, prefix):
    cfg = np.fromfile(infer_dir / f"{prefix}CG.bin", dtype=np.uint32)
    if cfg.size != 100:
        raise RuntimeError(f"Unexpected config length: {cfg.size}")
    return {
        "ifm": cfg[0:10].astype(int).tolist(),
        "ofm": cfg[10:20].astype(int).tolist(),
        "mult": cfg[20:30].astype(int).tolist(),
        "shift": cfg[30:40].astype(int).tolist(),
        "izp": cfg[40:50].astype(int).tolist(),
        "ozp": cfg[50:60].astype(int).tolist(),
        "azp": cfg[60:70].astype(int).tolist(),
        "sel_in": cfg[70:80].astype(int).tolist(),
        "pool": cfg[80:90].astype(int).tolist(),
        "stride": cfg[90:100].astype(int).tolist(),
    }


def layer_output_ref_file(layer):
    if "reference_file" in layer:
        return layer["reference_file"]
    model_index = int(layer["model_index"])
    if layer["pool"] == "maxpool2x2s2":
        return f"layer{model_index + 1:02d}_pooling_MaxPool2d_u8_hwc.bin"
    return f"layer{model_index:02d}_Conv_u8_hwc.bin"


def export_layer(project, state, cfg, spec, layer, args, ifm_override_array=None):
    model_index = int(layer["model_index"])
    infer_index = int(layer["infer_index"])
    name = layer["name"]
    layer_dir = Path(args.out_dir).resolve() / f"{infer_index:02d}_{name}"
    source_dir = project / "rtl_golden" / "facemask_yolov3tiny_layers"
    infer_dir = project / "infer_bin"
    layer_dir.mkdir(parents=True, exist_ok=True)

    input_shape = tuple(layer["input_shape_hwc"])
    if ifm_override_array is not None:
        ifm_path = None
        ifm_u8 = np.ascontiguousarray(ifm_override_array, dtype=np.uint8)
        if tuple(ifm_u8.shape) != input_shape:
            raise RuntimeError(f"{name}: chained IFM shape {ifm_u8.shape}, expected {input_shape}")
    elif args.ifm_override:
        ifm_path = Path(args.ifm_override).resolve()
        ifm_u8 = np.fromfile(ifm_path, dtype=np.uint8).reshape(input_shape)
    else:
        ifm_path = source_dir / layer["input_file"]
        ifm_u8 = np.fromfile(ifm_path, dtype=np.uint8).reshape(input_shape)
    input_zp = int(cfg["izp"][infer_index])
    centered_i16 = ifm_u8.astype(np.int16) - input_zp
    ifm_s8 = clamp_int8(centered_i16)
    sat_low_count = int(np.count_nonzero(centered_i16 < -128))
    sat_high_count = int(np.count_nonzero(centered_i16 > 127))

    default_conv_key = f"1.model.{model_index}.conv"
    weight_key = layer.get("weight_key", f"{default_conv_key}.weight")
    scale_key = layer.get("scale_key", f"{default_conv_key}.scale")
    zero_point_key = layer.get("zero_point_key", f"{default_conv_key}.zero_point")
    weight = state[weight_key].int_repr().numpy().astype(np.int8)
    weight_scale = float(torch.q_scale(state[weight_key]))
    conv_scale = float(scalar(state[scale_key]))
    conv_zp = int(scalar(state[zero_point_key]))
    act_scale = None
    act_zp = None
    act_scale_key = f"1.model.{model_index}.act.scale"
    act_zp_key = f"1.model.{model_index}.act.zero_point"
    if act_scale_key in state:
        act_scale = float(scalar(state[act_scale_key]))
        act_zp = int(scalar(state[act_zp_key]))

    bias_i64 = np.fromfile(infer_dir / f"{args.prefix}B{infer_index}.bin", dtype=np.int64)
    if bias_i64.size != weight.shape[0]:
        raise RuntimeError(f"{name}: bias count {bias_i64.size}, expected {weight.shape[0]}")
    if np.any(bias_i64 > np.iinfo(np.int32).max) or np.any(bias_i64 < np.iinfo(np.int32).min):
        raise RuntimeError(f"{name}: bias does not fit int32")
    bias_i32 = bias_i64.astype(np.int32)
    fw = np.fromfile(infer_dir / f"{args.prefix}W{infer_index}.bin", dtype=np.int8)
    lut = np.fromfile(infer_dir / f"{args.prefix}R{infer_index}.bin", dtype=np.uint64).astype(np.uint8)
    if lut.size != 256:
        raise RuntimeError(f"{name}: activation LUT size {lut.size}, expected 256")

    psum = conv2d_i32(
        ifm_s8,
        weight,
        bias_i32,
        int(layer["kernel"]),
        int(layer["stride"]),
        int(layer["pad"]),
    )
    requant_s8 = requantize_psum(psum, cfg["mult"][infer_index], cfg["shift"][infer_index], cfg["ozp"][infer_index])
    activation_u8 = lut[requant_s8.view(np.uint8)]
    if tuple(activation_u8.shape) != tuple(layer["conv_shape_hwc"]):
        raise RuntimeError(f"{name}: conv output shape {activation_u8.shape}, expected {layer['conv_shape_hwc']}")

    if layer["pool"] == "maxpool2x2s2":
        final_u8 = maxpool2d_u8_2x2_stride2(activation_u8)
    elif layer["pool"] == "bypass":
        final_u8 = activation_u8
    else:
        raise RuntimeError(f"{name}: unsupported pool mode {layer['pool']}")
    if tuple(final_u8.shape) != tuple(layer["output_shape_hwc"]):
        raise RuntimeError(f"{name}: final output shape {final_u8.shape}, expected {layer['output_shape_hwc']}")

    if not args.metadata_only:
        write_bin(layer_dir / "ifm_u8_hwc.bin", ifm_u8)
        write_bin(layer_dir / "ifm_s8_hwc.bin", ifm_s8)
        write_bin(layer_dir / "weight_raw_oihw_s8.bin", weight)
        write_bin(layer_dir / f"weight_packed_{args.prefix}W{infer_index}_s8.bin", fw)
        write_bin(layer_dir / "bias_i32.bin", bias_i32)
        write_bin(layer_dir / "bias_i64_from_infer_bin.bin", bias_i64)
        write_bin(layer_dir / "psum_i32_hwc.bin", psum)
        write_bin(layer_dir / "requant_s8_hwc.bin", requant_s8)
        write_bin(layer_dir / "requant_u8_hwc.bin", requant_s8.view(np.uint8))
        write_bin(layer_dir / "activation_lut_u8.bin", lut)
        write_bin(layer_dir / "activation_u8_hwc.bin", activation_u8)
        write_bin(layer_dir / "golden_ofm_u8_hwc.bin", final_u8)

    ref_file = layer_output_ref_file(layer)
    pytorch_ref_path = source_dir / ref_file if ref_file else None
    pytorch_ref_mismatch = None
    if pytorch_ref_path is not None and pytorch_ref_path.exists():
        pytorch_ref = np.fromfile(pytorch_ref_path, dtype=np.uint8)
        if pytorch_ref.size == final_u8.size:
            pytorch_ref = pytorch_ref.reshape(final_u8.shape)
            pytorch_ref_mismatch = int(np.count_nonzero(pytorch_ref != final_u8))

    rows = int(spec["array"]["rows"])
    cout_tile = int(spec["array"]["cout_tile"])
    cin = int(input_shape[2])
    cout = int(final_u8.shape[2])
    k_total = cin * int(layer["kernel"]) * int(layer["kernel"])
    metadata = {
        "description": "RTL semantic golden metadata for one single-scale YOLOv3-tiny layer.",
        "name": name,
        "project": str(project),
        "source_layer_file": "previous RTL semantic layer output" if ifm_path is None else str(ifm_path),
        "model_index": model_index,
        "infer_index": infer_index,
        "array": spec["array"],
        "shape": {
            "ifm_hwc": list(ifm_u8.shape),
            "conv_ofm_hwc": list(activation_u8.shape),
            "final_ofm_hwc": list(final_u8.shape),
            "layout": "HWC uint8 bytes",
            "expected_bytes": int(final_u8.size),
            "k_total": int(k_total),
            "k_passes": int((k_total + rows - 1) // rows),
            "cout_total": cout,
            "cout_blocks": int((cout + cout_tile - 1) // cout_tile),
        },
        "conv": {
            "kernel": int(layer["kernel"]),
            "stride": int(layer["stride"]),
            "pad": int(layer["pad"]),
            "padding_value": "internal signed zero",
        },
        "pool": {
            "mode": layer["pool"],
            "position": "after activation",
        },
        "quant": {
            "weight_scale": weight_scale,
            "conv_scale": conv_scale,
            "conv_zero_point": conv_zp,
            "activation_scale": act_scale,
            "activation_zero_point": act_zp,
            "rtl_mult": int(cfg["mult"][infer_index]),
            "rtl_raw_shift": int(cfg["shift"][infer_index]),
            "rtl_effective_shift": int(cfg["shift"][infer_index] + 15),
            "rtl_izp": input_zp,
            "rtl_ozp": int(cfg["ozp"][infer_index]),
            "rtl_azp": int(cfg["azp"][infer_index]),
            "bias_mode": "int32",
        },
        "ifm_centering": {
            "input_zero_point": input_zp,
            "source_u8_min": int(ifm_u8.min()),
            "source_u8_max": int(ifm_u8.max()),
            "centered_min_before_sat": int(centered_i16.min()),
            "centered_max_before_sat": int(centered_i16.max()),
            "centered_s8_min": int(ifm_s8.min()),
            "centered_s8_max": int(ifm_s8.max()),
            "sat_low_count": sat_low_count,
            "sat_high_count": sat_high_count,
            "sat_count": sat_low_count + sat_high_count,
        },
        "stats": {
            "psum_min": int(psum.min()),
            "psum_max": int(psum.max()),
            "requant_min_signed": int(requant_s8.min()),
            "requant_max_signed": int(requant_s8.max()),
            "activation_min_u8": int(activation_u8.min()),
            "activation_max_u8": int(activation_u8.max()),
            "final_min_u8": int(final_u8.min()),
            "final_max_u8": int(final_u8.max()),
            "pytorch_reference_mismatch": pytorch_ref_mismatch,
        },
        "files": {
            "metadata": "manifest.json",
            "golden_ofm_u8_hwc": None if args.metadata_only else "golden_ofm_u8_hwc.bin",
        },
        "notes": [
            "IFM bytes are centered as saturate_s8(ifm_u8 - input_zero_point).",
            "Requant uses mult / 2^(raw_shift + 15).",
            "This layer metadata is generated outside the RTL repo when out-dir points to PYTHON_PRJ/rtl_golden.",
        ],
    }
    (layer_dir / "manifest.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    return metadata, final_u8


def main():
    parser = argparse.ArgumentParser(description="Export RTL semantic golden data for the single-scale facemask YOLOv3-tiny plan.")
    parser.add_argument("--project", default=str(DEFAULT_EXTERNAL_PROJECT))
    parser.add_argument("--spec", default=str(DEFAULT_SPEC))
    parser.add_argument("--prefix", default="F")
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--layers", default="all", help="Comma-separated infer indices or names, or 'all'.")
    parser.add_argument("--ifm-override", default=None, help="Override IFM input binary path. Intended for one selected layer.")
    parser.add_argument("--chain", action="store_true",
                        help="Feed each selected layer's RTL semantic output into the next selected layer.")
    parser.add_argument("--metadata-only", action="store_true", help="Write manifests only; skip binary output files.")
    args = parser.parse_args()

    project = Path(args.project).resolve()
    spec = json.loads(Path(args.spec).read_text(encoding="utf-8"))
    args.out_dir = args.out_dir or str(project / "rtl_golden" / "facemask_single_scale_rtl")

    selected = None
    if args.layers != "all":
        selected = {x.strip() for x in args.layers.split(",") if x.strip()}
    layers = [
        layer for layer in spec["layers"]
        if selected is None or str(layer["infer_index"]) in selected or layer["name"] in selected
    ]
    if not layers:
        raise RuntimeError("No layer matched --layers")
    if args.ifm_override and len(layers) != 1:
        raise RuntimeError("--ifm-override requires exactly one selected layer")
    if args.chain and args.ifm_override:
        raise RuntimeError("--chain and --ifm-override cannot be used together")
    if args.chain:
        infer_indices = [int(layer["infer_index"]) for layer in layers]
        if infer_indices != list(range(infer_indices[0], infer_indices[0] + len(infer_indices))):
            raise RuntimeError("--chain requires consecutive layers in infer-index order")

    state = torch.load(project / "models_files" / "yolov3tiny_facemask_quant.pth", map_location="cpu")
    cfg = read_cfg(project / "infer_bin", args.prefix)
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "single_scale_layer_spec.json").write_text(json.dumps(spec, indent=2), encoding="utf-8")

    layer_meta = []
    chained_ifm = None
    for layer in layers:
        meta, final_u8 = export_layer(project, state, cfg, spec, layer, args, chained_ifm)
        layer_meta.append(meta)
        chained_ifm = final_u8 if args.chain else None
    summary = {
        "description": "Single-scale RTL semantic golden export summary.",
        "project": str(project),
        "output_dir": str(out_dir),
        "metadata_only": bool(args.metadata_only),
        "array": spec["array"],
        "layers": [
            {
                "name": meta["name"],
                "infer_index": meta["infer_index"],
                "ifm_hwc": meta["shape"]["ifm_hwc"],
                "final_ofm_hwc": meta["shape"]["final_ofm_hwc"],
                "expected_bytes": meta["shape"]["expected_bytes"],
                "k_passes": meta["shape"]["k_passes"],
                "cout_blocks": meta["shape"]["cout_blocks"],
                "sat_count": meta["ifm_centering"]["sat_count"],
                "pytorch_reference_mismatch": meta["stats"]["pytorch_reference_mismatch"],
            }
            for meta in layer_meta
        ],
    }
    (out_dir / "manifest.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
