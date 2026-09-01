from __future__ import annotations

import socket
import struct
import threading
import unittest

from tools.coco80.net_protocol import (
    CHUNK_RECORDS, CHUNK_TIMING_BYTES, DECODE_ACCURACY, END_BYTES,
    EXTENDED_TIMING, EXTENDED_TIMING_BYTES, EXTENDED_TIMING_MAGIC,
    EXTENDED_TIMING_VERSION,
    FLAG_ABLATION_REPRESENTATIVE, FLAG_NON_RELEASE, HELLO_BYTES,
    INPUT_PACKAGE_BYTES, MSG_HELLO, MSG_INPUT_CHUNK, MSG_RESULT_CHUNK,
    OUTPUT_DETECTIONS, REP_INPUT_MAGIC, REP_OUTPUT_MAGIC, RESULT_PREFIX,
    ChunkTiming, EndSummary, ExtendedTiming,
    NetHeader, NetProtocolError,
    binding_sha256, crc32, iter_result_records, make_header, pack_hello,
    pack_message, pack_representative_input, recv_message, send_message,
    unpack_hello, unpack_representative,
    REP_OVERRIDE_TILE,
)


SHA = {
    name: (bytes([index]) * 32).hex()
    for index, name in enumerate(("bit", "xsa", "elf", "parameter", "dataset", "quant"), 1)
}


class NetProtocolTests(unittest.TestCase):
    def binding(self) -> str:
        return binding_sha256(
            bit_sha256=SHA["bit"], xsa_sha256=SHA["xsa"],
            elf_sha256=SHA["elf"], parameter_sha256=SHA["parameter"],
            dataset_index_sha256=SHA["dataset"], quantization_sha256=SHA["quant"],
        )

    def test_hello_and_header_roundtrip(self) -> None:
        payload = pack_hello(
            flags=FLAG_NON_RELEASE, bit_sha256=SHA["bit"],
            xsa_sha256=SHA["xsa"], elf_sha256=SHA["elf"],
            parameter_sha256=SHA["parameter"], dataset_index_sha256=SHA["dataset"],
            quantization_sha256=SHA["quant"], software_build_crc32=1,
            hardware_build_crc32=2, parameter_package_bytes=18_682_508,
        )
        self.assertEqual(len(payload), HELLO_BYTES)
        self.assertEqual(unpack_hello(payload)["max_chunk_records"], CHUNK_RECORDS)
        header = make_header(
            message_type=MSG_HELLO, session_id=4, sequence=1,
            binding=self.binding(), payload=payload, flags=FLAG_NON_RELEASE,
        )
        raw = pack_message(header, payload)
        parsed = NetHeader.unpack(raw[:128])
        self.assertEqual(parsed.binding_sha256, self.binding())
        self.assertEqual(raw[128:], payload)

    def test_socket_short_reads_are_reassembled(self) -> None:
        left, right = socket.socketpair()
        payload = b"payload" * 1000
        header = make_header(
            message_type=MSG_INPUT_CHUNK, session_id=8, sequence=2,
            binding=self.binding(), payload=payload, first_record=0,
            record_count=1, output_kind=OUTPUT_DETECTIONS,
            decode_profile=DECODE_ACCURACY,
        )
        thread = threading.Thread(target=lambda: (send_message(left, header, payload), left.close()))
        thread.start()
        actual_header, actual_payload = recv_message(right)
        thread.join()
        right.close()
        self.assertEqual(actual_header.sequence, 2)
        self.assertEqual(actual_payload, payload)

    def test_representative_package_and_hello_roundtrip(self) -> None:
        flags = FLAG_NON_RELEASE | FLAG_ABLATION_REPRESENTATIVE
        hello = pack_hello(
            flags=flags, bit_sha256=SHA["bit"], xsa_sha256=SHA["xsa"],
            elf_sha256=SHA["elf"], parameter_sha256=SHA["parameter"],
            dataset_index_sha256=SHA["dataset"], quantization_sha256=SHA["quant"],
            software_build_crc32=1, hardware_build_crc32=2,
            parameter_package_bytes=18_682_508, representative=True,
        )
        self.assertTrue(unpack_hello(hello)["representative"])
        package = pack_representative_input(
            image_id=7, layer_index=6, input_mode=1, stream_config=0x29,
            ifm=b"legacy" * 100, ofm_bytes=86528,
            expected_ofm_crc32=0x12345678,
        )
        meta, payload = unpack_representative(package, expected_magic=REP_INPUT_MAGIC)
        self.assertEqual(meta["layer_index"], 6)
        self.assertEqual(payload, b"legacy" * 100)
        damaged = bytearray(package)
        damaged[-1] ^= 1
        with self.assertRaises(NetProtocolError):
            unpack_representative(bytes(damaged), expected_magic=REP_INPUT_MAGIC)
        with self.assertRaises(NetProtocolError):
            unpack_representative(package, expected_magic=REP_OUTPUT_MAGIC)

    def test_representative_custom_parameters_are_bound(self) -> None:
        package = pack_representative_input(
            image_id=8, layer_index=6, input_mode=0, stream_config=0x2B,
            ifm=b"ifm" * 64, ofm_bytes=173056, expected_ofm_crc32=0x1234,
            override_mode=REP_OVERRIDE_TILE, override_tile_h=4,
            override_kernel=3, bias=b"b" * 512, weight=b"w" * 576,
            bias_packets=4, weight_packets=1,
        )
        meta, payload = unpack_representative(
            package, expected_magic=REP_INPUT_MAGIC)
        self.assertEqual(meta["override_mode"], REP_OVERRIDE_TILE)
        self.assertEqual(meta["bias_bytes"], 512)
        self.assertEqual(payload[:192], b"ifm" * 64)
        damaged = bytearray(package)
        damaged[-1] ^= 1
        with self.assertRaises(NetProtocolError):
            unpack_representative(bytes(damaged), expected_magic=REP_INPUT_MAGIC)

    def test_header_and_payload_corruption_fail(self) -> None:
        payload = b"abc"
        header = make_header(
            message_type=MSG_INPUT_CHUNK, session_id=1, sequence=1,
            binding=self.binding(), payload=payload, record_count=1,
            output_kind=OUTPUT_DETECTIONS, decode_profile=DECODE_ACCURACY,
        )
        raw = bytearray(header.pack())
        raw[8] ^= 1
        with self.assertRaises(NetProtocolError):
            NetHeader.unpack(bytes(raw))
        wrong = bytearray(payload)
        wrong[0] ^= 1
        self.assertNotEqual(crc32(wrong), header.payload_crc32)

    def test_result_records_are_crc_and_length_bound(self) -> None:
        records = [(7, b"one"), (11, b"two-two")]
        payload = b"".join(
            RESULT_PREFIX.pack(image_id, len(data), crc32(data), 0) + data
            for image_id, data in records
        )
        self.assertEqual(list(iter_result_records(payload, 2)), records)
        damaged = bytearray(payload)
        damaged[-1] ^= 1
        with self.assertRaises(NetProtocolError):
            list(iter_result_records(bytes(damaged), 2))

    def test_contract_constants(self) -> None:
        self.assertEqual(INPUT_PACKAGE_BYTES * CHUNK_RECORDS, 66_469_888)
        self.assertEqual(RESULT_PREFIX.size, 16)
        self.assertEqual(MSG_RESULT_CHUNK, 5)

    def test_chunk_timing_roundtrip(self) -> None:
        timing = ChunkTiming(
            first_record=128, record_count=2, output_kind=OUTPUT_DETECTIONS,
            decode_profile=DECODE_ACCURACY, tick_hz=100_000_000,
            input_payload_bytes=2 * INPUT_PACKAGE_BYTES, result_payload_bytes=99,
            input_receive_ticks=10, compute_ticks=20, result_send_ticks=30,
            input_chunk_crc32=0x12345678, result_chunk_crc32=0x89ABCDEF,
            current_temp_millic=33000, max_temp_millic=34000,
        )
        raw = timing.pack()
        self.assertEqual(len(raw), CHUNK_TIMING_BYTES)
        self.assertEqual(ChunkTiming.unpack(raw, 2), timing)

    def test_end_and_extended_timing_roundtrip(self) -> None:
        end = EndSummary(
            status=0, records_received=128, records_completed=128,
            results_sent=128, error_count=0, input_crc32=1,
            result_crc32=2, parameter_crc32=3, reconnect_count=0,
            elapsed_ticks=0x123456789,
        )
        self.assertEqual(len(end.pack()), END_BYTES)
        self.assertEqual(EndSummary.unpack(end.pack()), end)
        raw = EXTENDED_TIMING.pack(
            EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION, EXTENDED_TIMING_BYTES, 7, 9,
            200_000_000, OUTPUT_DETECTIONS, DECODE_ACCURACY,
            1000, 700, 200, 100, 30, 20, 50,
            *range(13), *range(10), 4, 13, 0, 0x1234,
        )
        parsed = ExtendedTiming.unpack(raw)
        self.assertEqual(parsed.image_id, 7)
        self.assertEqual(parsed.pl_layer_ticks, tuple(range(13)))
        self.assertEqual(parsed.a53_op_ticks, tuple(range(10)))

        damaged = bytearray(raw)
        # output_crc32 remains at byte 284 in the v3 prefix; per-layer
        # telemetry follows it.
        struct.pack_into("<I", damaged, 284, 0)
        with self.assertRaises(NetProtocolError):
            ExtendedTiming.unpack(bytes(damaged))

    def test_a0_representative_timing_has_one_dispatch_and_sparse_layers(self) -> None:
        telemetry = [0] * (13 * 32)
        telemetry[0:9] = [10_000, 64, 128, 256, 2, 2, 2, 2, 2]
        raw = EXTENDED_TIMING.pack(
            EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION,
            EXTENDED_TIMING_BYTES, 9, 1, 200_000_000,
            OUTPUT_DETECTIONS, DECODE_ACCURACY,
            1000, 1000, 0, 0, 0, 0, 0,
            1000, *([0] * 12), *([0] * 10), 0, 1, 0, 0x1234,
            0x29, 13, 128, *([0] * 5), *telemetry,
        )
        parsed = ExtendedTiming.unpack(raw)
        self.assertEqual(parsed.stream_config, 0x29)
        self.assertEqual(parsed.pl_dispatches, 1)
        self.assertEqual(parsed.layer_telemetry[0].expected_contexts, 2)
        self.assertEqual(parsed.layer_telemetry[1].expected_contexts, 0)


if __name__ == "__main__":
    unittest.main()
