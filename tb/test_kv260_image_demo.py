import importlib.util
import json
import tempfile
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
PREPARE_PATH = ROOT / "tools" / "demo" / "prepare_ddr_image.py"
VISUALIZE_PATH = ROOT / "tools" / "demo" / "visualize_uart_detections.py"
PERF_PATH = ROOT / "tools" / "demo" / "summarize_uart_perf.py"
FIXTURE_IMAGE = ROOT / "repro" / "images" / "maksssksksss0.png"
FIXTURE_TENSOR = ROOT / "repro" / "model" / "00_conv0_pool" / "ifm_u8_hwc.bin"


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
            "STAGEPERF layer=conv0 bias_cycles=4 weight_cycles=20 "
            "feeder_cycles=30 compute_stage_cycles=40 drain_cycles=50 "
            "ofm_post_cycles=6\n"
            "STAGEPERF layer=conv1 bias_cycles=8 weight_cycles=60 "
            "feeder_cycles=90 compute_stage_cycles=120 drain_cycles=150 "
            "ofm_post_cycles=18\n"
            "SUBPERF layer=conv0 feed_fill=7 feed_push=8 "
            "feed_fifo_stall=9 feed_win_not_ready=10 comp_wload=11 "
            "comp_active=12 comp_fire=10 comp_ifm_stall=13 comp_tail=14 "
            "version=2\n"
            "SUBPERF layer=conv1 feed_fill=17 feed_push=18 "
            "feed_fifo_stall=19 feed_win_not_ready=20 comp_wload=21 "
            "comp_active=22 comp_fire=90 comp_ifm_stall=23 comp_tail=24 "
            "version=2\n"
            "TAILSTAT layer=conv0 tail_config=138 raw_start_level=64 tail_elapsed=14 "
            "drain_empty_wait=0 drain_empty_sticky=0\n"
            "TAILSTAT layer=conv1 tail_config=138 raw_start_level=64 tail_elapsed=24 "
            "drain_empty_wait=2 drain_empty_sticky=1\n"
            "RAWSTAT layer=conv0 load_active=3 load_unpack=4 "
            "replay_active=5 replay_wait_ready=0 compute_wait_ifm=0\n"
            "RAWSTAT layer=conv1 load_active=13 load_unpack=14 "
            "replay_active=15 replay_wait_ready=1 compute_wait_ifm=2\n"
            "DRAINPERF layer=conv0 read_fire=10 packet_fire=9 "
            "ready_stall=1 internal_full=2 empty_wait=0 version=1\n"
            "DRAINPERF layer=conv1 read_fire=20 packet_fire=19 "
            "ready_stall=3 internal_full=4 empty_wait=2 version=1\n"
            "PSUMOVLPERF layer=conv0 start=0 hit=0 wait_psum=0 "
            "underflow=0 version=1\n"
            "PSUMOVLPERF layer=conv1 start=10 hit=9 wait_psum=12 "
            "underflow=0 version=1\n"
            "PASSPERF layer=conv0 pass_count=2 start_to_first=6 "
            "fire_span=20 tail=4 collect_wait=8 collect_empty=3 "
            "replay_during_compute=5 compute_idle=7 version=1\n"
            "PASSPERF layer=conv1 pass_count=3 start_to_first=9 "
            "fire_span=30 tail=6 collect_wait=12 collect_empty=4 "
            "replay_during_compute=6 compute_idle=8 version=1\n"
            "PASSTRACE layer=conv1 tile=0 cout_block=1 k_pass=2 "
            "weight_done=1 feed_start=2 feed_ready=3 feed_done=4 "
            "compute_start=5 first_fire=8 last_fire=20 compute_done=22 "
            "collect_first=9 collect_last=21 pass_done=23 version=1\n"
            "COLTRACE layer=conv1 tile=0 cout_block=1 k_pass=2 col=0 "
            "first_wr=9 last_wr=20 wr_count=12 empty_wait=3 "
            "missing_or=3 missing_first=2 missing_last=1 version=1 valid=1\n"
            "COLTRACE layer=conv1 tile=0 cout_block=1 k_pass=2 col=1 "
            "first_wr=10 last_wr=21 wr_count=12 empty_wait=7 "
            "missing_or=3 missing_first=2 missing_last=1 version=1 valid=1\n"
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
        assert summary["stage"]["bias_cycles"] == 12
        assert summary["stage"]["weight_cycles"] == 80
        assert summary["stage"]["feeder_cycles"] == 120
        assert summary["stage"]["compute_stage_cycles"] == 160
        assert summary["stage"]["drain_cycles"] == 200
        assert summary["stage"]["ofm_post_cycles"] == 24
        assert summary["stage"]["total_cycles"] == 596
        assert summary["stage"]["coverage_percent"] == 149.0
        assert summary["subperf"]["feed_fill_cycles"] == 24
        assert summary["subperf"]["feed_push_cycles"] == 26
        assert summary["subperf"]["feed_fifo_stall_cycles"] == 28
        assert summary["subperf"]["feed_win_not_ready_cycles"] == 30
        assert summary["subperf"]["comp_wload_cycles"] == 32
        assert summary["subperf"]["comp_active_cycles"] == 34
        assert summary["subperf"]["comp_fire_cycles"] == 100
        assert summary["subperf"]["comp_ifm_stall_cycles"] == 36
        assert summary["subperf"]["comp_tail_cycles"] == 38
        assert summary["subperf"]["version"] == 2
        assert summary["subperf"]["feed_residual_cycles"] == 12
        assert summary["subperf"]["comp_residual_cycles"] == 56
        assert summary["tailstat"]["tail_config_cycles"] == 138
        assert summary["tailstat"]["raw_compute_start_level"] == 64
        assert summary["tailstat"]["tail_elapsed_cycles"] == 38
        assert summary["tailstat"]["drain_empty_wait_cycles"] == 2
        assert summary["tailstat"]["drain_empty_sticky"] == 1
        assert summary["rawstat"]["load_active_cycles"] == 16
        assert summary["rawstat"]["load_unpack_cycles"] == 18
        assert summary["rawstat"]["replay_active_cycles"] == 20
        assert summary["rawstat"]["replay_wait_ready_cycles"] == 1
        assert summary["rawstat"]["compute_wait_ifm_cycles"] == 2
        assert summary["drainperf"]["read_fire_cycles"] == 30
        assert summary["drainperf"]["packet_fire_cycles"] == 28
        assert summary["drainperf"]["ready_stall_cycles"] == 4
        assert summary["drainperf"]["internal_full_cycles"] == 6
        assert summary["drainperf"]["empty_wait_cycles"] == 2
        assert summary["drainperf"]["version"] == 1
        assert summary["drainperf"]["drain_residual_cycles"] == 160
        assert summary["psumovlperf"]["start_cycles"] == 10
        assert summary["psumovlperf"]["hit_cycles"] == 9
        assert summary["psumovlperf"]["wait_psum_cycles"] == 12
        assert summary["psumovlperf"]["underflow_cycles"] == 0
        assert summary["psumovlperf"]["hit_percent"] == 90.0
        assert summary["psumovlperf"]["version"] == 1
        assert summary["passperf"]["pass_count"] == 5
        assert summary["passperf"]["start_to_first_cycles"] == 15
        assert summary["passperf"]["fire_span_cycles"] == 50
        assert summary["passperf"]["tail_cycles"] == 10
        assert summary["passperf"]["collect_wait_cycles"] == 20
        assert summary["passperf"]["collect_empty_cycles"] == 7
        assert summary["passperf"]["replay_during_compute_cycles"] == 11
        assert summary["passperf"]["compute_idle_cycles"] == 15
        assert summary["passperf"]["avg_start_to_first"] == 3.0
        assert summary["passperf"]["avg_collect_wait"] == 4.0
        assert summary["passperf"]["fire_density_percent"] == 200.0
        assert summary["passperf"]["compute_util_percent"] == 62.5
        assert summary["passtrace"][0]["layer"] == "conv1"
        assert summary["passtrace"][0]["pass_done"] == 23
        assert summary["coltrace"]["total_empty_wait"] == 10
        assert summary["coltrace"]["worst_layer"] == "conv1"
        assert summary["coltrace"]["worst_col"] == 1
        assert summary["coltrace"]["max_empty_wait"] == 7
        assert summary["coltrace"]["columns"][0]["wr_count"] == 12

    print("PASS: KV260 runtime image package and visualization tests")


if __name__ == "__main__":
    main()
