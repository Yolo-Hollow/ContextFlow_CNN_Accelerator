from pathlib import Path

import json
import numpy as np


SRC_DIR = Path(r"D:\MPSoC\python_prj\rtl_golden\facemask_conv0")
OUT_DIR = Path(r"D:\MPSoC\python_prj\rtl_golden\facemask_conv0_crop16x8_pool")

SRC_H = 416
SRC_W = 416
CIN = 3
COUT = 16
CROP_X = 96
CROP_Y = 96
CROP_W = 16
CROP_H = 8
INPUT_ZP = 0
MULT = 18898
RAW_SHIFT = 9
OUTPUT_ZP = 69


def write_hex(path, values, width):
    path.parent.mkdir(parents=True, exist_ok=True)
    mask = (1 << (width * 4)) - 1
    with path.open("w", encoding="ascii") as f:
        for value in values:
            f.write(f"{int(value) & mask:0{width}x}\n")


def clamp_int8(x):
    return np.clip(x, -128, 127).astype(np.int8)


def requantize_psum(psum):
    effective_shift = RAW_SHIFT + 15
    v = psum.astype(np.int64) * MULT
    v = v + (1 << (effective_shift - 1))
    v = np.right_shift(v, effective_shift) + OUTPUT_ZP
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
    pooled = np.empty((h // 2, w // 2, c), dtype=np.uint8)
    for y in range(h // 2):
        for x in range(w // 2):
            pooled[y, x, :] = hwc_u8[y * 2 : y * 2 + 2, x * 2 : x * 2 + 2, :].max(axis=(0, 1))
    return pooled


def main():
    ifm_full = np.fromfile(SRC_DIR / "ifm_u8_hwc.bin", dtype=np.uint8).reshape(SRC_H, SRC_W, CIN)
    weight = np.fromfile(SRC_DIR / "weight_raw_oihw_s8.bin", dtype=np.int8).reshape(COUT, CIN, 3, 3)
    bias = np.fromfile(SRC_DIR / "bias_i32.bin", dtype=np.int32)
    lut = np.fromfile(SRC_DIR / "activation_lut_u8.bin", dtype=np.uint8)

    ifm_u8 = ifm_full[CROP_Y : CROP_Y + CROP_H, CROP_X : CROP_X + CROP_W, :].copy()
    centered = ifm_u8.astype(np.int16) - INPUT_ZP
    ifm_s8 = clamp_int8(centered)
    psum = conv2d_3x3_same_i32(ifm_s8, weight, bias)
    requant = requantize_psum(psum)
    activation = lut[requant.view(np.uint8)]
    pooled = maxpool2d_u8_2x2_stride2(activation)

    xsim_dir = OUT_DIR / "xsim_mem"
    weight_kco = np.empty((CIN * 9, COUT), dtype=np.uint8)
    for ch in range(CIN):
        for ky in range(3):
            for kx in range(3):
                k = ch * 9 + ky * 3 + kx
                weight_kco[k, :] = weight[:, ch, ky, kx].view(np.uint8)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ifm_u8.tofile(OUT_DIR / "ifm_u8_hwc.bin")
    activation.tofile(OUT_DIR / "golden_ofm_u8_hwc.bin")
    pooled.tofile(OUT_DIR / "golden_pool2x2s2_u8_hwc.bin")

    write_hex(xsim_dir / "ifm_u8_hwc.mem", ifm_u8.reshape(-1), 2)
    write_hex(xsim_dir / "weight_kco_s8.mem", weight_kco.reshape(-1), 2)
    write_hex(xsim_dir / "bias_i32.mem", bias.view(np.uint32), 8)
    write_hex(xsim_dir / "activation_lut_u8.mem", lut, 2)
    write_hex(xsim_dir / "golden_pool2x2s2_u8_hwc.mem", pooled.reshape(-1), 2)

    manifest = {
        "description": "Small Conv0 real-data crop for RTL Conv+Pool xsim regression.",
        "source_dir": str(SRC_DIR),
        "output_dir": str(OUT_DIR),
        "crop": {"x": CROP_X, "y": CROP_Y, "w": CROP_W, "h": CROP_H},
        "ifm_shape_hwc": list(ifm_u8.shape),
        "ofm_shape_hwc": list(activation.shape),
        "pool_shape_hwc": list(pooled.shape),
        "quant": {
            "input_zero_point": INPUT_ZP,
            "mult": MULT,
            "raw_shift": RAW_SHIFT,
            "effective_shift": RAW_SHIFT + 15,
            "output_zero_point": OUTPUT_ZP,
        },
        "stats": {
            "ifm_u8_min": int(ifm_u8.min()),
            "ifm_u8_max": int(ifm_u8.max()),
            "centered_s8_min": int(ifm_s8.min()),
            "centered_s8_max": int(ifm_s8.max()),
            "sat_count": int(np.count_nonzero((centered < -128) | (centered > 127))),
            "activation_min": int(activation.min()),
            "activation_max": int(activation.max()),
            "pool_min": int(pooled.min()),
            "pool_max": int(pooled.max()),
        },
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
