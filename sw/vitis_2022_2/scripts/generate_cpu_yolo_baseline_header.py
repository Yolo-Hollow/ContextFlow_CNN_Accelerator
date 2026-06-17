import argparse
import json
import struct
from pathlib import Path


DEFAULT_PROJECT = Path(r"D:\MPSoC\python_prj")


LAYERS = [
    ("facemask_chain_conv0_conv4_rtl", "00_conv0_pool"),
    ("facemask_chain_conv0_conv4_rtl", "01_conv1_pool"),
    ("facemask_chain_conv0_conv4_rtl", "02_conv2_pool"),
    ("facemask_chain_conv0_conv4_rtl", "03_conv3_pool"),
    ("facemask_chain_conv0_conv4_rtl", "04_conv4_pool"),
    ("facemask_chain_conv0_conv5_rtl", "05_conv5_pool_like_tiny"),
    ("facemask_chain_conv0_conv6_rtl", "06_head_conv6_3x3"),
    ("facemask_chain_conv0_conv7_rtl", "07_head_conv7_1x1"),
    ("facemask_chain_conv0_conv8_rtl", "08_head_conv8_3x3"),
    ("facemask_chain_conv0_conv9_rtl", "09_head_detect_conv9_1x1"),
]


def read_exact(path, expected_size):
    data = path.read_bytes()
    if len(data) != expected_size:
        raise RuntimeError(f"{path} has {len(data)} bytes, expected {expected_size}")
    return data


def int8_value(byte):
    return byte - 256 if byte >= 128 else byte


def symbol_from_layer(name):
    return name[3:].replace("-", "_")


def emit_array(f, c_type, name, values, per_line=16, static=True):
    storage = "static const" if static else "const"
    f.write(f"{storage} {c_type} {name}[{len(values)}] = {{\n")
    for i in range(0, len(values), per_line):
        chunk = values[i : i + per_line]
        f.write("    ")
        f.write(", ".join(str(v) for v in chunk))
        if i + per_line < len(values):
            f.write(",")
        f.write("\n")
    f.write("};\n\n")


def pack_weight_kco(weight_oihw, cout, cin, kernel):
    weight_kco = []
    for ci in range(cin):
        for ky in range(kernel):
            for kx in range(kernel):
                for co in range(cout):
                    src = ((co * cin + ci) * kernel + ky) * kernel + kx
                    weight_kco.append(weight_oihw[src])
    return weight_kco


def main():
    parser = argparse.ArgumentParser(description="Generate CPU-only YOLOv3-tiny baseline data header.")
    parser.add_argument("output_header")
    parser.add_argument("--project", default=str(DEFAULT_PROJECT))
    parser.add_argument(
        "--omit-golden",
        action="store_true",
        help="Do not embed per-layer golden OFM arrays; golden_mismatch prints zero.",
    )
    args = parser.parse_args()

    project = Path(args.project).resolve()
    rtl_root = project / "rtl_golden"
    out = Path(args.output_header).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)

    entries = []
    for root_name, layer_name in LAYERS:
        layer_dir = rtl_root / root_name / layer_name
        meta = json.loads((layer_dir / "manifest.json").read_text(encoding="utf-8"))
        ifm_h, ifm_w, ifm_c = meta["shape"]["ifm_hwc"]
        conv_h, conv_w, conv_c = meta["shape"]["conv_ofm_hwc"]
        ofm_h, ofm_w, ofm_c = meta["shape"]["final_ofm_hwc"]
        kernel = int(meta["conv"]["kernel"])
        weight_bytes = conv_c * ifm_c * kernel * kernel
        bias_bytes = conv_c * 4
        golden_bytes = ofm_h * ofm_w * ofm_c
        weight_oihw = [int8_value(x) for x in read_exact(layer_dir / "weight_raw_oihw_s8.bin", weight_bytes)]
        entry = {
            "name": meta["name"],
            "symbol": symbol_from_layer(layer_name),
            "dir": layer_dir,
            "meta": meta,
            "ifm_shape": (ifm_h, ifm_w, ifm_c),
            "conv_shape": (conv_h, conv_w, conv_c),
            "ofm_shape": (ofm_h, ofm_w, ofm_c),
            "kernel": kernel,
            "stride": int(meta["conv"]["stride"]),
            "pad": int(meta["conv"]["pad"]),
            "pool_enable": 1 if meta["pool"]["mode"] == "maxpool2x2s2" else 0,
            "pool_stride": 2 if meta["pool"]["mode"] == "maxpool2x2s2" else 0,
            "input_zero_point": int(meta["ifm_centering"]["input_zero_point"]),
            "quant_mult": int(meta["quant"]["rtl_mult"]),
            "quant_shift": int(meta["quant"]["rtl_raw_shift"]),
            "output_zero_point": int(meta["quant"]["rtl_ozp"]),
            "weight": pack_weight_kco(weight_oihw, conv_c, ifm_c, kernel),
            "bias": list(struct.unpack("<" + "i" * conv_c, read_exact(layer_dir / "bias_i32.bin", bias_bytes))),
            "lut": list(read_exact(layer_dir / "activation_lut_u8.bin", 256)),
            "golden": None
            if args.omit_golden
            else list(read_exact(layer_dir / "golden_ofm_u8_hwc.bin", golden_bytes)),
            "golden_bytes": golden_bytes,
        }
        entries.append(entry)

    first_dir = entries[0]["dir"]
    input_h, input_w, input_c = entries[0]["ifm_shape"]
    input_data = list(read_exact(first_dir / "ifm_u8_hwc.bin", input_h * input_w * input_c))

    with out.open("w", encoding="ascii", newline="\n") as f:
        f.write("#ifndef CPU_YOLO_DATA_H\n")
        f.write("#define CPU_YOLO_DATA_H\n\n")
        f.write("#include <stdint.h>\n")
        f.write("#include \"cpu_yolo_baseline.h\"\n\n")
        f.write(f"/* Generated from {rtl_root.as_posix()} chain RTL semantic golden data. */\n")
        f.write("/* Weight layout is KCO: [ci][ky][kx][out_channel]. */\n\n")
        emit_array(f, "uint8_t", "cpu_yolo_input_u8", input_data, static=False)
        for entry in entries:
            sym = entry["symbol"]
            emit_array(f, "int8_t", f"{sym}_weight_s8_kco", entry["weight"])
            emit_array(f, "int32_t", f"{sym}_bias_i32", entry["bias"], per_line=8)
            emit_array(f, "uint8_t", f"{sym}_activation_lut_u8", entry["lut"])
            if entry["golden"] is not None:
                emit_array(f, "uint8_t", f"{sym}_golden_ofm_u8", entry["golden"])

        f.write("const cpu_yolo_layer_t cpu_yolo_layers[CPU_YOLO_LAYER_COUNT] = {\n")
        for entry in entries:
            sym = entry["symbol"]
            ifm_h, ifm_w, ifm_c = entry["ifm_shape"]
            conv_h, conv_w, _ = entry["conv_shape"]
            ofm_h, ofm_w, ofm_c = entry["ofm_shape"]
            golden = f"{sym}_golden_ofm_u8" if entry["golden"] is not None else "0"
            f.write("    {\n")
            f.write(f"        \"{entry['name']}\",\n")
            f.write(f"        {ifm_h}U, {ifm_w}U, {ifm_c}U,\n")
            f.write(f"        {conv_h}U, {conv_w}U,\n")
            f.write(f"        {ofm_h}U, {ofm_w}U, {ofm_c}U,\n")
            f.write(
                f"        {entry['kernel']}U, {entry['stride']}U, {entry['pad']}U, "
                f"{entry['pool_enable']}U, {entry['pool_stride']}U,\n"
            )
            f.write(
                f"        {entry['input_zero_point']}U, {entry['output_zero_point']}U, "
                f"{entry['quant_mult']}U, {entry['quant_shift']}U,\n"
            )
            f.write(
                f"        {sym}_weight_s8_kco, {len(entry['weight'])}U, "
                f"{sym}_bias_i32, {len(entry['bias'])}U,\n"
            )
            f.write(
                f"        {sym}_activation_lut_u8, {golden}, "
                f"{entry['golden_bytes'] if entry['golden'] is not None else 0}U\n"
            )
            f.write("    },\n")
        f.write("};\n\n")
        f.write("#endif\n")

    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
