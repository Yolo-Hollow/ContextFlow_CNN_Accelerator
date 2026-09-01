"""Portable XSIM fixture generation from the repository repro package.

The generated ``.mem`` files are build products.  Inputs must remain below
``repro/`` so regressions never silently depend on a developer's training
workspace or another absolute path.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Iterable

import numpy as np


SOURCE_FILES = (
    "manifest.json",
    "ifm_u8_hwc.bin",
    "weight_raw_oihw_s8.bin",
    "bias_i32.bin",
    "activation_lut_u8.bin",
    "golden_ofm_u8_hwc.bin",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_under(path: Path, root: Path) -> Path:
    resolved = path.resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as exc:
        raise RuntimeError(f"fixture source escapes repository repro/: {resolved}") from exc
    return resolved


def load_layer(layer_dir: Path, repro_root: Path) -> tuple[dict, dict[str, np.ndarray]]:
    layer_dir = ensure_under(layer_dir, repro_root)
    missing = [name for name in SOURCE_FILES if not (layer_dir / name).is_file()]
    if missing:
        raise RuntimeError(f"missing repro inputs in {layer_dir}: {', '.join(missing)}")

    meta = json.loads((layer_dir / "manifest.json").read_text(encoding="utf-8"))
    ifm_h, ifm_w, cin = (int(v) for v in meta["shape"]["ifm_hwc"])
    conv_h, conv_w, cout = (int(v) for v in meta["shape"]["conv_ofm_hwc"])
    final_h, final_w, final_cout = (
        int(v)
        for v in meta["shape"].get("final_ofm_hwc", meta["shape"]["conv_ofm_hwc"])
    )
    kernel = int(meta["conv"]["kernel"])

    arrays = {
        "ifm": np.fromfile(layer_dir / "ifm_u8_hwc.bin", dtype=np.uint8),
        "weight": np.fromfile(layer_dir / "weight_raw_oihw_s8.bin", dtype=np.int8),
        "bias": np.fromfile(layer_dir / "bias_i32.bin", dtype=np.int32),
        "lut": np.fromfile(layer_dir / "activation_lut_u8.bin", dtype=np.uint8),
        "golden": np.fromfile(layer_dir / "golden_ofm_u8_hwc.bin", dtype=np.uint8),
    }
    expected = {
        "ifm": ifm_h * ifm_w * cin,
        "weight": cout * cin * kernel * kernel,
        "bias": cout,
        "lut": 256,
        "golden": final_h * final_w * final_cout,
    }
    for name, count in expected.items():
        if arrays[name].size != count:
            raise RuntimeError(
                f"{layer_dir.name}/{name} size mismatch: got {arrays[name].size}, expected {count}"
            )
    if (conv_h, conv_w) != (ifm_h, ifm_w):
        raise RuntimeError(
            f"unsupported spatial transform in {layer_dir.name}: "
            f"ifm={ifm_h}x{ifm_w}, conv={conv_h}x{conv_w}"
        )
    if final_cout != cout:
        raise RuntimeError(
            f"unsupported COUT transform in {layer_dir.name}: final={final_cout}, conv={cout}"
        )
    arrays["ifm"] = arrays["ifm"].reshape(ifm_h, ifm_w, cin)
    arrays["weight"] = arrays["weight"].reshape(cout, cin, kernel, kernel)
    arrays["golden"] = arrays["golden"].reshape(final_h, final_w, cout)
    return meta, arrays


def _write_hex(path: Path, values: np.ndarray, width: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    flat = np.asarray(values).reshape(-1)
    mask = (1 << (4 * width)) - 1
    chunk_items = 65536
    with temporary.open("w", encoding="ascii", newline="\n") as stream:
        for start in range(0, flat.size, chunk_items):
            chunk = flat[start : start + chunk_items]
            stream.write("".join(f"{int(value) & mask:0{width}x}\n" for value in chunk))
    temporary.replace(path)


def emit_standard_layer(
    layer_dir: Path,
    out_dir: Path,
    repro_root: Path,
    cout_limit: int | None = None,
) -> list[Path]:
    meta, arrays = load_layer(layer_dir, repro_root)
    cout = int(meta["shape"]["conv_ofm_hwc"][2])
    emit_cout = cout if cout_limit is None else int(cout_limit)
    if not 1 <= emit_cout <= cout:
        raise RuntimeError(f"invalid COUT limit {emit_cout} for {layer_dir.name} COUT={cout}")

    # RTL stream order is k-major/co-minor, k={ci,ky,kx}.
    weight_kco = arrays["weight"][:emit_cout].transpose(1, 2, 3, 0).reshape(-1)
    outputs = [
        out_dir / "ifm_u8_hwc.mem",
        out_dir / "weight_kco_s8.mem",
        out_dir / "bias_i32.mem",
        out_dir / "activation_lut_u8.mem",
        out_dir / "golden_ofm_u8_hwc.mem",
    ]
    _write_hex(outputs[0], arrays["ifm"], 2)
    _write_hex(outputs[1], weight_kco.view(np.uint8), 2)
    _write_hex(outputs[2], arrays["bias"][:emit_cout].view(np.uint32), 8)
    _write_hex(outputs[3], arrays["lut"], 2)
    _write_hex(outputs[4], arrays["golden"][:, :, :emit_cout], 2)
    return outputs


def _requant_activate(psums: np.ndarray, meta: dict, lut: np.ndarray) -> np.ndarray:
    quant = meta["quant"]
    mult = int(quant["rtl_mult"])
    effective_shift = int(quant.get("rtl_effective_shift", int(quant["rtl_raw_shift"]) + 15))
    output_zp = int(quant["rtl_ozp"])
    product = psums.astype(np.int64) * mult
    rounded = np.right_shift(product + (1 << (effective_shift - 1)), effective_shift)
    requant = np.clip(rounded + output_zp, -128, 127).astype(np.int8)
    return lut[requant.view(np.uint8)]


def _conv_same_psum(meta: dict, arrays: dict[str, np.ndarray]) -> np.ndarray:
    ifm = arrays["ifm"]
    weight = arrays["weight"]
    bias = arrays["bias"]
    kernel = int(meta["conv"]["kernel"])
    pad = int(meta["conv"]["pad"])
    input_zp = int(meta["quant"]["rtl_izp"])
    centered = np.clip(ifm.astype(np.int16) - input_zp, -128, 127).astype(np.int32)
    padded = np.pad(centered, ((pad, pad), (pad, pad), (0, 0)), mode="constant")
    height, width, cin = centered.shape
    cout = weight.shape[0]
    psum = np.broadcast_to(bias.reshape(1, 1, cout), (height, width, cout)).astype(np.int64).copy()
    for ky in range(kernel):
        for kx in range(kernel):
            window = padded[ky : ky + height, kx : kx + width]
            # Matrix multiplication keeps the accumulation exact while avoiding
            # hundreds of large Python-level tensor operations.
            psum += window.reshape(height * width, cin).astype(np.int64).dot(
                weight[:, :, ky, kx].astype(np.int64).T
            ).reshape(height, width, cout)
    return psum


def maxpool2x2s2(values: np.ndarray) -> np.ndarray:
    height, width, channels = values.shape
    if (height & 1) or (width & 1):
        raise RuntimeError(f"2x2s2 pooling requires even dimensions, got {height}x{width}")
    return values.reshape(height // 2, 2, width // 2, 2, channels).max(axis=(1, 3))


def emit_conv3_with_unpooled_golden(
    layer_dir: Path, out_dir: Path, repro_root: Path
) -> list[Path]:
    meta, arrays = load_layer(layer_dir, repro_root)
    if meta["name"] != "conv3_pool":
        raise RuntimeError(f"expected conv3_pool fixture, got {meta['name']}")
    psum = _conv_same_psum(meta, arrays)
    activated = _requant_activate(psum, meta, arrays["lut"])
    pooled = maxpool2x2s2(activated)
    if not np.array_equal(pooled, arrays["golden"]):
        mismatch = int(np.count_nonzero(pooled != arrays["golden"]))
        raise RuntimeError(
            f"derived conv3 pooled output disagrees with repro golden: {mismatch} bytes"
        )

    weight_kco = arrays["weight"].transpose(1, 2, 3, 0).reshape(-1)
    outputs = [
        out_dir / "ifm_u8_hwc.mem",
        out_dir / "weight_kco_s8.mem",
        out_dir / "bias_i32.mem",
        out_dir / "activation_lut_u8.mem",
        out_dir / "golden_ofm_u8_hwc.mem",
        out_dir / "golden_pool2x2s2_u8_hwc.mem",
    ]
    _write_hex(outputs[0], arrays["ifm"], 2)
    _write_hex(outputs[1], weight_kco.view(np.uint8), 2)
    _write_hex(outputs[2], arrays["bias"].view(np.uint32), 8)
    _write_hex(outputs[3], arrays["lut"], 2)
    _write_hex(outputs[4], activated, 2)
    _write_hex(outputs[5], pooled, 2)
    return outputs


def emit_conv0_crop(
    layer_dir: Path,
    out_dir: Path,
    repro_root: Path,
    crop_x: int = 96,
    crop_y: int = 96,
    crop_w: int = 16,
    crop_h: int = 8,
) -> list[Path]:
    meta, arrays = load_layer(layer_dir, repro_root)
    if meta["name"] != "conv0_pool":
        raise RuntimeError(f"expected conv0_pool fixture, got {meta['name']}")
    ifm_h, ifm_w, _ = arrays["ifm"].shape
    if crop_x < 0 or crop_y < 0 or crop_x + crop_w > ifm_w or crop_y + crop_h > ifm_h:
        raise RuntimeError("Conv0 crop lies outside the repro IFM")

    crop_arrays = dict(arrays)
    crop_arrays["ifm"] = arrays["ifm"][
        crop_y : crop_y + crop_h, crop_x : crop_x + crop_w
    ].copy()
    crop_meta = json.loads(json.dumps(meta))
    crop_meta["shape"]["ifm_hwc"] = [crop_h, crop_w, crop_arrays["ifm"].shape[2]]
    crop_meta["shape"]["conv_ofm_hwc"] = [crop_h, crop_w, arrays["weight"].shape[0]]
    crop_meta["shape"]["final_ofm_hwc"] = [
        crop_h // 2,
        crop_w // 2,
        arrays["weight"].shape[0],
    ]
    psum = _conv_same_psum(crop_meta, crop_arrays)
    activated = _requant_activate(psum, crop_meta, arrays["lut"])
    pooled = maxpool2x2s2(activated)
    weight_kco = arrays["weight"].transpose(1, 2, 3, 0).reshape(-1)

    outputs = [
        out_dir / "ifm_u8_hwc.mem",
        out_dir / "weight_kco_s8.mem",
        out_dir / "bias_i32.mem",
        out_dir / "activation_lut_u8.mem",
        out_dir / "golden_pool2x2s2_u8_hwc.mem",
    ]
    _write_hex(outputs[0], crop_arrays["ifm"], 2)
    _write_hex(outputs[1], weight_kco.view(np.uint8), 2)
    _write_hex(outputs[2], arrays["bias"].view(np.uint32), 8)
    _write_hex(outputs[3], arrays["lut"], 2)
    _write_hex(outputs[4], pooled, 2)
    return outputs


def source_fingerprint(paths: Iterable[Path], root: Path) -> list[dict[str, object]]:
    records = []
    for path in sorted((p.resolve() for p in paths), key=lambda item: item.as_posix()):
        records.append(
            {
                "path": path.relative_to(root.resolve()).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    return records
