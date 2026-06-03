import argparse
import json
import os
from pathlib import Path

import numpy as np
import torch
from PIL import Image


DEFAULT_EXTERNAL_PROJECT = Path(os.environ.get("PYTHON_PRJ", r"D:\MPSoC\python_prj"))


def scalar(x):
    if hasattr(x, "item"):
        return x.item()
    return x


def letterbox_rgb(image_path, size=416, fill=114):
    img = Image.open(image_path).convert("RGB")
    src_w, src_h = img.size
    scale = min(size / src_w, size / src_h)
    new_w = int(round(src_w * scale))
    new_h = int(round(src_h * scale))
    resized = img.resize((new_w, new_h), Image.BILINEAR)
    canvas = Image.new("RGB", (size, size), (fill, fill, fill))
    pad_x = (size - new_w) // 2
    pad_y = (size - new_h) // 2
    canvas.paste(resized, (pad_x, pad_y))
    meta = {
        "source_width": src_w,
        "source_height": src_h,
        "letterbox_size": size,
        "scale": scale,
        "resized_width": new_w,
        "resized_height": new_h,
        "pad_x": pad_x,
        "pad_y": pad_y,
        "fill": fill,
    }
    return canvas, meta


def quantize_input_u8(rgb_u8, scale, zero_point):
    x = rgb_u8.astype(np.float64) / 255.0
    q = np.rint(x / scale + zero_point)
    return np.clip(q, 0, 255).astype(np.uint8)


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
    cout = weight_s8_oihw.shape[0]
    padded = np.pad(ifm_s8_hwc.astype(np.int32), ((1, 1), (1, 1), (0, 0)), mode="constant")
    psum = np.broadcast_to(bias_i32.reshape(1, 1, cout), (h, w, cout)).astype(np.int64).copy()
    for ky in range(3):
        for kx in range(3):
            window = padded[ky : ky + h, kx : kx + w, :]
            for ci in range(cin):
                psum += window[:, :, ci : ci + 1] * weight_s8_oihw[:, ci, ky, kx].reshape(1, 1, cout)
    return psum.astype(np.int32)


def maxpool2d_u8_2x2_stride2(hwc_u8):
    h, w, c = hwc_u8.shape
    out_h = h // 2
    out_w = w // 2
    pooled = np.empty((out_h, out_w, c), dtype=np.uint8)
    for y in range(out_h):
        for x in range(out_w):
            window = hwc_u8[y * 2 : y * 2 + 2, x * 2 : x * 2 + 2, :]
            pooled[y, x, :] = window.max(axis=(0, 1))
    return pooled


def write_bin(path, array):
    path.parent.mkdir(parents=True, exist_ok=True)
    np.ascontiguousarray(array).tofile(path)


def main():
    parser = argparse.ArgumentParser(description="Export Conv0 RTL golden data for the facemask quantized YOLOv3-tiny model.")
    parser.add_argument("--project", default=str(DEFAULT_EXTERNAL_PROJECT))
    parser.add_argument("--image", default=None)
    parser.add_argument("--prefix", default="F")
    parser.add_argument("--size", type=int, default=416)
    parser.add_argument("--out", default=None)
    parser.add_argument("--pool-stride2", action="store_true", help="Also export activation-after-pool 2x2 stride2 golden.")
    args = parser.parse_args()

    project = Path(args.project).resolve()
    image_path = Path(args.image).resolve() if args.image else project / "facemask" / "images" / "maksssksksss0.png"
    out_dir = Path(args.out).resolve() if args.out else project / "rtl_golden" / "facemask_conv0"
    infer_dir = project / "infer_bin"
    model_path = project / "models_files" / "yolov3tiny_facemask_quant.pth"

    state = torch.load(model_path, map_location="cpu")
    input_scale = float(scalar(state["0.scale"][0]))
    input_zp = int(scalar(state["0.zero_point"][0]))

    conv0_w = state["1.model.0.conv.weight"].int_repr().numpy().astype(np.int8)
    conv0_bias_float = state["1.model.0.conv.bias"].detach().numpy()
    conv0_weight_scale = float(torch.q_scale(state["1.model.0.conv.weight"]))
    conv0_conv_scale = float(scalar(state["1.model.0.conv.scale"]))
    conv0_conv_zp = int(scalar(state["1.model.0.conv.zero_point"]))
    conv0_act_scale = float(scalar(state["1.model.0.act.scale"]))
    conv0_act_zp = int(scalar(state["1.model.0.act.zero_point"]))

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

    bias_i64 = np.fromfile(infer_dir / f"{args.prefix}B0.bin", dtype=np.int64)
    if bias_i64.size != conv0_w.shape[0]:
        raise RuntimeError(f"Unexpected bias count: {bias_i64.size}, expected {conv0_w.shape[0]}")
    if np.any(bias_i64 > np.iinfo(np.int32).max) or np.any(bias_i64 < np.iinfo(np.int32).min):
        raise RuntimeError("Conv0 bias does not fit int32.")
    bias_i32 = bias_i64.astype(np.int32)

    fw0 = np.fromfile(infer_dir / f"{args.prefix}W0.bin", dtype=np.int8)
    fr0 = np.fromfile(infer_dir / f"{args.prefix}R0.bin", dtype=np.uint64).astype(np.uint8)
    if fr0.size != 256:
        raise RuntimeError(f"Unexpected LeakyReLU table size: {fr0.size}")

    image, letterbox_meta = letterbox_rgb(image_path, size=args.size)
    out_dir.mkdir(parents=True, exist_ok=True)
    image.save(out_dir / "input_letterbox_rgb.png")
    rgb = np.asarray(image, dtype=np.uint8)
    ifm_u8 = quantize_input_u8(rgb, input_scale, input_zp)
    input_zp_rtl = cfg_fields["izp"][0]
    centered_i16 = ifm_u8.astype(np.int16) - int(input_zp_rtl)
    sat_low_count = int(np.count_nonzero(centered_i16 < -128))
    sat_high_count = int(np.count_nonzero(centered_i16 > 127))
    ifm_s8 = clamp_int8(centered_i16)

    ifm_axis5 = np.zeros((args.size, args.size, 5), dtype=np.uint8)
    ifm_axis5[:, :, 0:3] = ifm_u8

    psum_i32 = conv2d_3x3_same_i32(ifm_s8, conv0_w, bias_i32)
    requant_s8 = requantize_psum(psum_i32, cfg_fields["mult"][0], cfg_fields["shift"][0], cfg_fields["ozp"][0])
    activation_u8 = fr0[requant_s8.view(np.uint8)]
    pooled_u8 = maxpool2d_u8_2x2_stride2(activation_u8) if args.pool_stride2 else None

    write_bin(out_dir / "ifm_u8_hwc.bin", ifm_u8)
    write_bin(out_dir / "ifm_s8_hwc.bin", ifm_s8)
    write_bin(out_dir / "ifm_axis5_u8_hwc.bin", ifm_axis5)
    write_bin(out_dir / "weight_raw_oihw_s8.bin", conv0_w)
    write_bin(out_dir / "weight_packed_fw0_s8.bin", fw0)
    write_bin(out_dir / "bias_i32.bin", bias_i32)
    write_bin(out_dir / "bias_i64_from_infer_bin.bin", bias_i64)
    write_bin(out_dir / "psum_i32_hwc.bin", psum_i32)
    write_bin(out_dir / "requant_s8_hwc.bin", requant_s8)
    write_bin(out_dir / "requant_u8_hwc.bin", requant_s8.view(np.uint8))
    write_bin(out_dir / "activation_lut_u8.bin", fr0)
    write_bin(out_dir / "activation_u8_hwc.bin", activation_u8)
    write_bin(out_dir / "golden_ofm_u8_hwc.bin", activation_u8)
    if pooled_u8 is not None:
        write_bin(out_dir / "golden_pool2x2s2_u8_hwc.bin", pooled_u8)

    manifest = {
        "description": "Conv0 real-image golden data for RTL bring-up.",
        "project": str(project),
        "image": str(image_path),
        "output_dir": str(out_dir),
        "model": str(model_path),
        "prefix": args.prefix,
        "layer": {
            "name": "Conv0",
            "kernel": 3,
            "stride": 1,
            "pad": 1,
            "ifm_shape_hwc": list(ifm_u8.shape),
            "ifm_axis5_shape_hwc": list(ifm_axis5.shape),
            "weight_raw_shape_oihw": list(conv0_w.shape),
            "ofm_shape_hwc": list(activation_u8.shape),
            "pool_ofm_shape_hwc": list(pooled_u8.shape) if pooled_u8 is not None else None,
            "fw0_packed_count_int8": int(fw0.size),
        },
        "pool": {
            "enabled": bool(args.pool_stride2),
            "mode": "maxpool2d_u8_2x2_stride2" if args.pool_stride2 else "bypass",
            "position": "after activation",
        },
        "quant": {
            "input_scale": input_scale,
            "input_zero_point": input_zp,
            "weight_scale": conv0_weight_scale,
            "conv_scale": conv0_conv_scale,
            "conv_zero_point": conv0_conv_zp,
            "activation_scale": conv0_act_scale,
            "activation_zero_point": conv0_act_zp,
            "rtl_mult": cfg_fields["mult"][0],
            "rtl_raw_shift": cfg_fields["shift"][0],
            "rtl_effective_shift": cfg_fields["shift"][0] + 15,
            "rtl_multiplier_fractional_bits": 15,
            "rtl_izp": cfg_fields["izp"][0],
            "rtl_ozp": cfg_fields["ozp"][0],
            "rtl_azp": cfg_fields["azp"][0],
            "bias_mode": "int32",
        },
        "ifm_centering": {
            "input_zero_point": int(input_zp_rtl),
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
        "config": cfg_fields,
        "letterbox": letterbox_meta,
        "files": {
            "ifm_u8_hwc": "ifm_u8_hwc.bin",
            "ifm_s8_hwc": "ifm_s8_hwc.bin",
            "ifm_axis5_u8_hwc": "ifm_axis5_u8_hwc.bin",
            "weight_raw_oihw_s8": "weight_raw_oihw_s8.bin",
            "weight_packed_fw0_s8": "weight_packed_fw0_s8.bin",
            "bias_i32": "bias_i32.bin",
            "psum_i32_hwc": "psum_i32_hwc.bin",
            "requant_s8_hwc": "requant_s8_hwc.bin",
            "activation_lut_u8": "activation_lut_u8.bin",
            "golden_ofm_u8_hwc": "golden_ofm_u8_hwc.bin",
        },
        "notes": [
            "This export is for Conv0 bring-up only.",
            "The IFM is transformed as saturate_s8(ifm_u8 - rtl_izp) before convolution.",
            "Requant uses mult / 2^(raw_shift + 15) because mult stores 15 fractional bits.",
            "Bias uses RTL integer semantics: psum = conv_accumulator + int32_bias.",
            "Non-convolution YOLO operations such as MaxPool, Upsample, Concat, Detect decode and NMS are not exported here.",
        ],
    }
    if pooled_u8 is not None:
        manifest["files"]["golden_pool2x2s2_u8_hwc"] = "golden_pool2x2s2_u8_hwc.bin"
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    summary = {
        "out_dir": str(out_dir),
        "ifm_shape_hwc": list(ifm_u8.shape),
        "ofm_shape_hwc": list(activation_u8.shape),
        "input_zero_point": int(input_zp_rtl),
        "ifm_u8_min": int(ifm_u8.min()),
        "ifm_u8_max": int(ifm_u8.max()),
        "centered_s8_min": int(ifm_s8.min()),
        "centered_s8_max": int(ifm_s8.max()),
        "sat_count": sat_low_count + sat_high_count,
        "psum_min": int(psum_i32.min()),
        "psum_max": int(psum_i32.max()),
        "rtl_mult": int(cfg_fields["mult"][0]),
        "rtl_raw_shift": int(cfg_fields["shift"][0]),
        "rtl_effective_shift": int(cfg_fields["shift"][0] + 15),
        "bias_mode": "int32",
        "requant_min_signed": int(requant_s8.min()),
        "requant_max_signed": int(requant_s8.max()),
        "activation_min_u8": int(activation_u8.min()),
        "activation_max_u8": int(activation_u8.max()),
        "pool_enabled": bool(args.pool_stride2),
        "pool_shape_hwc": list(pooled_u8.shape) if pooled_u8 is not None else None,
        "pool_min_u8": int(pooled_u8.min()) if pooled_u8 is not None else None,
        "pool_max_u8": int(pooled_u8.max()) if pooled_u8 is not None else None,
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
