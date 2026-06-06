import argparse
import importlib.util
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[2]
PARSER_PATH = ROOT / "tools" / "golden" / "compare_yolo_uart.py"
COLORS = ((40, 190, 90), (225, 70, 65), (245, 170, 35))


def load_uart_parser():
    spec = importlib.util.spec_from_file_location("compare_yolo_uart", PARSER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.parse_uart


def draw_detections(image_path, uart_log, output_path, json_path):
    parse_uart = load_uart_parser()
    detections = parse_uart(uart_log.read_text(encoding="utf-8", errors="replace"))
    image = Image.open(image_path).convert("RGB")
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default()
    line_width = max(2, round(max(image.size) / 256))

    for detection in detections:
        x1, y1, x2, y2 = detection["original_xyxy"]
        color = COLORS[detection["class_id"] % len(COLORS)]
        label = f"{detection['class_name']} {detection['score']:.3f}"
        draw.rectangle((x1, y1, x2, y2), outline=color, width=line_width)
        left, top, right, bottom = draw.textbbox((0, 0), label, font=font)
        label_w = right - left + 8
        label_h = bottom - top + 6
        label_y = max(0, y1 - label_h)
        draw.rectangle((x1, label_y, x1 + label_w, label_y + label_h), fill=color)
        draw.text((x1 + 4, label_y + 3), label, fill=(255, 255, 255), font=font)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(output_path)
    result = {
        "image": str(image_path.resolve()),
        "uart_log": str(uart_log.resolve()),
        "visualization": str(output_path.resolve()),
        "detection_count": len(detections),
        "detections": detections,
    }
    json_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description="Draw KV260 UART detections on the original image.")
    parser.add_argument("image", type=Path)
    parser.add_argument("uart_log", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()

    result = draw_detections(args.image, args.uart_log, args.output, args.json)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
