import argparse
import json
import re
from pathlib import Path


DEFAULT_SPEC = Path(__file__).resolve().parent / "single_scale_yolov3tiny_layers.json"
DEFAULT_PLAN = Path(__file__).resolve().parents[2] / "sw" / "vitis_2022_2" / "src" / "accel_single_scale_plan.h"
OFM_AXIS_BEAT_BYTES = 8


def ceil_div(value, divisor):
    return (value + divisor - 1) // divisor


def parse_define_int(text, name):
    m = re.search(rf"#define\s+{re.escape(name)}\s+([0-9]+)U?\b", text)
    if not m:
        raise RuntimeError(f"Missing integer define {name}")
    return int(m.group(1))


def parse_c_plan(path):
    text = path.read_text(encoding="utf-8")
    rows = parse_define_int(text, "ACCEL_SINGLE_SCALE_ROWS")
    cols = parse_define_int(text, "ACCEL_SINGLE_SCALE_COLS")
    ifm_banks = parse_define_int(text, "ACCEL_SINGLE_SCALE_IFM_BANKS")
    layer_count = parse_define_int(text, "ACCEL_SINGLE_SCALE_LAYER_COUNT")
    max_tile_ofm_h = parse_define_int(text, "ACCEL_SINGLE_SCALE_MAX_TILE_OFM_H")
    cout_tile = cols * 2

    entry_re = re.compile(r'\{\s*"([^"]+)"\s*,([^{}]+)\}')
    layers = []
    for m in entry_re.finditer(text):
        name = m.group(1)
        nums = [int(x) for x in re.findall(r"\b[0-9]+\b", m.group(2))]
        if len(nums) != 17:
            raise RuntimeError(f"Unexpected field count for {name}: {len(nums)}")
        layers.append(
            {
                "name": name,
                "model_index": nums[0],
                "infer_index": nums[1],
                "fm_w": nums[2],
                "fm_h": nums[3],
                "cin": nums[4],
                "cout_total": nums[5],
                "kernel": nums[6],
                "stride": nums[7],
                "pad": nums[8],
                "pool_enable": nums[9],
                "pool_stride": nums[10],
                "conv_pixels": nums[11],
                "final_pixels": nums[12],
                "expected_ofm_bytes": nums[13],
                "k_total": nums[14],
                "k_passes": nums[15],
                "cout_blocks": nums[16],
            }
        )

    if len(layers) != layer_count:
        raise RuntimeError(f"Layer count mismatch in C plan: got {len(layers)} exp {layer_count}")

    return {
        "rows": rows,
        "cols": cols,
        "ifm_banks": ifm_banks,
        "cout_tile": cout_tile,
        "max_tile_ofm_h": max_tile_ofm_h,
        "layers": layers,
    }


def expected_from_spec_layer(layer, rows, cout_tile, max_tile_ofm_h):
    in_h, in_w, cin = [int(v) for v in layer["input_shape_hwc"]]
    conv_h, conv_w, cout = [int(v) for v in layer["conv_shape_hwc"]]
    out_h, out_w, out_c = [int(v) for v in layer["output_shape_hwc"]]
    kernel = int(layer["kernel"])
    stride = int(layer["stride"])
    pad = int(layer["pad"])
    hardware_kernel = int(layer.get("hardware_kernel", kernel))
    hardware_pad = int(layer.get("hardware_pad", pad))
    pool_enable = 0 if layer["pool"] == "bypass" else 1
    pool_stride = 2 if layer["pool"] == "maxpool2x2s2" else 0

    calc_conv_w = ((in_w + 2 * pad - kernel) // stride) + 1
    calc_conv_h = ((in_h + 2 * pad - kernel) // stride) + 1
    if calc_conv_w != conv_w or calc_conv_h != conv_h:
        raise RuntimeError(f"{layer['name']}: conv shape does not match kernel/stride/pad")
    hardware_conv_w = ((in_w + 2 * hardware_pad - hardware_kernel) // stride) + 1
    hardware_conv_h = ((in_h + 2 * hardware_pad - hardware_kernel) // stride) + 1
    if hardware_conv_w != conv_w or hardware_conv_h != conv_h:
        raise RuntimeError(f"{layer['name']}: hardware conv mapping changes the output shape")

    final_w = conv_w
    final_h = conv_h
    if pool_enable:
        final_w = conv_w // pool_stride
        final_h = conv_h // pool_stride
    if final_w != out_w or final_h != out_h or out_c != cout:
        raise RuntimeError(f"{layer['name']}: output shape does not match conv/pool shape")

    tile_h = min(max_tile_ofm_h, conv_h)
    if pool_enable and (tile_h % pool_stride) != 0:
        tile_h -= tile_h % pool_stride
    if tile_h <= 0:
        raise RuntimeError(f"{layer['name']}: invalid tile_h {tile_h}")
    tile_count = ceil_div(conv_h, tile_h)
    last_tile_h = conv_h - ((tile_count - 1) * tile_h)
    if pool_enable and (last_tile_h % pool_stride) != 0:
        raise RuntimeError(f"{layer['name']}: last pooled tile height is not aligned")

    max_tile_output_pixels = conv_w * tile_h
    if pool_enable:
        max_tile_output_pixels = (conv_w // pool_stride) * (tile_h // pool_stride)

    return {
        "name": layer["name"],
        "model_index": int(layer["model_index"]),
        "infer_index": int(layer["infer_index"]),
        "fm_w": in_w,
        "fm_h": in_h,
        "cin": cin,
        "cout_total": cout,
        "kernel": hardware_kernel,
        "stride": stride,
        "pad": hardware_pad,
        "pool_enable": pool_enable,
        "pool_stride": pool_stride,
        "conv_pixels": conv_w * conv_h,
        "final_pixels": out_w * out_h,
        "expected_ofm_bytes": out_w * out_h * cout,
        "k_total": cin * hardware_kernel * hardware_kernel,
        "k_passes": ceil_div(cin * hardware_kernel * hardware_kernel, rows),
        "cout_blocks": ceil_div(cout, cout_tile),
        "conv_w": conv_w,
        "conv_h": conv_h,
        "final_w": out_w,
        "final_h": out_h,
        "tile_h": tile_h,
        "tile_count": tile_count,
        "max_tile_axis_bytes": max_tile_output_pixels * cout * OFM_AXIS_BEAT_BYTES,
    }


def compare_layer(c_layer, e_layer):
    keys = [
        "name",
        "model_index",
        "infer_index",
        "fm_w",
        "fm_h",
        "cin",
        "cout_total",
        "kernel",
        "stride",
        "pad",
        "pool_enable",
        "pool_stride",
        "conv_pixels",
        "final_pixels",
        "expected_ofm_bytes",
        "k_total",
        "k_passes",
        "cout_blocks",
    ]
    return [f"{c_layer['name']}: {k} got {c_layer[k]} exp {e_layer[k]}" for k in keys if c_layer[k] != e_layer[k]]


def main():
    ap = argparse.ArgumentParser(description="Verify Vitis single-scale schedule against the JSON layer spec.")
    ap.add_argument("--spec", type=Path, default=DEFAULT_SPEC)
    ap.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    args = ap.parse_args()

    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    c_plan = parse_c_plan(args.plan)
    errors = []

    array = spec["array"]
    for key in ["rows", "cols", "ifm_banks", "cout_tile"]:
        if int(array[key]) != int(c_plan[key]):
            errors.append(f"array.{key} got {c_plan[key]} exp {array[key]}")

    spec_layers = spec["layers"]
    if len(spec_layers) != len(c_plan["layers"]):
        errors.append(f"layer count got {len(c_plan['layers'])} exp {len(spec_layers)}")

    total_tiles = 0
    total_blocks = 0
    max_axis = 0
    max_tile_axis = 0
    fb = [0, 0]
    external_input_bytes = 0
    prev_final = None

    for idx, (c_layer, spec_layer) in enumerate(zip(c_plan["layers"], spec_layers)):
        e_layer = expected_from_spec_layer(
            spec_layer,
            c_plan["rows"],
            c_plan["cout_tile"],
            c_plan["max_tile_ofm_h"],
        )
        errors.extend(compare_layer(c_layer, e_layer))

        if idx == 0:
            external_input_bytes = e_layer["fm_w"] * e_layer["fm_h"] * e_layer["cin"]
        elif prev_final != (e_layer["fm_w"], e_layer["fm_h"], e_layer["cin"]):
            errors.append(f"{e_layer['name']}: input shape does not match previous output")

        out_id = idx & 1
        fb[out_id] = max(fb[out_id], e_layer["expected_ofm_bytes"])
        max_axis = max(max_axis, e_layer["expected_ofm_bytes"] * OFM_AXIS_BEAT_BYTES)
        max_tile_axis = max(max_tile_axis, e_layer["max_tile_axis_bytes"])
        total_tiles += e_layer["tile_count"]
        total_blocks += e_layer["tile_count"] * e_layer["cout_blocks"]
        prev_final = (e_layer["final_w"], e_layer["final_h"], e_layer["cout_total"])

        print(
            f"plan[{idx}] {e_layer['name']} "
            f"{e_layer['fm_w']}x{e_layer['fm_h']}x{e_layer['cin']} -> "
            f"{e_layer['final_w']}x{e_layer['final_h']}x{e_layer['cout_total']} "
            f"bytes={e_layer['expected_ofm_bytes']} tile_h={e_layer['tile_h']} "
            f"tiles={e_layer['tile_count']} tile_axis={e_layer['max_tile_axis_bytes']} "
            f"kpass={e_layer['k_passes']} cblk={e_layer['cout_blocks']}"
        )

    print(
        "summary "
        f"layers={len(c_plan['layers'])} ext_in={external_input_bytes} "
        f"fb0={fb[0]} fb1={fb[1]} max_axis={max_axis} "
        f"max_tile_axis={max_tile_axis} tiles={total_tiles} blocks={total_blocks}"
    )

    if errors:
        print("FAIL: single-scale schedule verification failed")
        for err in errors:
            print(f"  {err}")
        raise SystemExit(1)

    print("PASS: single-scale schedule matches JSON spec and C plan")


if __name__ == "__main__":
    main()
