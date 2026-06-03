import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from PIL import Image


DEFAULT_EXTERNAL_PROJECT = Path(os.environ.get("PYTHON_PRJ", r"D:\MPSoC\python_prj"))


def letterbox_rgb(image, size=416, fill=114):
    src_w, src_h = image.size
    scale = min(size / src_w, size / src_h)
    new_w = int(round(src_w * scale))
    new_h = int(round(src_h * scale))
    resized = image.resize((new_w, new_h), Image.BILINEAR)
    canvas = Image.new("RGB", (size, size), (fill, fill, fill))
    pad_x = (size - new_w) // 2
    pad_y = (size - new_h) // 2
    canvas.paste(resized, (pad_x, pad_y))
    return canvas, {
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


def build_quant_model(project, float_model, quant_state):
    sys.path.insert(0, str(project))
    from models.experimental import attempt_load

    torch.backends.quantized.engine = "fbgemm"
    model = attempt_load(str(float_model), map_location="cpu")
    model.eval()

    quant_model = nn.Sequential(
        torch.quantization.QuantStub(),
        model,
        torch.quantization.DeQuantStub(),
    ).to("cpu")
    quant_model.qconfig = torch.quantization.default_qconfig
    quant_model = torch.quantization.prepare(quant_model, inplace=False)
    quant_model = torch.quantization.convert(quant_model, inplace=False)
    quant_model.load_state_dict(torch.load(quant_state, map_location="cpu"))
    quant_model.eval()
    return quant_model


def clean_type(module_type):
    return module_type.replace("models.common.", "").replace("models.yolo.", "").replace(
        "torch.nn.modules.", ""
    ).replace(".", "_")


def tensor_stats(tensor):
    if tensor.is_quantized:
        raw = tensor.int_repr()
        return {
            "min": int(raw.min().item()),
            "max": int(raw.max().item()),
            "scale": float(tensor.q_scale()),
            "zero_point": int(tensor.q_zero_point()),
            "torch_dtype": str(tensor.dtype),
        }
    return {
        "min": float(tensor.min().item()),
        "max": float(tensor.max().item()),
        "torch_dtype": str(tensor.dtype),
    }


def write_tensor(out_dir, stem, tensor):
    tensor = tensor.detach().cpu()
    entry = {
        "shape": list(tensor.shape),
        "is_quantized": bool(tensor.is_quantized),
        **tensor_stats(tensor),
        "files": {},
    }

    if tensor.is_quantized:
        raw = tensor.int_repr().contiguous().numpy().astype(np.uint8)
        native = f"{stem}_u8_native.bin"
        raw.tofile(out_dir / native)
        entry["files"]["u8_native"] = native

        if raw.ndim == 4 and raw.shape[0] == 1:
            chw = raw[0]
            hwc = np.transpose(chw, (1, 2, 0)).copy()
            hwc_name = f"{stem}_u8_hwc.bin"
            hwc.tofile(out_dir / hwc_name)
            entry["files"]["u8_hwc"] = hwc_name
            entry["shape_hwc"] = list(hwc.shape)
        elif raw.ndim == 5 and raw.shape[0] == 1:
            native_shape = raw[0].shape
            entry["shape_native_no_batch"] = list(native_shape)
    else:
        raw = tensor.contiguous().numpy().astype(np.float32)
        native = f"{stem}_f32_native.bin"
        raw.tofile(out_dir / native)
        entry["files"]["f32_native"] = native

        if raw.ndim == 4 and raw.shape[0] == 1:
            chw = raw[0]
            hwc = np.transpose(chw, (1, 2, 0)).copy()
            hwc_name = f"{stem}_f32_hwc.bin"
            hwc.tofile(out_dir / hwc_name)
            entry["files"]["f32_hwc"] = hwc_name
            entry["shape_hwc"] = list(hwc.shape)

    return entry


def export_layers(args):
    project = Path(args.project).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    image_path = Path(args.image).resolve()
    float_model = Path(args.float_model).resolve()
    quant_state = Path(args.quant_state).resolve()

    image = Image.open(image_path).convert("RGB")
    lb_image, lb_meta = letterbox_rgb(image, args.img_size, args.fill)
    lb_image.save(out_dir / "input_letterbox_rgb.png")

    rgb = np.asarray(lb_image).copy()
    x_float_np = rgb.transpose(2, 0, 1).astype(np.float32) / 255.0
    x_float_np.tofile(out_dir / "input_float_chw_f32.bin")
    rgb.tofile(out_dir / "input_rgb_hwc_u8.bin")
    x_float = torch.from_numpy(x_float_np).unsqueeze(0)

    quant_model = build_quant_model(project, float_model, quant_state)
    model = quant_model[1]
    detect = model.model[-1]
    detect.training = True  # Export raw detect tensors, not sigmoid/grid-decoded boxes.

    manifest = {
        "description": "YOLOv3-tiny facemask real-image per-layer quantized golden data.",
        "project": str(project),
        "image": str(image_path),
        "float_model": str(float_model),
        "quant_state": str(quant_state),
        "output_dir": str(out_dir),
        "preprocess": {
            "input_float_layout": "CHW, RGB, float32, value=image_u8/255.0",
            "input_rgb_layout": "HWC, RGB, uint8",
            "letterbox": lb_meta,
        },
        "files": {
            "input_letterbox_rgb": "input_letterbox_rgb.png",
            "input_float_chw_f32": "input_float_chw_f32.bin",
            "input_rgb_hwc_u8": "input_rgb_hwc_u8.bin",
        },
        "layers": [],
        "notes": [
            "Layer outputs are captured from the quantized PyTorch model using a manual YOLO forward_once loop.",
            "Quantized tensor files contain int_repr() bytes; use scale and zero_point from this manifest to dequantize.",
            "4D feature maps are exported in native NCHW and HWC layout. 5D Detect outputs keep native [N, anchor, H, W, value] order.",
            "Detect sigmoid/grid/anchor decode is intentionally not exported because the original model mixes quantized tensors with float grid math there.",
            "This file set is software-model golden for network dataflow. Conv0 RTL-bit-oriented psum/requant golden is exported separately by export_rtl_conv0_golden.py.",
        ],
    }

    with torch.no_grad():
        x = quant_model[0](x_float)
        manifest["quantized_input"] = write_tensor(out_dir, "input_quant", x)

        saved = []
        for module in model.model:
            if module.f != -1:
                if isinstance(module.f, int):
                    x = saved[module.f]
                else:
                    x = [x if j == -1 else saved[j] for j in module.f]

            x = module(x)
            layer_entry = {
                "index": int(module.i),
                "from": module.f,
                "type": module.type,
                "name": clean_type(module.type),
            }

            if isinstance(x, (list, tuple)):
                layer_entry["outputs"] = []
                for idx, tensor in enumerate(x):
                    stem = f"layer{module.i:02d}_{clean_type(module.type)}_{idx}"
                    layer_entry["outputs"].append(write_tensor(out_dir, stem, tensor))
            else:
                stem = f"layer{module.i:02d}_{clean_type(module.type)}"
                layer_entry["output"] = write_tensor(out_dir, stem, x)

            manifest["layers"].append(layer_entry)
            saved.append(x if module.i in model.save else None)

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(
        description="Export facemask YOLOv3-tiny quantized per-layer golden tensors."
    )
    project = DEFAULT_EXTERNAL_PROJECT
    parser.add_argument("--project", default=str(project))
    parser.add_argument("--image", default=str(project / "facemask" / "images" / "maksssksksss0.png"))
    parser.add_argument("--float-model", default=str(project / "models_files" / "yolov3tiny_facemask.pt"))
    parser.add_argument("--quant-state", default=str(project / "models_files" / "yolov3tiny_facemask_quant.pth"))
    parser.add_argument("--out-dir", default=str(project / "rtl_golden" / "facemask_yolov3tiny_layers"))
    parser.add_argument("--img-size", type=int, default=416)
    parser.add_argument("--fill", type=int, default=114)
    args = parser.parse_args()

    manifest = export_layers(args)
    summary = {
        "out_dir": manifest["output_dir"],
        "layer_count": len(manifest["layers"]),
        "first_layer": manifest["layers"][0]["output"]["shape_hwc"],
        "detect_outputs": [
            output["shape"] for output in manifest["layers"][-1]["outputs"]
        ],
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
