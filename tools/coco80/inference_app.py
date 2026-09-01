"""Local upload-to-KV260 COCO80 inference web application.

The application deliberately reuses the versioned C8IN package builder and
the fail-closed Ethernet runner.  It does not provide a host-model fallback:
if the board, its artifacts, or the TCP response cannot be verified, the HTTP
request fails instead of displaying a synthetic result.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
import json
import math
import os
from pathlib import Path
import re
import socket
import threading
import time
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import unquote, urlparse

from PIL import Image, UnidentifiedImageError

from .assets import sha256_file, write_json_atomic
from .common import coco_class_name
from .net_protocol import EXTENDED_TIMING_BYTES, ExtendedTiming, NetProtocolError
from .net_runner import NetworkRunnerError, run_network
from .sd_pack import SdPackError, build_input_shards, iter_detection_records
from .visualize import VisualizationError, render as render_visualization


APP_FORMAT = "kv260-coco80-inference-app-result"
APP_VERSION = 1
DEFAULT_WEB_PORT = 8088
MAX_UPLOAD_BYTES = 20 * 1024 * 1024
MAX_SOURCE_PIXELS = 50_000_000
MAX_SOURCE_DIMENSION = 16_384
LAYER_NAMES = (
    "m0", "m2", "m4", "m6", "m8", "m10", "m13", "m14", "m15",
    "m16", "m19", "p4_detect", "p5_detect",
)
A53_NAMES = (
    "pool1", "pool3", "pool5", "pool7", "pool9", "pool12",
    "upsample17", "requant_concat18", "p5_copy", "reserved",
)
PROFILE_MODES = {"demo": "detections-demo", "accuracy": "detections-accuracy"}
STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
}
IMAGE_TYPES = {"JPEG": ".jpg", "PNG": ".png", "WEBP": ".webp", "BMP": ".bmp"}
RUN_PATH = re.compile(r"^/runs/([0-9TZ_a-f-]+)/(source\.(?:jpg|png|webp|bmp)|visualization\.jpg|result\.json)$")


class InferenceAppError(RuntimeError):
    """A request cannot be served without weakening the deployment contract."""

    def __init__(self, message: str, status: int = HTTPStatus.BAD_REQUEST):
        super().__init__(message)
        self.status = int(status)


@dataclass(frozen=True)
class AppConfig:
    runner_manifest: Path
    quantization_manifest: Path
    output_root: Path
    board_ip: str = "192.168.10.2"
    board_port: int = 5001
    connect_timeout: float = 10.0
    io_timeout: float = 600.0
    allow_development: bool = False
    max_upload_bytes: int = MAX_UPLOAD_BYTES


def _json_file(path: Path, label: str) -> dict[str, Any]:
    target = path.resolve()
    if target.is_symlink() or not target.is_file():
        raise InferenceAppError(f"{label}不存在或不是普通文件：{target}")
    try:
        value = json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise InferenceAppError(f"无法读取{label}：{exc}") from exc
    if not isinstance(value, dict):
        raise InferenceAppError(f"{label}必须包含一个JSON对象")
    return value


def read_input_qparams(path: Path) -> dict[str, Any]:
    """Return the canonical reduced-u8 input domain from m0."""

    data = _json_file(path, "量化manifest")
    if data.get("format") != "kv260-coco80-rtl-quantization":
        raise InferenceAppError("量化manifest格式不受支持")
    layers = data.get("layers")
    if not isinstance(layers, list) or len(layers) != 13 or layers[0].get("name") != "m0":
        raise InferenceAppError("量化manifest缺少固定13层/m0合同")
    quant = layers[0].get("quant")
    input_quant = quant.get("input") if isinstance(quant, Mapping) else None
    if not isinstance(input_quant, Mapping):
        raise InferenceAppError("m0缺少输入量化参数")
    scale = input_quant.get("scale")
    zero_point = input_quant.get("zero_point")
    if (
        isinstance(scale, bool) or not isinstance(scale, (int, float))
        or not math.isfinite(float(scale)) or float(scale) <= 0.0
        or isinstance(zero_point, bool) or not isinstance(zero_point, int)
        or input_quant.get("qmin") != 0 or input_quant.get("qmax") != 127
        or not 0 <= zero_point <= 127
    ):
        raise InferenceAppError("m0输入不是硬件要求的uint8 reduced-range量化域")
    return {"scale": float(scale), "zero_point": zero_point}


def validate_uploaded_image(payload: bytes) -> dict[str, Any]:
    if not payload:
        raise InferenceAppError("上传内容为空")
    try:
        with Image.open(BytesIO(payload)) as image:
            image_format = str(image.format or "").upper()
            width, height = image.size
            if image_format not in IMAGE_TYPES:
                raise InferenceAppError("仅支持JPEG、PNG、WebP或BMP图像")
            if (
                width <= 0 or height <= 0
                or width > MAX_SOURCE_DIMENSION or height > MAX_SOURCE_DIMENSION
                or width * height > MAX_SOURCE_PIXELS
            ):
                raise InferenceAppError("图像尺寸超过安全限制")
            image.verify()
    except InferenceAppError:
        raise
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise InferenceAppError(f"无法解码上传图像：{exc}") from exc
    return {
        "format": image_format,
        "extension": IMAGE_TYPES[image_format],
        "width": width,
        "height": height,
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def timing_to_dict(timing: ExtendedTiming) -> dict[str, Any]:
    def microseconds(ticks: int) -> float:
        return ticks * 1_000_000.0 / timing.tick_hz

    return {
        "tick_hz": timing.tick_hz,
        "resident_ms": microseconds(timing.total_ticks) / 1000.0,
        "pl_ms": microseconds(timing.pl_ticks) / 1000.0,
        "a53_ms": microseconds(timing.a53_ticks) / 1000.0,
        "decode_ms": microseconds(timing.decode_ticks) / 1000.0,
        "candidate_ms": microseconds(timing.candidate_ticks) / 1000.0,
        "sort_ms": microseconds(timing.sort_ticks) / 1000.0,
        "nms_ms": microseconds(timing.nms_ticks) / 1000.0,
        "pl_layers_ms": {
            name: microseconds(timing.pl_layer_ticks[index]) / 1000.0
            for index, name in enumerate(LAYER_NAMES)
        },
        "a53_ops_ms": {
            name: microseconds(timing.a53_op_ticks[index]) / 1000.0
            for index, name in enumerate(A53_NAMES)
            if name != "reserved"
        },
        "detection_count": timing.detection_count,
        "pl_dispatches": timing.pl_dispatches,
        "output_crc32": f"{timing.output_crc32:08x}",
    }


def _safe_filename(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", Path(value).name).strip("._")
    return cleaned[:120] or "upload"


class BoardInferenceService:
    """Serialize access to the single persistent bare-metal TCP endpoint."""

    def __init__(
        self,
        config: AppConfig,
        *,
        network_runner: Callable[[argparse.Namespace], dict[str, Any]] = run_network,
    ) -> None:
        self.config = config
        self.network_runner = network_runner
        self._board_lock = threading.Lock()
        self._started = time.time()
        self.web_root = Path(__file__).with_name("inference_app_web").resolve()
        self.runs_root = config.output_root.resolve() / "runs"
        self.runs_root.mkdir(parents=True, exist_ok=True)

    def status(self, *, probe: bool = False) -> dict[str, Any]:
        runner = _json_file(self.config.runner_manifest, "runner manifest")
        qparams = read_input_qparams(self.config.quantization_manifest)
        local_errors: list[str] = []
        if runner.get("format") != "kv260-coco80-ethernet-runner" or runner.get("version") != 1:
            local_errors.append("runner manifest格式/版本错误")
        if runner.get("development_build") and not self.config.allow_development:
            local_errors.append("development runner未显式授权")
        if runner.get("quantization_manifest_sha256") != sha256_file(self.config.quantization_manifest):
            local_errors.append("runner与量化manifest哈希不一致")

        artifact_rows: list[tuple[str, Any]] = [
            ("BIT", runner.get("bit")), ("XSA", runner.get("xsa")),
            ("ELF", runner.get("elf")), ("参数包", runner.get("parameter_package")),
        ]
        multicore = runner.get("multicore")
        workers = multicore.get("workers") if isinstance(multicore, Mapping) else None
        if not isinstance(workers, list) or len(workers) != 3:
            local_errors.append("runner缺少3个A53 worker")
        else:
            artifact_rows.extend((f"A53 worker {index}", row) for index, row in enumerate(workers, 1))
        for label, metadata in artifact_rows:
            if not isinstance(metadata, Mapping):
                local_errors.append(f"{label}元数据缺失")
                continue
            artifact = Path(str(metadata.get("path", ""))).resolve()
            digest = metadata.get("sha256")
            expected_bytes = metadata.get("bytes")
            if artifact.is_symlink() or not artifact.is_file():
                local_errors.append(f"{label}文件缺失")
            elif not isinstance(digest, str) or sha256_file(artifact) != digest:
                local_errors.append(f"{label}哈希漂移")
            elif expected_bytes is not None and artifact.stat().st_size != expected_bytes:
                local_errors.append(f"{label}长度漂移")
        local_ready = not local_errors
        board_reachable: bool | None = None
        board_error = ""
        if probe:
            try:
                with socket.create_connection(
                    (self.config.board_ip, self.config.board_port), timeout=1.0
                ):
                    board_reachable = True
            except OSError as exc:
                board_reachable = False
                board_error = str(exc)
        return {
            "status": "READY" if local_ready else "BLOCKED",
            "local_ready": local_ready,
            "local_errors": local_errors,
            "board": {
                "ip": self.config.board_ip,
                "port": self.config.board_port,
                "reachable": board_reachable,
                "error": board_error,
            },
            "model": {
                "classes": 80,
                "input": "416x416 RGB / INT8",
                "profile": "current deployed epoch1",
                "development_build": bool(runner.get("development_build")),
                "release_eligible": bool(runner.get("release_eligible")),
                "bit_sha256": runner.get("bit", {}).get("sha256"),
                "elf_sha256": runner.get("elf", {}).get("sha256"),
                "quantization_sha256": runner.get("quantization_manifest_sha256"),
                "input_scale": qparams["scale"],
                "input_zero_point": qparams["zero_point"],
            },
            "busy": self._board_lock.locked(),
            "uptime_seconds": time.time() - self._started,
        }

    def infer(
        self,
        payload: bytes,
        *,
        filename: str,
        profile: str,
        display_confidence: float,
    ) -> dict[str, Any]:
        if profile not in PROFILE_MODES:
            raise InferenceAppError("profile必须是demo或accuracy")
        if not math.isfinite(display_confidence) or not 0.0 <= display_confidence <= 1.0:
            raise InferenceAppError("显示置信度必须在0到1之间")
        if len(payload) > self.config.max_upload_bytes:
            raise InferenceAppError("上传文件超过20 MiB限制", HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
        image_info = validate_uploaded_image(payload)
        if not self._board_lock.acquire(blocking=False):
            raise InferenceAppError("开发板正在处理另一张图片，请稍后重试", HTTPStatus.CONFLICT)
        started_ns = time.perf_counter_ns()
        request_id = ""
        run_dir: Path | None = None
        try:
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
            request_id = f"{stamp}_{image_info['sha256'][:10]}"
            run_dir = self.runs_root / request_id
            run_dir.mkdir(parents=False, exist_ok=False)
            source = run_dir / ("source" + image_info["extension"])
            with source.open("xb") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())

            qparams = read_input_qparams(self.config.quantization_manifest)
            image_id = int(image_info["sha256"][:8], 16) or 1
            package_started = time.perf_counter_ns()
            input_root = run_dir / "input"
            input_manifest = build_input_shards(
                [(image_id, source)],
                input_root,
                input_scale=qparams["scale"],
                input_zero_point=qparams["zero_point"],
                expected_count=1,
                shard_target_bytes=520_000,
            )
            package_ms = (time.perf_counter_ns() - package_started) / 1e6

            network_output = run_dir / "board"
            network_args = argparse.Namespace(
                runner_manifest=self.config.runner_manifest,
                quantization_manifest=self.config.quantization_manifest,
                input_index_json=input_root / "input_index.json",
                selection_index_bin=None,
                output_dir=network_output,
                mode=PROFILE_MODES[profile],
                board_ip=self.config.board_ip,
                port=self.config.board_port,
                start_record=0,
                record_count=1,
                warmup_records=0,
                chunk_records=1,
                connect_timeout=self.config.connect_timeout,
                io_timeout=self.config.io_timeout,
                resume=False,
                allow_development=self.config.allow_development,
                skip_full_input_validation=False,
            )
            network_started = time.perf_counter_ns()
            network_summary = self.network_runner(network_args)
            network_ms = (time.perf_counter_ns() - network_started) / 1e6
            if network_summary.get("status") != "PASS":
                raise InferenceAppError("板端runner未返回PASS", HTTPStatus.BAD_GATEWAY)

            detection_path = network_output / "detections.bin"
            detections = list(iter_detection_records(detection_path))
            if any(int(item["image_id"]) != image_id for item in detections):
                raise InferenceAppError("板端检测结果image_id不匹配", HTTPStatus.BAD_GATEWAY)
            timing_raw = (network_output / "extended_timing.bin").read_bytes()
            if len(timing_raw) != EXTENDED_TIMING_BYTES:
                raise InferenceAppError("板端逐图计时记录长度错误", HTTPStatus.BAD_GATEWAY)
            timing = ExtendedTiming.unpack(timing_raw)
            if timing.image_id != image_id or timing.detection_count != len(detections):
                raise InferenceAppError("板端计时与检测结果不一致", HTTPStatus.BAD_GATEWAY)

            predictions = [
                {
                    "image_id": image_id,
                    "category_id": int(item["category_id"]),
                    "bbox": [
                        float(item["x1"]), float(item["y1"]),
                        float(item["x2"] - item["x1"]),
                        float(item["y2"] - item["y1"]),
                    ],
                    "score": float(item["score"]),
                }
                for item in detections
            ]
            predictions_path = run_dir / "predictions.json"
            write_json_atomic(predictions_path, predictions)
            visualization = run_dir / "visualization.jpg"
            render_started = time.perf_counter_ns()
            render_visualization(argparse.Namespace(
                predictions=predictions_path,
                image_id=image_id,
                image=source,
                annotations=None,
                image_root=None,
                output=visualization,
                confidence=display_confidence,
                max_boxes=300,
                title=f"KV260 r5 COCO80 | {profile} | {len(detections)} detections",
                overwrite=False,
            ))
            render_ms = (time.perf_counter_ns() - render_started) / 1e6

            public_detections = [
                {
                    **{key: value for key, value in item.items() if key != "image_id"},
                    "class_name": coco_class_name(int(item["class_id"])),
                }
                for item in detections
            ]
            chunk = network_summary["chunks"][0]
            board_chunk = chunk.get("board") or {}
            timing_result = timing_to_dict(timing)
            timing_result["host"] = {
                "preprocess_package_ms": package_ms,
                "network_session_ms": network_ms,
                "network_chunk_ms": float(chunk["host_wall_seconds"]) * 1000.0,
                "visualization_ms": render_ms,
                "request_total_ms": (time.perf_counter_ns() - started_ns) / 1e6,
            }
            timing_result["transport"] = {
                "input_bytes": int(chunk["input_bytes"]),
                "result_bytes": int(chunk["result_bytes"]),
                "board_current_temp_c": float(board_chunk.get("current_temp_millic", 0)) / 1000.0,
                "board_max_temp_c": float(board_chunk.get("max_temp_millic", 0)) / 1000.0,
            }

            result = {
                "format": APP_FORMAT,
                "version": APP_VERSION,
                "status": "PASS",
                "request_id": request_id,
                "created_utc": datetime.now(timezone.utc).isoformat(),
                "profile": profile,
                "display_confidence": display_confidence,
                "image": {
                    **image_info,
                    "original_filename": _safe_filename(filename),
                    "image_id": image_id,
                },
                "detections": public_detections,
                "timing": timing_result,
                "artifacts": {
                    "source_url": f"/runs/{request_id}/{source.name}",
                    "visualization_url": f"/runs/{request_id}/visualization.jpg",
                    "result_url": f"/runs/{request_id}/result.json",
                    "visualization_sha256": sha256_file(visualization),
                    "runner_binding_sha256": network_summary["binding_sha256"],
                    "input_index_sha256": network_summary["artifacts"]["input_index"]["sha256"],
                    "board_output_sha256": network_summary["artifacts"]["results"]["sha256"],
                    "timing_sha256": network_summary["artifacts"]["timing"]["sha256"],
                },
                "network": {
                    "board_ip": self.config.board_ip,
                    "board_port": self.config.board_port,
                    "session_id": network_summary["session_id"],
                    "end": network_summary["end"],
                },
            }
            write_json_atomic(run_dir / "result.json", result)
            return result
        except InferenceAppError:
            raise
        except (
            NetworkRunnerError, NetProtocolError, SdPackError,
            VisualizationError, OSError, ValueError,
        ) as exc:
            if run_dir is not None:
                write_json_atomic(run_dir / "error.json", {
                    "format": APP_FORMAT + ".error",
                    "version": APP_VERSION,
                    "request_id": request_id,
                    "error": str(exc),
                })
            raise InferenceAppError(f"板端推理失败：{exc}", HTTPStatus.BAD_GATEWAY) from exc
        finally:
            self._board_lock.release()


def make_handler(service: BoardInferenceService) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "KV260InferenceApp/1"

        def _headers(self, status: int, content_type: str, length: int) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cache-Control", "no-store")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; img-src 'self' blob: data:; "
                "style-src 'self'; script-src 'self'; connect-src 'self'",
            )
            self.end_headers()

        def _json(self, status: int, value: Mapping[str, Any]) -> None:
            payload = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
            self._headers(status, "application/json; charset=utf-8", len(payload))
            self.wfile.write(payload)

        def _file(self, path: Path, content_type: str) -> None:
            if path.is_symlink() or not path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            payload = path.read_bytes()
            self._headers(HTTPStatus.OK, content_type, len(payload))
            self.wfile.write(payload)

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            parsed = urlparse(self.path)
            if parsed.path in ("/", "/index.html"):
                self._file(service.web_root / "index.html", STATIC_TYPES[".html"])
                return
            if parsed.path in ("/app.js", "/style.css"):
                path = service.web_root / parsed.path.removeprefix("/")
                self._file(path, STATIC_TYPES[path.suffix])
                return
            if parsed.path == "/api/status":
                probe = parsed.query in ("probe=1", "probe=true")
                try:
                    self._json(HTTPStatus.OK, service.status(probe=probe))
                except InferenceAppError as exc:
                    self._json(exc.status, {"status": "ERROR", "error": str(exc)})
                return
            match = RUN_PATH.fullmatch(parsed.path)
            if match:
                path = service.runs_root / match.group(1) / match.group(2)
                suffix = path.suffix.lower()
                content_type = "application/json; charset=utf-8" if suffix == ".json" else (
                    "image/png" if suffix == ".png" else "image/webp" if suffix == ".webp"
                    else "image/bmp" if suffix == ".bmp" else "image/jpeg"
                )
                self._file(path, content_type)
                return
            self.send_error(HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            if urlparse(self.path).path != "/api/infer":
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            raw_length = self.headers.get("Content-Length")
            try:
                length = int(raw_length or "")
            except ValueError:
                length = -1
            if length <= 0:
                self._json(HTTPStatus.LENGTH_REQUIRED, {"status": "ERROR", "error": "缺少有效Content-Length"})
                return
            if length > service.config.max_upload_bytes:
                self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"status": "ERROR", "error": "上传文件超过20 MiB限制"})
                return
            payload = self.rfile.read(length)
            if len(payload) != length:
                self._json(HTTPStatus.BAD_REQUEST, {"status": "ERROR", "error": "上传内容被截断"})
                return
            filename = unquote(self.headers.get("X-File-Name", "upload"))
            profile = self.headers.get("X-Decode-Profile", "demo").lower()
            try:
                confidence = float(self.headers.get("X-Display-Confidence", "0.25"))
                result = service.infer(
                    payload, filename=filename, profile=profile,
                    display_confidence=confidence,
                )
                self._json(HTTPStatus.OK, result)
            except InferenceAppError as exc:
                self._json(exc.status, {"status": "ERROR", "error": str(exc)})
            except Exception as exc:  # pragma: no cover - last-resort HTTP isolation
                self.log_error("unhandled inference error: %r", exc)
                self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"status": "ERROR", "error": "服务内部错误"})

        def log_message(self, fmt: str, *args: object) -> None:
            print(f"[{self.log_date_time_string()}] {self.address_string()} {fmt % args}")

    return Handler


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner-manifest", type=Path, required=True)
    parser.add_argument("--quantization-manifest", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, default=Path("results/coco80/inference_app"))
    parser.add_argument("--board-ip", default="192.168.10.2")
    parser.add_argument("--board-port", type=int, default=5001)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_WEB_PORT)
    parser.add_argument("--connect-timeout", type=float, default=10.0)
    parser.add_argument("--io-timeout", type=float, default=600.0)
    parser.add_argument("--allow-development", action="store_true")
    parser.add_argument("--open-browser", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    config = AppConfig(
        runner_manifest=args.runner_manifest.resolve(),
        quantization_manifest=args.quantization_manifest.resolve(),
        output_root=args.output_root.resolve(),
        board_ip=args.board_ip,
        board_port=args.board_port,
        connect_timeout=args.connect_timeout,
        io_timeout=args.io_timeout,
        allow_development=args.allow_development,
    )
    service = BoardInferenceService(config)
    status = service.status(probe=False)
    if status["status"] != "READY":
        raise SystemExit("inference app artifact contract is blocked")
    server = ThreadingHTTPServer((args.host, args.port), make_handler(service))
    url = f"http://{args.host}:{args.port}/"
    print(json.dumps({"status": "READY", "url": url, "board": f"{args.board_ip}:{args.board_port}"}, ensure_ascii=False))
    if args.open_browser:
        import webbrowser
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
