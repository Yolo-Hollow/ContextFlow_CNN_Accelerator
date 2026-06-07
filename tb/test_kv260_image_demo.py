import importlib.util
import json
import tempfile
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
PREPARE_PATH = ROOT / "tools" / "demo" / "prepare_ddr_image.py"
VISUALIZE_PATH = ROOT / "tools" / "demo" / "visualize_uart_detections.py"
PERF_PATH = ROOT / "tools" / "demo" / "summarize_uart_perf.py"
FIXTURE_IMAGE = Path(r"D:\MPSoC\python_prj\facemask\images\maksssksksss0.png")
FIXTURE_TENSOR = Path(
    r"D:\MPSoC\python_prj\rtl_golden\facemask_chain_conv0_conv4_rtl"
    r"\00_conv0_pool\ifm_u8_hwc.bin"
)


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load_module(PREPARE_PATH, "prepare_ddr_image")
visualize = load_module(VISUALIZE_PATH, "visualize_uart_detections")
perf = load_module(PERF_PATH, "summarize_uart_perf")


def main():
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary)
        package = output / "image_package.bin"
        metadata_path = output / "image_metadata.json"
        preview = output / "preview.png"
        metadata = prepare.prepare_image(
            FIXTURE_IMAGE, package, metadata_path, preview
        )
        package_bytes = package.read_bytes()
        header = prepare.PACKAGE_HEADER.unpack(
            package_bytes[: prepare.PACKAGE_HEADER_BYTES]
        )
        tensor = package_bytes[prepare.PACKAGE_HEADER_BYTES :]

        assert header[0] == prepare.PACKAGE_MAGIC
        assert header[1] == prepare.PACKAGE_VERSION
        assert header[2] == prepare.PACKAGE_HEADER_BYTES
        assert header[3] == 416 * 416 * 3
        assert header[4:6] == (512, 366)
        assert abs(header[6] - 0.8125) < 1e-6
        assert header[7:9] == (0.0, 59.0)
        assert header[9] == prepare.fnv1a32(tensor)
        assert tensor == FIXTURE_TENSOR.read_bytes()
        assert metadata["tensor_layout"] == "HWC RGB uint8"

        uart_log = output / "uart.log"
        uart_log.write_text(
            "DECODE count=1\n"
            "DET index=0 class=0 name=with_mask score=0.357321 "
            "model_x1=157.166458 model_y1=150.173492 "
            "model_x2=185.691238 model_y2=192.684204 "
            "orig_x1=193.435638 orig_y1=112.213531 "
            "orig_x2=228.543060 orig_y2=164.534409\n",
            encoding="utf-8",
        )
        rendered = output / "detections.png"
        detections_json = output / "detections.json"
        result = visualize.draw_detections(
            FIXTURE_IMAGE, uart_log, rendered, detections_json
        )
        assert rendered.is_file()
        assert Image.open(rendered).size == (512, 366)
        assert result["detection_count"] == 1
        assert json.loads(detections_json.read_text(encoding="utf-8"))[
            "detections"
        ][0]["class_name"] == "with_mask"

        summary = perf.summarize_perf(
            "PERF layer=conv0 total_us=100 "
            "ifm_pack_us=20 ifm_dma_us=30 other_us=50\n"
            "PERF layer=conv1 total_us=200 "
            "ifm_pack_us=40 ifm_dma_us=60 other_us=100\n"
            "HWPERF layer=conv0 busy_cycles=100 wait_cycles=80 "
            "nonwait_cycles=20 compute_cycles=10 bias_wait_cycles=1 "
            "weight_wait_cycles=9 ifm_wait_cycles=70 ofm_wait_cycles=0 "
            "compute_permille=100\n"
            "HWPERF layer=conv1 busy_cycles=300 wait_cycles=150 "
            "nonwait_cycles=150 compute_cycles=90 bias_wait_cycles=2 "
            "weight_wait_cycles=18 ifm_wait_cycles=130 ofm_wait_cycles=0 "
            "compute_permille=300\n"
            "DMASTAT layer=conv0 bias_starts=1 weight_starts=2 "
            "ifm_starts=3 ofm_starts=1\n"
            "DMASTAT layer=conv1 bias_starts=1 weight_starts=2 "
            "ifm_starts=3 ofm_starts=1\n"
            "VECTORSTAT layer=conv0 packets=0 pixels=0 beats=0 "
            "fifo_stall_cycles=0\n"
            "VECTORSTAT layer=conv1 packets=2 pixels=8 beats=24 "
            "fifo_stall_cycles=3\n"
        )
        assert summary["layer_count"] == 2
        assert summary["total_microseconds"] == 300
        assert summary["categories"][0]["name"] == "other_us"
        assert summary["categories"][0]["microseconds"] == 150
        assert summary["hardware"]["busy_cycles"] == 400
        assert summary["hardware"]["compute_percent"] == 25.0
        assert summary["dma"]["bias_starts"] == 2
        assert summary["dma"]["weight_starts"] == 4
        assert summary["dma"]["ifm_starts"] == 6
        assert summary["dma"]["ofm_starts"] == 2
        assert summary["vector"]["packets"] == 2
        assert summary["vector"]["pixels"] == 8
        assert summary["vector"]["beats"] == 24
        assert summary["vector"]["fifo_stall_cycles"] == 3

    print("PASS: KV260 runtime image package and visualization tests")


if __name__ == "__main__":
    main()
