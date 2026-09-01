from __future__ import annotations

import argparse
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest

from PIL import Image

from tools.coco80.assets import sha256_file, write_json_atomic
from tools.coco80.net_protocol import (
    CHUNK_TIMING_BYTES, DECODE_ACCURACY, END_BYTES, EXTENDED_TIMING,
    EXTENDED_TIMING_BYTES, EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION,
    FLAG_NON_RELEASE,
    MSG_END, MSG_HELLO, MSG_INPUT_CHUNK, MSG_PARAMETERS, MSG_RESULT_CHUNK,
    MSG_RUN, MSG_STATUS, MSG_TIMING_CHUNK, OUTPUT_RAW, RESULT_PREFIX,
    ChunkTiming, EndSummary, crc32, make_header, recv_message, send_message,
)
from tools.coco80.net_runner import run_network
from tools.coco80.sd_pack import (
    P4_BYTES, P5_BYTES, build_input_shards, pack_parameter_package,
    pack_raw_heads, parse_parameter_package, validate_board_output_index,
)


class MockBoard(threading.Thread):
    def __init__(self, parameter_crc: int, raw_record: bytes, image_id: int):
        super().__init__(daemon=True)
        self.parameter_crc = parameter_crc
        self.raw_record = raw_record
        self.image_id = image_id
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.error: BaseException | None = None

    @staticmethod
    def respond(stream: socket.socket, request, kind: int, payload: bytes = b"", output: int = 0) -> None:
        header = make_header(
            message_type=kind, session_id=request.session_id,
            sequence=request.sequence, binding=request.binding_sha256,
            payload=payload, flags=FLAG_NON_RELEASE,
            first_record=request.first_record, record_count=request.record_count,
            output_kind=output, decode_profile=DECODE_ACCURACY if output else 0,
            tick_hz=200_000_000,
        )
        send_message(stream, header, payload)

    def run(self) -> None:
        try:
            stream, _ = self.listener.accept()
            with stream:
                hello, _ = recv_message(stream)
                self.assert_type(hello, MSG_HELLO, 1)
                self.respond(stream, hello, MSG_STATUS)
                params, _ = recv_message(stream)
                self.assert_type(params, MSG_PARAMETERS, 2)
                self.respond(stream, params, MSG_STATUS)
                input_header, input_payload = recv_message(stream)
                self.assert_type(input_header, MSG_INPUT_CHUNK, 3)
                self.respond(stream, input_header, MSG_STATUS)
                run_header, _ = recv_message(stream)
                self.assert_type(run_header, MSG_RUN, 4)
                result_payload = (
                    RESULT_PREFIX.pack(self.image_id, len(self.raw_record), crc32(self.raw_record), 0)
                    + self.raw_record
                )
                self.respond(stream, run_header, MSG_RESULT_CHUNK, result_payload, OUTPUT_RAW)
                timing = ChunkTiming(
                    first_record=0, record_count=1, output_kind=OUTPUT_RAW,
                    decode_profile=DECODE_ACCURACY, tick_hz=200_000_000,
                    input_payload_bytes=len(input_payload),
                    result_payload_bytes=len(result_payload),
                    input_receive_ticks=10, compute_ticks=1000,
                    result_send_ticks=50, input_chunk_crc32=crc32(input_payload),
                    result_chunk_crc32=crc32(result_payload),
                    current_temp_millic=33000, max_temp_millic=34000,
                ).pack()
                timing += EXTENDED_TIMING.pack(
                    EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION, EXTENDED_TIMING_BYTES,
                    self.image_id, 1, 200_000_000, OUTPUT_RAW, DECODE_ACCURACY,
                    1000, 700, 200, 100, 30, 20, 50,
                    *([10] * 13), *([5] * 10), 0, 13, 0, crc32(self.raw_record),
                )
                self.respond(stream, run_header, MSG_TIMING_CHUNK, timing, OUTPUT_RAW)
                end_header, end_payload = recv_message(stream)
                self.assert_type(end_header, MSG_END, 5)
                host_end = EndSummary.unpack(end_payload)
                if host_end.records_received != 1 or host_end.results_sent != 1:
                    raise AssertionError("bad host END counters")
                response = EndSummary(
                    status=0, records_received=1, records_completed=1,
                    results_sent=1, error_count=0,
                    input_crc32=crc32(input_payload), result_crc32=crc32(result_payload),
                    parameter_crc32=self.parameter_crc, reconnect_count=0,
                    elapsed_ticks=2000,
                ).pack()
                if len(response) != END_BYTES or len(timing) != CHUNK_TIMING_BYTES + EXTENDED_TIMING_BYTES:
                    raise AssertionError("protocol fixture sizes are wrong")
                self.respond(stream, end_header, MSG_END, response)
        except BaseException as exc:  # surfaced by the test thread after join
            self.error = exc
        finally:
            self.listener.close()

    @staticmethod
    def assert_type(header, expected_type: int, expected_sequence: int) -> None:
        if header.message_type != expected_type or header.sequence != expected_sequence:
            raise AssertionError((header.message_type, header.sequence))


class NetworkRunnerTests(unittest.TestCase):
    def test_one_raw_record_closes_all_hash_and_index_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / "000000000007.jpg"
            Image.new("RGB", (8, 6), (20, 30, 40)).save(image)
            inputs = root / "inputs"
            input_manifest = build_input_shards(
                [(7, image)], inputs, input_scale=1.0 / 127.0,
                input_zero_point=0, expected_count=1,
            )
            input_crc = input_manifest["entries"][0]["package"]["package_crc32"]
            parts = []
            for name, size in (
                ("weights.bin", 13 * 64), ("biases.bin", 13 * 64),
                ("luts.bin", 13 * 256), ("bindings.bin", 13 * 15 * 4),
            ):
                path = root / name; path.write_bytes(bytes(size)); parts.append(path)
            parameter = root / "parameters.c8pa"
            packed = pack_parameter_package(
                parameter, weights=parts[0], biases=parts[1],
                activation_luts=parts[2], quantization=parts[3],
                model_sha256="11" * 32,
            )
            p4 = root / "p4.bin"; p4.write_bytes(bytes(P4_BYTES))
            p5 = root / "p5.bin"; p5.write_bytes(bytes(P5_BYTES))
            raw_path = root / "raw.c8rh"
            pack_raw_heads(
                raw_path, p4=p4, p5=p5, p4_scale=0.25, p4_zero_point=1,
                p5_scale=0.5, p5_zero_point=2, input_package=input_crc,
                parameter_package=packed.package_crc32,
            )
            quant = root / "quantization_manifest.json"
            write_json_atomic(quant, {"fixture": True})
            bit = root / "r5.bit"; bit.write_bytes(b"bit")
            xsa = root / "r5.xsa"; xsa.write_bytes(b"xsa")
            elf = root / "net.elf"; elf.write_bytes(b"elf")
            runner = root / "runner.json"
            write_json_atomic(runner, {
                "format": "kv260-coco80-ethernet-runner", "version": 1,
                "development_build": True, "software_build_crc32": 12,
                "hardware_build_crc32": 13,
                "bit": {"path": str(bit), "sha256": sha256_file(bit)},
                "xsa": {"path": str(xsa), "sha256": sha256_file(xsa)},
                "elf": {"path": str(elf), "bytes": elf.stat().st_size, "sha256": sha256_file(elf)},
                "parameter_package": {"path": str(parameter), "bytes": parameter.stat().st_size, "sha256": sha256_file(parameter)},
                "quantization_manifest_sha256": sha256_file(quant),
            })
            board = MockBoard(
                parse_parameter_package(parameter)["package_crc32"],
                raw_path.read_bytes(), 7,
            )
            board.start()
            output = root / "output"
            args = argparse.Namespace(
                runner_manifest=runner, quantization_manifest=quant,
                input_index_json=inputs / "input_index.json", output_dir=output,
                mode="raw-accuracy", board_ip="127.0.0.1", port=board.port,
                start_record=0, record_count=1, chunk_records=1,
                warmup_records=0,
                connect_timeout=2.0, io_timeout=2.0, resume=False,
                allow_development=True, skip_full_input_validation=False,
            )
            summary = run_network(args)
            board.join(2)
            if board.error is not None:
                raise board.error
            self.assertEqual(summary["status"], "PASS")
            self.assertEqual((output / "raw_heads.bin").read_bytes(), raw_path.read_bytes())
            validated = validate_board_output_index(
                output / "output_index.bin", output / "raw_heads.bin"
            )
            self.assertEqual(validated["output_records"], 1)
            self.assertEqual(json.loads((output / "summary.json").read_text())["record_count"], 1)


if __name__ == "__main__":
    unittest.main()
