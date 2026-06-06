import argparse
import json
import re
from pathlib import Path


COUNT_RE = re.compile(r"^DECODE count=(\d+)$")
DET_RE = re.compile(
    r"^DET index=(\d+) class=(\d+) name=(\S+) score=([-0-9.]+) "
    r"model_x1=([-0-9.]+) model_y1=([-0-9.]+) "
    r"model_x2=([-0-9.]+) model_y2=([-0-9.]+) "
    r"orig_x1=([-0-9.]+) orig_y1=([-0-9.]+) "
    r"orig_x2=([-0-9.]+) orig_y2=([-0-9.]+)$"
)


def parse_uart(text):
    expected_count = None
    detections = []
    for raw_line in text.replace("\r", "").splitlines():
        line = raw_line.strip()
        count_match = COUNT_RE.match(line)
        if count_match:
            expected_count = int(count_match.group(1))
            continue
        detection_match = DET_RE.match(line)
        if detection_match:
            groups = detection_match.groups()
            detections.append(
                {
                    "index": int(groups[0]),
                    "class_id": int(groups[1]),
                    "class_name": groups[2],
                    "score": float(groups[3]),
                    "model_xyxy": [float(value) for value in groups[4:8]],
                    "original_xyxy": [float(value) for value in groups[8:12]],
                }
            )
    if expected_count is None:
        raise RuntimeError("UART output does not contain a DECODE count line")
    if expected_count != len(detections):
        raise RuntimeError(
            f"UART detection count mismatch: header={expected_count}, parsed={len(detections)}"
        )
    return detections


def compare_detections(actual, expected, coordinate_tolerance, score_tolerance):
    errors = []
    if len(actual) != len(expected):
        return [f"detection count got {len(actual)} expected {len(expected)}"]
    for index, (got, want) in enumerate(zip(actual, expected)):
        for key in ("index", "class_id", "class_name"):
            if got[key] != want[key]:
                errors.append(f"detection[{index}] {key} got {got[key]} expected {want[key]}")
        if abs(got["score"] - want["score"]) > score_tolerance:
            errors.append(
                f"detection[{index}] score got {got['score']:.6f} "
                f"expected {want['score']:.6f}"
            )
        for label, got_values, want_values in (
            ("model_xyxy", got["model_xyxy"], want["model_xyxy"]),
            ("original_xyxy", got["original_xyxy"], want["original_xyxy"]),
        ):
            for coordinate, (got_value, want_value) in enumerate(zip(got_values, want_values)):
                if abs(got_value - want_value) > coordinate_tolerance:
                    errors.append(
                        f"detection[{index}] {label}[{coordinate}] got {got_value:.6f} "
                        f"expected {want_value:.6f}"
                    )
    return errors


def main():
    parser = argparse.ArgumentParser(description="Compare UART YOLO detections with a JSON golden.")
    parser.add_argument("uart_log", type=Path)
    parser.add_argument("golden_json", type=Path)
    parser.add_argument("--coordinate-tolerance", type=float, default=0.1)
    parser.add_argument("--score-tolerance", type=float, default=1e-4)
    args = parser.parse_args()

    actual = parse_uart(args.uart_log.read_text(encoding="utf-8", errors="replace"))
    golden = json.loads(args.golden_json.read_text(encoding="utf-8"))
    errors = compare_detections(
        actual,
        golden["detections"],
        args.coordinate_tolerance,
        args.score_tolerance,
    )
    if errors:
        print("FAIL: UART detections do not match decode golden")
        for error in errors:
            print(f"  {error}")
        raise SystemExit(1)
    print(f"PASS: UART detections match decode golden count={len(actual)}")


if __name__ == "__main__":
    main()
