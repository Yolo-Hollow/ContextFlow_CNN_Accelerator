import argparse
import json
import os
from pathlib import Path

import numpy as np
import torch


DEFAULT_EXTERNAL_PROJECT = Path(os.environ.get("PYTHON_PRJ", r"D:\MPSoC\python_prj"))


def scalar(x):
    if hasattr(x, "item"):
        return x.item()
    return x


def clamp_int8(x):
    return np.clip(x, -128, 127).astype(np.int8)


def requantize_psum(psum, mult, shift, zp):
    effective_shift = int(shift) + 15
    v = psum.astype(np.int64) * int(mult)
    v = v + (1 << (effective_shift - 1))
    v = np.right_shift(v, effective_shift) + int(zp)
    return clamp_int8(v)


def conv2d_3x3_same_i32(ifm_s8_hwc, weight_s8_oihw, bias_i32):
    h, w, cin = ifm_s8_hwc.shape
    cout, w_cin, kh, kw = weight_s8_oihw.shape
    if w_cin != cin or kh != 3 or kw != 3:
        raise RuntimeError(f"Unexpected weight shape {weight_s8_oihw.shape} for IFM {ifm_s8_hwc.shape}")

    padded = np.pad(ifm_s8_hwc.astype(np.int32), ((1, 1), (1, 1), (0, 0)), mode="constant")
    psum = np.broadcast_to(bias_i32.reshape(1, cout), (h * w, cout)).astype(np.int64).copy()
    for ky in range(3):
        for kx in range(3):
            window = padded[ky : ky + h, kx : kx + w, :].reshape(h * w, cin)
            kernel = weight_s8_oihw[:, :, ky, kx].T.astype(np.int32)
            psum += window @ kernel
    return psum.reshape(h, w, cout).astype(np.int32)


def write_bin(path, array):
    path.parent.mkdir(parents=True, exist_ok=True)
    np.ascontiguousarray(array).tofile(path)


def main():
    parser = argparse.ArgumentParser(
        description="Export Layer06 RTL-semantic golden data for facemask YOLOv3-tiny."
    )
    parser.add_argument("--project", default=str(DEFAULT_EXTERNAL_PROJECT))
    parser.add_argument("--prefix", default="F")
    parser.add_argument("--model-index", type=int, default=6)
    parser.add_argument("--infer-index", type=int, default=3)
    parser.add_argument("--in-dir", default=None)
    parser.add_argument("--ifm", default="layer05_pooling_MaxPool2d_u8_hwc.bin")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    project = Path(args.project).resolve()
    infer_dir = project / "infer_bin"
    in_dir = Path(args.in_dir).resolve() if args.in_dir else project / "rtl_golden" / "facemask_yolov3tiny_layers"
    out_dir = Path(args.out).resolve() if args.out else project / "rtl_golden" / "facemask_layer06_rtl"
    model_path = project / "models_files" / "yolov3tiny_facemask_quant.pth"

    state = torch.load(model_path, map_location="cpu")
    key = f"1.model.{args.model_index}.conv"
    weight = state[f"{key}.weight"].int_repr().numpy().astype(np.int8)
    conv_scale = float(scalar(state[f"{key}.scale"]))
    conv_zp = int(scalar(state[f"{key}.zero_point"]))
    act_scale = float(scalar(state[f"1.model.{args.model_index}.act.scale"]))
    act_zp = int(scalar(state[f"1.model.{args.model_index}.act.zero_point"]))
    weight_scale = float(torch.q_scale(state[f"{key}.weight"]))

    cfg = np.fromfile(infer_dir / f"{args.prefix}CG.bin", dtype=np.uint32)
    if cfg.size != 100:
        raise RuntimeError(f"Unexpected config length: {cfg.size}")
    cfg_fields = {
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

    cout, cin, kh, kw = weight.shape
    input_zp = cfg_fields["izp"][args.infer_index]
    ifm_u8 = np.fromfile(in_dir / args.ifm, dtype=np.uint8).reshape(52, 52, cin)
    centered_i16 = ifm_u8.astype(np.int16) - int(input_zp)
    sat_low_count = int(np.count_nonzero(centered_i16 < -128))
    sat_high_count = int(np.count_nonzero(centered_i16 > 127))
    ifm_s8 = clamp_int8(centered_i16)

    bias_i64 = np.fromfile(infer_dir / f"{args.prefix}B{args.infer_index}.bin", dtype=np.int64)
    if bias_i64.size != cout:
        raise RuntimeError(f"Unexpected bias count: {bias_i64.size}, expected {cout}")
    if np.any(bias_i64 > np.iinfo(np.int32).max) or np.any(bias_i64 < np.iinfo(np.int32).min):
        raise RuntimeError("Layer06 bias does not fit int32.")
    bias_i32 = bias_i64.astype(np.int32)

    fw = np.fromfile(infer_dir / f"{args.prefix}W{args.infer_index}.bin", dtype=np.int8)
    fr = np.fromfile(infer_dir / f"{args.prefix}R{args.infer_index}.bin", dtype=np.uint64).astype(np.uint8)
    if fr.size != 256:
        raise RuntimeError(f"Unexpected activation LUT size: {fr.size}")

    out_dir.mkdir(parents=True, exist_ok=True)
    psum_i32 = conv2d_3x3_same_i32(ifm_s8, weight, bias_i32)
    requant_s8 = requantize_psum(
        psum_i32,
        cfg_fields["mult"][args.infer_index],
        cfg_fields["shift"][args.infer_index],
        cfg_fields["ozp"][args.infer_index],
    )
    activation_u8 = fr[requant_s8.view(np.uint8)]
    pytorch_ref_path = in_dir / f"layer{args.model_index:02d}_Conv_u8_hwc.bin"
    pytorch_ref_mismatch = None
    if pytorch_ref_path.exists():
        pytorch_ref = np.fromfile(pytorch_ref_path, dtype=np.uint8)
        if pytorch_ref.size == activation_u8.size:
            pytorch_ref = pytorch_ref.reshape(activation_u8.shape)
            pytorch_ref_mismatch = int(np.count_nonzero(activation_u8 != pytorch_ref))

    write_bin(out_dir / "ifm_u8_hwc.bin", ifm_u8)
    write_bin(out_dir / "ifm_s8_hwc.bin", ifm_s8)
    write_bin(out_dir / "weight_raw_oihw_s8.bin", weight)
    write_bin(out_dir / f"weight_packed_{args.prefix}W{args.infer_index}_s8.bin", fw)
    write_bin(out_dir / "bias_i32.bin", bias_i32)
    write_bin(out_dir / "bias_i64_from_infer_bin.bin", bias_i64)
    write_bin(out_dir / "psum_i32_hwc.bin", psum_i32)
    write_bin(out_dir / "requant_s8_hwc.bin", requant_s8)
    write_bin(out_dir / "requant_u8_hwc.bin", requant_s8.view(np.uint8))
    write_bin(out_dir / "activation_lut_u8.bin", fr)
    write_bin(out_dir / "activation_u8_hwc.bin", activation_u8)
    write_bin(out_dir / "golden_ofm_u8_hwc.bin", activation_u8)

    manifest = {
        "description": "Layer06 real-image golden data for RTL block-strategy verification.",
        "project": str(project),
        "output_dir": str(out_dir),
        "model": str(model_path),
        "prefix": args.prefix,
        "model_index": args.model_index,
        "infer_index": args.infer_index,
        "input": str(in_dir / args.ifm),
        "layer": {
            "name": "Conv6 52x52x64 to 52x52x128",
            "kernel": 3,
            "stride": 1,
            "pad": 1,
            "ifm_shape_hwc": list(ifm_u8.shape),
            "weight_raw_shape_oihw": list(weight.shape),
            "ofm_shape_hwc": list(activation_u8.shape),
            "rows": 18,
            "cols": 16,
            "ifm_banks": 2,
            "k_total": int(cin * kh * kw),
            "k_passes": int((cin * kh * kw + 17) // 18),
            "cout_tile": 32,
            "cout_blocks": int((cout + 31) // 32),
        },
        "quant": {
            "weight_scale": weight_scale,
            "conv_scale": conv_scale,
            "conv_zero_point": conv_zp,
            "activation_scale": act_scale,
            "activation_zero_point": act_zp,
            "rtl_mult": cfg_fields["mult"][args.infer_index],
            "rtl_raw_shift": cfg_fields["shift"][args.infer_index],
            "rtl_effective_shift": cfg_fields["shift"][args.infer_index] + 15,
            "rtl_multiplier_fractional_bits": 15,
            "rtl_izp": cfg_fields["izp"][args.infer_index],
            "rtl_ozp": cfg_fields["ozp"][args.infer_index],
            "rtl_azp": cfg_fields["azp"][args.infer_index],
            "bias_mode": "int32",
        },
        "ifm_centering": {
            "input_zero_point": int(input_zp),
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
        "files": {
            "ifm_u8_hwc": "ifm_u8_hwc.bin",
            "ifm_s8_hwc": "ifm_s8_hwc.bin",
            "weight_raw_oihw_s8": "weight_raw_oihw_s8.bin",
            "bias_i32": "bias_i32.bin",
            "psum_i32_hwc": "psum_i32_hwc.bin",
            "requant_s8_hwc": "requant_s8_hwc.bin",
            "activation_lut_u8": "activation_lut_u8.bin",
            "golden_ofm_u8_hwc": "golden_ofm_u8_hwc.bin",
        },
        "notes": [
            "This golden follows the RTL uint8 input stream to centered signed int8 IFM semantics.",
            "The IFM is transformed as saturate_s8(ifm_u8 - rtl_izp) before convolution.",
            "Requant uses mult / 2^(raw_shift + 15) because mult stores 15 fractional bits.",
            "Bias uses RTL integer semantics: psum = conv_accumulator + int32_bias.",
            "PyTorch quantized conv may differ by a small number of bytes because it uses float-bias semantics.",
            "Padding in the convolution model is internal signed zero.",
        ],
    }
    if pytorch_ref_mismatch is not None:
        manifest["pytorch_reference"] = {
            "file": str(pytorch_ref_path),
            "mismatch_vs_rtl_semantic_golden": pytorch_ref_mismatch,
            "total_bytes": int(activation_u8.size),
        }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    requant_unique_values, requant_unique_counts = np.unique(requant_s8, return_counts=True)
    requant_top_order = np.argsort(requant_unique_counts)[::-1][:16]
    unique_values, unique_counts = np.unique(activation_u8, return_counts=True)
    top_order = np.argsort(unique_counts)[::-1][:16]
    summary = {
        "out_dir": str(out_dir),
        "ifm_shape_hwc": list(ifm_u8.shape),
        "ofm_shape_hwc": list(activation_u8.shape),
        "input_zero_point": int(input_zp),
        "ifm_u8_min": int(ifm_u8.min()),
        "ifm_u8_max": int(ifm_u8.max()),
        "centered_min_before_sat": int(centered_i16.min()),
        "centered_max_before_sat": int(centered_i16.max()),
        "centered_s8_min": int(ifm_s8.min()),
        "centered_s8_max": int(ifm_s8.max()),
        "sat_low_count": sat_low_count,
        "sat_high_count": sat_high_count,
        "sat_count": sat_low_count + sat_high_count,
        "psum_min": int(psum_i32.min()),
        "psum_max": int(psum_i32.max()),
        "rtl_mult": int(cfg_fields["mult"][args.infer_index]),
        "rtl_raw_shift": int(cfg_fields["shift"][args.infer_index]),
        "rtl_effective_shift": int(cfg_fields["shift"][args.infer_index] + 15),
        "bias_mode": "int32",
        "requant_min_signed": int(requant_s8.min()),
        "requant_max_signed": int(requant_s8.max()),
        "requant_unique_count": int(requant_unique_values.size),
        "requant_top_values": [
            {"value": int(requant_unique_values[i]), "count": int(requant_unique_counts[i])}
            for i in requant_top_order
        ],
        "activation_min_u8": int(activation_u8.min()),
        "activation_max_u8": int(activation_u8.max()),
        "activation_unique_count": int(unique_values.size),
        "pytorch_reference_mismatch": pytorch_ref_mismatch,
        "activation_top_values": [
            {"value": int(unique_values[i]), "count": int(unique_counts[i])}
            for i in top_order
        ],
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
