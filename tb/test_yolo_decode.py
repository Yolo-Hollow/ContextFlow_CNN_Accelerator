import importlib.util
import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DECODE_PATH = ROOT / "tools" / "golden" / "yolo_single_scale_decode.py"
COMPARE_PATH = ROOT / "tools" / "golden" / "compare_yolo_uart.py"
C_SOURCE = ROOT / "sw" / "vitis_2022_2" / "src" / "yolo_decode.c"
C_INCLUDE = ROOT / "sw" / "vitis_2022_2" / "src"
C_UNIT = ROOT / "tb" / "test_yolo_decode_c.c"
C_HOST = ROOT / "tb" / "yolo_decode_host.c"
TENSOR = ROOT / "repro" / "expected" / "conv9_golden_ofm_u8_hwc.bin"
GOLDEN = ROOT / "repro" / "expected" / "decode_golden.json"
GCC = Path(r"C:\msys64\ucrt64\bin\gcc.exe")


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


decode = load_module(DECODE_PATH, "yolo_single_scale_decode")


def run(command):
    subprocess.run(command, check=True)


def main():
    tensor = bytearray(decode.GRID_H * decode.GRID_W * decode.CHANNELS)
    base = ((2 * decode.GRID_W + 3) * decode.CHANNELS) + decode.VALUES_PER_ANCHOR
    tensor[base:base + decode.VALUES_PER_ANCHOR] = bytes(
        [80, 80, 80, 80, 100, 0, 100, 0]
    )
    synthetic = decode.decode_hwc(tensor)
    assert len(synthetic) == 1
    assert synthetic[0].class_id == 1
    assert synthetic[0].source_index == (2 * decode.GRID_W + 3) * 3 + 1

    same_class = [
        decode.Detection(0, 0, 100, 100, 0.9, 0, 2),
        decode.Detection(2, 2, 98, 98, 0.8, 0, 1),
        decode.Detection(2, 2, 98, 98, 0.7, 1, 0),
    ]
    kept = decode.class_aware_nms(same_class, 0.45)
    assert len(kept) == 2
    assert [item.class_id for item in kept] == [0, 1]

    result = decode.export_decode_golden(TENSOR, GOLDEN, 0.25, 0.45)
    assert result["detection_count"] == 1
    assert result["detections"][0]["class_name"] == "with_mask"

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        unit_exe = tmp_path / "test_yolo_decode_c.exe"
        host_exe = tmp_path / "yolo_decode_host.exe"
        host_log = tmp_path / "host_uart.log"

        run([
            str(GCC), "-std=c99", "-Wall", "-Wextra", "-Werror",
            "-I", str(C_INCLUDE), str(C_SOURCE), str(C_UNIT), "-lm", "-o", str(unit_exe),
        ])
        run([str(unit_exe)])
        run([
            str(GCC), "-std=c99", "-Wall", "-Wextra", "-Werror",
            "-I", str(C_INCLUDE), str(C_SOURCE), str(C_HOST), "-lm", "-o", str(host_exe),
        ])
        completed = subprocess.run([str(host_exe), str(TENSOR)], check=True, text=True, capture_output=True)
        host_log.write_text(completed.stdout, encoding="utf-8")
        run([
            "python", str(COMPARE_PATH), str(host_log), str(GOLDEN),
            "--coordinate-tolerance", "0.1", "--score-tolerance", "0.0001",
        ])

    print("PASS: Python and host C YOLO decode tests")


if __name__ == "__main__":
    main()
