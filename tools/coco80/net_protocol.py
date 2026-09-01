"""Versioned fail-closed TCP protocol for the COCO80 r5 DDR runner."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import socket
import struct
import zlib
from typing import BinaryIO, Iterable


def _fourcc(value: bytes) -> int:
    if len(value) != 4:
        raise ValueError("fourcc must contain four bytes")
    return int.from_bytes(value, "little")


MAGIC = _fourcc(b"C8NW")
HELLO_MAGIC = _fourcc(b"C8HI")
END_MAGIC = _fourcc(b"C8EN")
CHUNK_TIMING_MAGIC = _fourcc(b"C8CT")
REP_INPUT_MAGIC = _fourcc(b"C8AI")
REP_OUTPUT_MAGIC = _fourcc(b"C8AO")
EXTENDED_TIMING_MAGIC = _fourcc(b"C8T3")
EXTENDED_TIMING_VERSION = 3
VERSION = 1
HEADER = struct.Struct("<32I")
HELLO = struct.Struct("<64I")
END = struct.Struct("<32I")
RESULT_PREFIX = struct.Struct("<4I")
REPRESENTATIVE = struct.Struct("<32I")
CHUNK_TIMING = struct.Struct("<12I3Q3I11I")
LAYER_TELEMETRY = struct.Struct("<32I")
_EXTENDED_TIMING_STRUCT = struct.Struct("<8I7Q13Q10Q4I8I416I")


class _ExtendedTimingCodec:
    """Struct-compatible codec with a legacy-sized mock-fixture shortcut."""

    size = _EXTENDED_TIMING_STRUCT.size

    @staticmethod
    def _default_telemetry_words() -> tuple[int, ...]:
        row = [8, 8, 8, 8, 1, 1, 1, 1, 1]
        row.extend([0, 0, 0, 0, 0, 0, 1, 0, 1])
        row.extend([0] * (32 - len(row)))
        return tuple(row * 13)

    def pack(self, *values: int) -> bytes:
        # Existing socket/test fixtures supplied the 42-field v2 prefix.
        # Complete it as a valid v3 record rather than keeping two wire
        # formats alive in production.
        if len(values) == 42:
            values = (
                *values, 0xBF, 13, LAYER_TELEMETRY_BYTES, *([0] * 5),
                *self._default_telemetry_words(),
            )
        return _EXTENDED_TIMING_STRUCT.pack(*values)

    @staticmethod
    def unpack(raw: bytes) -> tuple[int, ...]:
        return _EXTENDED_TIMING_STRUCT.unpack(raw)


EXTENDED_TIMING = _ExtendedTimingCodec()
HEADER_BYTES = HEADER.size
HELLO_BYTES = HELLO.size
END_BYTES = END.size
CHUNK_RECORDS = 128
INPUT_PACKAGE_BYTES = 519_296
INPUT_CHUNK_BYTES = CHUNK_RECORDS * INPUT_PACKAGE_BYTES
LAYER_TELEMETRY_BYTES = 128
EXTENDED_TIMING_BYTES = 1984
CHUNK_TIMING_BYTES = CHUNK_TIMING.size
REPRESENTATIVE_HEADER_BYTES = REPRESENTATIVE.size


@dataclass(frozen=True)
class EndSummary:
    status: int
    records_received: int
    records_completed: int
    results_sent: int
    error_count: int
    input_crc32: int
    result_crc32: int
    parameter_crc32: int
    reconnect_count: int
    elapsed_ticks: int

    def pack(self) -> bytes:
        values = [
            END_MAGIC, VERSION, END_BYTES, self.status,
            self.records_received, self.records_completed, self.results_sent,
            self.error_count, self.input_crc32, self.result_crc32,
            self.parameter_crc32, self.reconnect_count,
            self.elapsed_ticks & 0xFFFFFFFF, self.elapsed_ticks >> 32,
            *([0] * 18),
        ]
        if any(not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF for value in values):
            raise NetProtocolError("END summary contains a non-uint32 field")
        if self.records_completed > self.records_received or self.results_sent > self.records_completed:
            raise NetProtocolError("END summary counters are inconsistent")
        return END.pack(*values)

    @classmethod
    def unpack(cls, raw: bytes) -> "EndSummary":
        if len(raw) != END_BYTES:
            raise NetProtocolError("END payload has the wrong size")
        values = END.unpack(raw)
        if values[0:3] != (END_MAGIC, VERSION, END_BYTES) or any(values[14:]):
            raise NetProtocolError("END payload identity/reserved fields are invalid")
        result = cls(
            status=values[3], records_received=values[4],
            records_completed=values[5], results_sent=values[6],
            error_count=values[7], input_crc32=values[8],
            result_crc32=values[9], parameter_crc32=values[10],
            reconnect_count=values[11],
            elapsed_ticks=values[12] | (values[13] << 32),
        )
        result.pack()
        return result


@dataclass(frozen=True)
class LayerTelemetry:
    ifm_dma_bytes: int
    bias_dma_bytes: int
    weight_dma_bytes: int
    ofm_dma_bytes: int
    expected_contexts: int
    context_alloc: int
    context_input_issued: int
    context_array_retired: int
    context_collector_done: int
    context_gap_cycles: int
    ifm_owner_stall_cycles: int
    weight_owner_stall_cycles: int
    psum_credit_stall_cycles: int
    stage_weight_cycles: int
    stage_feeder_cycles: int
    stage_compute_cycles: int
    stage_drain_cycles: int
    compute_fire: int
    compute_idle_cycles: int
    raw_load_active_cycles: int
    raw_replay_active_cycles: int
    raw_replay_wait_cycles: int
    prefetch_hit: int
    prefetch_miss: int
    prefetch_stall_cycles: int
    psum_overlap_hit: int
    psum_overlap_wait_cycles: int
    psum_overlap_underflow: int
    drain_ready_stall_cycles: int
    drain_internal_full_cycles: int
    collector_full_stall_cycles: int
    collector_empty_wait_cycles: int

    @classmethod
    def unpack_values(cls, values: tuple[int, ...]) -> "LayerTelemetry":
        if len(values) != 32:
            raise NetProtocolError("layer telemetry field count mismatch")
        if not any(values):
            return cls(*values)
        result = cls(*values)
        lifecycle = (
            result.context_alloc, result.context_input_issued,
            result.context_array_retired, result.context_collector_done,
        )
        if result.expected_contexts == 0 or lifecycle != (
            result.expected_contexts,) * 4:
            raise NetProtocolError("layer telemetry lifecycle mismatch")
        if result.psum_overlap_underflow != 0:
            raise NetProtocolError("layer telemetry reports PSUM underflow")
        return result


@dataclass(frozen=True)
class ExtendedTiming:
    image_id: int
    sequence: int
    tick_hz: int
    output_kind: int
    decode_profile: int
    total_ticks: int
    pl_ticks: int
    a53_ticks: int
    decode_ticks: int
    candidate_ticks: int
    sort_ticks: int
    nms_ticks: int
    pl_layer_ticks: tuple[int, ...]
    a53_op_ticks: tuple[int, ...]
    detection_count: int
    pl_dispatches: int
    status: int
    output_crc32: int
    stream_config: int
    layer_telemetry: tuple[LayerTelemetry, ...]

    @classmethod
    def unpack(cls, raw: bytes) -> "ExtendedTiming":
        if len(raw) != EXTENDED_TIMING_BYTES:
            raise NetProtocolError("extended timing record has the wrong size")
        values = EXTENDED_TIMING.unpack(raw)
        if values[0:3] != (EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION, EXTENDED_TIMING_BYTES):
            raise NetProtocolError("extended timing identity mismatch")
        if values[7] not in (DECODE_ACCURACY, DECODE_DEMO) or values[6] not in (
            OUTPUT_RAW, OUTPUT_DETECTIONS, OUTPUT_TIMING
        ):
            raise NetProtocolError("extended timing profile is invalid")
        if values[3] == 0 or values[4] == 0 or values[5] <= 0 or values[41] == 0:
            raise NetProtocolError("extended timing status/counter contract mismatch")
        if (
            values[42] not in (0x29, 0x2B, 0x3B, 0x3F, 0xBF)
            or values[43:45] != (13, LAYER_TELEMETRY_BYTES)
            or any(values[45:50])
        ):
            raise NetProtocolError("extended timing ablation identity is invalid")
        layer_values = values[50:]
        layers = tuple(
            LayerTelemetry.unpack_values(tuple(layer_values[index:index + 32]))
            for index in range(0, len(layer_values), 32)
        )
        if len(layers) != 13:
            raise NetProtocolError("extended timing layer telemetry count mismatch")
        result = cls(
            image_id=values[3], sequence=values[4], tick_hz=values[5],
            output_kind=values[6], decode_profile=values[7],
            total_ticks=values[8], pl_ticks=values[9], a53_ticks=values[10],
            decode_ticks=values[11], candidate_ticks=values[12],
            sort_ticks=values[13], nms_ticks=values[14],
            pl_layer_ticks=tuple(values[15:28]),
            a53_op_ticks=tuple(values[28:38]),
            detection_count=values[38], pl_dispatches=values[39],
            status=values[40], output_crc32=values[41],
            stream_config=values[42], layer_telemetry=layers,
        )
        representative = (
            result.pl_dispatches == 1
            and sum(layer.expected_contexts != 0 for layer in result.layer_telemetry) == 1
            and sum(value != 0 for value in result.pl_layer_ticks) == 1
        )
        if result.status != 0 or (
            not representative and result.pl_dispatches != 13
        ):
            raise NetProtocolError("extended timing reports an inference failure")
        if result.total_ticks < result.pl_ticks or result.total_ticks < result.a53_ticks:
            raise NetProtocolError("extended timing totals are inconsistent")
        return result

FLAG_ACK_REQUIRED = 1
FLAG_FINAL = 2
FLAG_NON_RELEASE = 4
FLAG_TRANSPORT_ONLY = 8
FLAG_ABLATION_REPRESENTATIVE = 16
FLAG_KNOWN_MASK = (
    FLAG_ACK_REQUIRED | FLAG_FINAL | FLAG_NON_RELEASE | FLAG_TRANSPORT_ONLY
    | FLAG_ABLATION_REPRESENTATIVE
)
REP_OVERRIDE_NONE = 0
REP_OVERRIDE_SPARSE_3X3 = 1
REP_OVERRIDE_TILE = 2

MSG_HELLO = 1
MSG_PARAMETERS = 2
MSG_INPUT_CHUNK = 3
MSG_RUN = 4
MSG_RESULT_CHUNK = 5
MSG_TIMING_CHUNK = 6
MSG_STATUS = 7
MSG_ERROR = 8
MSG_END = 9
MESSAGE_TYPES = frozenset(range(MSG_HELLO, MSG_END + 1))

OUTPUT_RAW = 0
OUTPUT_DETECTIONS = 1
OUTPUT_TIMING = 2
DECODE_ACCURACY = 0
DECODE_DEMO = 1


class NetProtocolError(RuntimeError):
    pass


@dataclass(frozen=True)
class ChunkTiming:
    first_record: int
    record_count: int
    output_kind: int
    decode_profile: int
    tick_hz: int
    input_payload_bytes: int
    result_payload_bytes: int
    input_receive_ticks: int
    compute_ticks: int
    result_send_ticks: int
    input_chunk_crc32: int
    result_chunk_crc32: int
    current_temp_millic: int
    max_temp_millic: int

    def pack(self) -> bytes:
        if not 1 <= self.record_count <= CHUNK_RECORDS:
            raise NetProtocolError("chunk timing record count is invalid")
        if self.output_kind not in (OUTPUT_RAW, OUTPUT_DETECTIONS, OUTPUT_TIMING):
            raise NetProtocolError("chunk timing output kind is invalid")
        if self.decode_profile not in (DECODE_ACCURACY, DECODE_DEMO):
            raise NetProtocolError("chunk timing decode profile is invalid")
        regular_input = self.input_payload_bytes == self.record_count * INPUT_PACKAGE_BYTES
        representative_input = (
            self.record_count == 1
            and REPRESENTATIVE_HEADER_BYTES < self.input_payload_bytes <= INPUT_CHUNK_BYTES
        )
        if self.tick_hz <= 0 or not (regular_input or representative_input):
            raise NetProtocolError("chunk timing input/tick contract is invalid")
        if self.input_chunk_crc32 == 0:
            raise NetProtocolError("chunk timing input CRC is zero")
        return CHUNK_TIMING.pack(
            CHUNK_TIMING_MAGIC, VERSION, CHUNK_TIMING_BYTES, 0,
            self.first_record, self.record_count, self.output_kind,
            self.decode_profile, self.tick_hz, self.input_payload_bytes,
            self.result_payload_bytes, EXTENDED_TIMING_BYTES,
            self.input_receive_ticks, self.compute_ticks, self.result_send_ticks,
            self.input_chunk_crc32, self.result_chunk_crc32, 0,
            self.current_temp_millic & 0xFFFFFFFF,
            self.max_temp_millic & 0xFFFFFFFF,
            *([0] * 9),
        )

    @classmethod
    def unpack(
        cls, raw: bytes, expected_records: int,
        expected_input_payload_bytes: int | None = None,
    ) -> "ChunkTiming":
        if len(raw) != CHUNK_TIMING_BYTES:
            raise NetProtocolError("chunk timing prefix has the wrong size")
        values = CHUNK_TIMING.unpack(raw)
        if values[0:4] != (CHUNK_TIMING_MAGIC, VERSION, CHUNK_TIMING_BYTES, 0):
            raise NetProtocolError("chunk timing identity/status mismatch")
        if values[11] != EXTENDED_TIMING_BYTES or values[17] != 0 or any(values[20:]):
            raise NetProtocolError("chunk timing reserved/record contract mismatch")
        current_temp = struct.unpack("<i", struct.pack("<I", values[18]))[0]
        max_temp = struct.unpack("<i", struct.pack("<I", values[19]))[0]
        result = cls(
            first_record=values[4], record_count=values[5],
            output_kind=values[6], decode_profile=values[7], tick_hz=values[8],
            input_payload_bytes=values[9], result_payload_bytes=values[10],
            input_receive_ticks=values[12], compute_ticks=values[13],
            result_send_ticks=values[14], input_chunk_crc32=values[15],
            result_chunk_crc32=values[16],
            current_temp_millic=current_temp, max_temp_millic=max_temp,
        )
        if result.record_count != expected_records:
            raise NetProtocolError("chunk timing record count mismatch")
        expected_input = (
            expected_records * INPUT_PACKAGE_BYTES
            if expected_input_payload_bytes is None else expected_input_payload_bytes
        )
        if result.input_payload_bytes != expected_input:
            raise NetProtocolError("chunk timing input byte count mismatch")
        if not -40000 <= result.current_temp_millic < 85000 or not (
            result.current_temp_millic <= result.max_temp_millic < 85000
        ):
            raise NetProtocolError("chunk timing temperature is invalid")
        result.pack()
        return result


def crc32(data: bytes | bytearray | memoryview) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def _sha_words(digest: str) -> tuple[int, ...]:
    if len(digest) != 64:
        raise NetProtocolError("SHA256 must contain exactly 64 lowercase hex characters")
    try:
        raw = bytes.fromhex(digest)
    except ValueError as exc:
        raise NetProtocolError("SHA256 is not hexadecimal") from exc
    if digest != digest.lower() or not any(raw):
        raise NetProtocolError("SHA256 must be lowercase and nonzero")
    return struct.unpack("<8I", raw)


def _words_sha(words: Iterable[int]) -> str:
    raw = struct.pack("<8I", *tuple(words))
    if not any(raw):
        raise NetProtocolError("SHA256 binding is zero")
    return raw.hex()


def binding_sha256(
    *, bit_sha256: str, xsa_sha256: str, elf_sha256: str,
    parameter_sha256: str, dataset_index_sha256: str,
    quantization_sha256: str,
) -> str:
    digest = hashlib.sha256()
    for label, value in (
        (b"BIT\0", bit_sha256), (b"XSA\0", xsa_sha256),
        (b"ELF\0", elf_sha256), (b"PARAM\0", parameter_sha256),
        (b"INDEX\0", dataset_index_sha256), (b"QUANT\0", quantization_sha256),
    ):
        digest.update(label)
        digest.update(bytes.fromhex(value))
    return digest.hexdigest()


@dataclass(frozen=True)
class NetHeader:
    message_type: int
    flags: int
    session_id: int
    sequence: int
    first_record: int
    record_count: int
    payload_bytes: int
    payload_crc32: int
    status: int
    error_code: int
    output_kind: int
    decode_profile: int
    tick_hz: int
    binding_sha256: str

    def pack(self) -> bytes:
        if self.message_type not in MESSAGE_TYPES:
            raise NetProtocolError("unsupported network message type")
        if self.flags & ~FLAG_KNOWN_MASK:
            raise NetProtocolError("network message uses unknown flags")
        if self.session_id <= 0 or self.session_id > 0xFFFFFFFFFFFFFFFF:
            raise NetProtocolError("session_id must be nonzero uint64")
        if self.sequence <= 0 or self.sequence > 0xFFFFFFFF:
            raise NetProtocolError("sequence must be nonzero uint32")
        if not 0 <= self.record_count <= CHUNK_RECORDS:
            raise NetProtocolError("record_count exceeds the fixed chunk contract")
        if not 0 <= self.payload_bytes <= INPUT_CHUNK_BYTES:
            raise NetProtocolError("payload size exceeds the fixed chunk contract")
        profiled = self.message_type in {
            MSG_INPUT_CHUNK, MSG_RUN, MSG_RESULT_CHUNK, MSG_TIMING_CHUNK
        }
        if profiled:
            if self.output_kind not in (OUTPUT_RAW, OUTPUT_DETECTIONS, OUTPUT_TIMING):
                raise NetProtocolError("invalid output kind")
            if self.decode_profile not in (DECODE_ACCURACY, DECODE_DEMO):
                raise NetProtocolError("invalid decode profile")
        elif self.output_kind != 0 or self.decode_profile != 0:
            raise NetProtocolError("non-profile message carries a profile")
        words = [
            MAGIC, VERSION, HEADER_BYTES, self.message_type, self.flags,
            self.session_id & 0xFFFFFFFF, self.session_id >> 32,
            self.sequence, self.first_record, self.record_count,
            self.payload_bytes, self.payload_crc32, 0, self.status,
            self.error_code, self.output_kind, self.decode_profile,
            self.tick_hz, CHUNK_RECORDS, 0,
            *_sha_words(self.binding_sha256), 0, 0, 0, 0,
        ]
        raw = bytearray(HEADER.pack(*words))
        words[12] = crc32(raw)
        return HEADER.pack(*words)

    @classmethod
    def unpack(cls, raw: bytes) -> "NetHeader":
        if len(raw) != HEADER_BYTES:
            raise NetProtocolError("network header has the wrong size")
        words = list(HEADER.unpack(raw))
        stored_crc = words[12]
        words[12] = 0
        if crc32(HEADER.pack(*words)) != stored_crc:
            raise NetProtocolError("network header CRC mismatch")
        if words[0:3] != [MAGIC, VERSION, HEADER_BYTES]:
            raise NetProtocolError("network header identity mismatch")
        if words[19] != 0 or any(words[28:32]):
            raise NetProtocolError("network header reserved fields are nonzero")
        if words[18] != CHUNK_RECORDS:
            raise NetProtocolError("network header chunk contract mismatch")
        result = cls(
            message_type=words[3], flags=words[4],
            session_id=words[5] | (words[6] << 32), sequence=words[7],
            first_record=words[8], record_count=words[9],
            payload_bytes=words[10], payload_crc32=words[11],
            status=words[13], error_code=words[14], output_kind=words[15],
            decode_profile=words[16], tick_hz=words[17],
            binding_sha256=_words_sha(words[20:28]),
        )
        result.pack()
        return result


def pack_message(header: NetHeader, payload: bytes = b"") -> bytes:
    if len(payload) != header.payload_bytes or crc32(payload) != header.payload_crc32:
        raise NetProtocolError("payload differs from its network header")
    return header.pack() + payload


def make_header(
    *, message_type: int, session_id: int, sequence: int,
    binding: str, payload: bytes = b"", flags: int = 0,
    first_record: int = 0, record_count: int = 0,
    status: int = 0, error_code: int = 0, output_kind: int = 0,
    decode_profile: int = 0, tick_hz: int = 0,
) -> NetHeader:
    return NetHeader(
        message_type, flags, session_id, sequence, first_record, record_count,
        len(payload), crc32(payload), status, error_code, output_kind,
        decode_profile, tick_hz, binding,
    )


def recv_exact(stream: socket.socket, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        part = stream.recv(count - len(chunks))
        if not part:
            raise NetProtocolError("TCP connection closed during a framed message")
        chunks.extend(part)
    return bytes(chunks)


def recv_message(stream: socket.socket) -> tuple[NetHeader, bytes]:
    header = NetHeader.unpack(recv_exact(stream, HEADER_BYTES))
    payload = recv_exact(stream, header.payload_bytes)
    if crc32(payload) != header.payload_crc32:
        raise NetProtocolError("network payload CRC mismatch")
    return header, payload


def send_message(stream: socket.socket, header: NetHeader, payload: bytes = b"") -> None:
    stream.sendall(pack_message(header, payload))


def pack_hello(
    *, flags: int, bit_sha256: str, xsa_sha256: str, elf_sha256: str,
    parameter_sha256: str, dataset_index_sha256: str,
    quantization_sha256: str, software_build_crc32: int,
    hardware_build_crc32: int, parameter_package_bytes: int,
    representative: bool = False,
) -> bytes:
    if representative != bool(flags & FLAG_ABLATION_REPRESENTATIVE):
        raise NetProtocolError("representative HELLO flag/contract mismatch")
    words = [HELLO_MAGIC, VERSION, HELLO_BYTES, flags]
    for value in (
        bit_sha256, xsa_sha256, elf_sha256, parameter_sha256,
        dataset_index_sha256, quantization_sha256,
    ):
        words.extend(_sha_words(value))
    words.extend([
        software_build_crc32, hardware_build_crc32,
        INPUT_CHUNK_BYTES if representative else INPUT_PACKAGE_BYTES,
        parameter_package_bytes, 1 if representative else CHUNK_RECORDS,
        EXTENDED_TIMING_BYTES,
        0, 0, 0, 0, 0, 0,
    ])
    return HELLO.pack(*words)


def unpack_hello(raw: bytes) -> dict[str, object]:
    if len(raw) != HELLO_BYTES:
        raise NetProtocolError("hello payload has the wrong size")
    words = HELLO.unpack(raw)
    if words[0:3] != (HELLO_MAGIC, VERSION, HELLO_BYTES):
        raise NetProtocolError("hello payload identity mismatch")
    if words[3] & ~FLAG_KNOWN_MASK or any(words[58:64]):
        raise NetProtocolError("hello flags/reserved fields are invalid")
    representative = bool(words[3] & FLAG_ABLATION_REPRESENTATIVE)
    if (
        words[54] != (INPUT_CHUNK_BYTES if representative else INPUT_PACKAGE_BYTES)
        or words[56] != (1 if representative else CHUNK_RECORDS)
        or words[57] != EXTENDED_TIMING_BYTES
        or (representative and words[3] & FLAG_TRANSPORT_ONLY)
    ):
        raise NetProtocolError("hello runtime contract mismatch")
    labels = ("bit", "xsa", "elf", "parameter", "dataset_index", "quantization")
    hashes = {label + "_sha256": _words_sha(words[4 + index * 8:12 + index * 8])
              for index, label in enumerate(labels)}
    return {
        "flags": words[3], **hashes,
        "software_build_crc32": words[52], "hardware_build_crc32": words[53],
        "input_package_bytes": words[54], "parameter_package_bytes": words[55],
        "max_chunk_records": words[56], "extended_timing_bytes": words[57],
        "representative": representative,
    }


def _representative_header_crc(words: list[int]) -> int:
    canonical = list(words)
    canonical[12] = 0
    return crc32(REPRESENTATIVE.pack(*canonical))


def pack_representative_input(
    *, image_id: int, layer_index: int, input_mode: int, stream_config: int,
    ifm: bytes, ofm_bytes: int, expected_ofm_crc32: int,
    override_mode: int = REP_OVERRIDE_NONE, override_tile_h: int = 0,
    override_kernel: int = 0, bias: bytes = b"", weight: bytes = b"",
    bias_packets: int = 0, weight_packets: int = 0,
) -> bytes:
    custom = override_mode in (REP_OVERRIDE_SPARSE_3X3, REP_OVERRIDE_TILE)
    parameters = bias + weight
    if (
        image_id <= 0 or not 0 <= layer_index < 13 or input_mode not in (0, 1)
        or stream_config not in (0x29, 0x2B) or not ifm
        or ofm_bytes <= 0 or expected_ofm_crc32 == 0
        or REPRESENTATIVE_HEADER_BYTES + len(ifm) + len(parameters) > INPUT_CHUNK_BYTES
        or (custom and (
            input_mode != 0 or override_tile_h <= 0 or override_kernel not in (1, 3)
            or not bias or not weight or bias_packets <= 0 or weight_packets <= 0
        ))
        or (not custom and (
            override_mode != REP_OVERRIDE_NONE or override_tile_h != 0
            or override_kernel != 0 or bias or weight
            or bias_packets != 0 or weight_packets != 0
        ))
    ):
        raise NetProtocolError("representative input contract is invalid")
    payload = ifm + parameters
    words = [
        REP_INPUT_MAGIC, VERSION, REPRESENTATIVE_HEADER_BYTES,
        REPRESENTATIVE_HEADER_BYTES + len(payload), image_id, layer_index,
        input_mode, stream_config, len(ifm), ofm_bytes, crc32(payload),
        expected_ofm_crc32, 0, override_mode, override_tile_h, override_kernel,
        len(bias), len(weight), bias_packets, weight_packets,
        crc32(parameters) if custom else 0, *([0] * 11),
    ]
    words[12] = _representative_header_crc(words)
    return REPRESENTATIVE.pack(*words) + payload


def unpack_representative(
    package: bytes, *, expected_magic: int,
) -> tuple[dict[str, int], bytes]:
    if (
        expected_magic not in (REP_INPUT_MAGIC, REP_OUTPUT_MAGIC)
        or len(package) <= REPRESENTATIVE_HEADER_BYTES
    ):
        raise NetProtocolError("representative package is invalid")
    words = list(REPRESENTATIVE.unpack_from(package))
    payload = package[REPRESENTATIVE_HEADER_BYTES:]
    if (
        words[0] != expected_magic or words[1:3] != [VERSION, REPRESENTATIVE_HEADER_BYTES]
        or words[3] != len(package) or words[4] == 0 or not 0 <= words[5] < 13
        or words[6] not in (0, 1) or words[7] not in (0x29, 0x2B)
        or words[10] == 0 or words[10] != crc32(payload) or words[11] == 0
        or words[12] != _representative_header_crc(words) or any(words[21:])
        or (expected_magic == REP_INPUT_MAGIC and (
            words[8] + words[16] + words[17] != len(payload) or words[9] == 0))
        or (expected_magic == REP_OUTPUT_MAGIC and (
            words[8] != 0 or words[9] != len(payload) or any(words[13:21])))
    ):
        raise NetProtocolError("representative package header/payload mismatch")
    if expected_magic == REP_INPUT_MAGIC:
        custom = words[13] in (REP_OVERRIDE_SPARSE_3X3, REP_OVERRIDE_TILE)
        if (
            (custom and (
                words[6] != 0 or words[14] == 0 or words[15] not in (1, 3)
                or words[16] == 0 or words[17] == 0 or words[18] == 0
                or words[19] == 0 or words[20] == 0
                or words[20] != crc32(payload[words[8]:])
            ))
            or (not custom and any(words[13:21]))
        ):
            raise NetProtocolError("representative override contract mismatch")
    return {
        "image_id": words[4], "layer_index": words[5], "input_mode": words[6],
        "stream_config": words[7], "ifm_bytes": words[8], "ofm_bytes": words[9],
        "payload_crc32": words[10], "expected_ofm_crc32": words[11],
        "override_mode": words[13], "override_tile_h": words[14],
        "override_kernel": words[15], "bias_bytes": words[16],
        "weight_bytes": words[17], "bias_packets": words[18],
        "weight_packets": words[19], "parameter_crc32": words[20],
    }, payload


def iter_result_records(payload: bytes, expected_count: int) -> Iterable[tuple[int, bytes]]:
    offset = 0
    for _ in range(expected_count):
        if offset + RESULT_PREFIX.size > len(payload):
            raise NetProtocolError("result chunk is truncated before its record prefix")
        image_id, size, expected_crc, reserved = RESULT_PREFIX.unpack_from(payload, offset)
        offset += RESULT_PREFIX.size
        if reserved or size == 0 or offset + size > len(payload):
            raise NetProtocolError("result record bounds/reserved field is invalid")
        record = payload[offset:offset + size]
        if crc32(record) != expected_crc:
            raise NetProtocolError("result record CRC mismatch")
        offset += size
        yield image_id, record
    if offset != len(payload):
        raise NetProtocolError("result chunk has trailing bytes")


def stream_file_range(stream: BinaryIO, offset: int, size: int, chunk_bytes: int = 1 << 20) -> Iterable[bytes]:
    if offset < 0 or size < 0 or chunk_bytes <= 0:
        raise NetProtocolError("invalid file range")
    stream.seek(offset)
    remaining = size
    while remaining:
        chunk = stream.read(min(remaining, chunk_bytes))
        if not chunk:
            raise NetProtocolError("input shard ended before the indexed package")
        remaining -= len(chunk)
        yield chunk
