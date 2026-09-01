"""Fail-closed COCO80 YOLOv3-tiny schedule for the ABI-v2 r5 hardware.

The table in this module describes convolution dispatches, not every graph
node.  The four unbranched early 2x2/stride-2 pools are fused into the existing
r5 post-activation PL pool.  The route-producing m8 pool, special padded m10
pool, upsample, route requant/concat, decode and NMS remain explicit A53 graph
nodes.

All capacity formulae mirror ``systolic/layer_config_regs.v``.  Keeping them
in one small, dependency-free module lets the parameter packer and host tests
bind to exactly the same physical contract.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from types import MappingProxyType
from typing import Iterable, Mapping, Sequence


HARDWARE_PLAN_MAGIC = "kv260-coco80-yolov3-tiny-hardware-plan"
HARDWARE_PLAN_VERSION = 2

ROWS = 18
COLS = 16
COUT_TILE = 32
BIAS_PACKET_BYTES = COUT_TILE * 4
WEIGHT_PACKET_BYTES = ROWS * COUT_TILE
DMA_SIMPLE_LENGTH_BITS = 26
DMA_SIMPLE_MAX_LENGTH = 1 << DMA_SIMPLE_LENGTH_BITS
PARAMETER_ALIGNMENT = 64
BIAS_WINDOW_BYTES = 64 * 1024
WEIGHT_WINDOW_BYTES = 20 * 1024 * 1024

EXPECTED_LAYER_COUNT = 13
EXPECTED_BIAS_PACKAGE_BYTES = 64_256
EXPECTED_WEIGHT_PACKAGE_BYTES = 18_614_016


class PlanValidationError(ValueError):
    """The requested graph cannot be represented by the r5 release ABI."""


@dataclass(frozen=True)
class HardwareLimits:
    rows: int = ROWS
    cols: int = COLS
    cout_tile: int = COUT_TILE
    fm_h_max: int = 416
    fm_w_max: int = 416
    max_channels: int = 1024
    max_k_total: int = (1 << 14) - 1
    max_passes: int = 512
    psum_depth: int = 1024
    materialized_depth: int = 32768
    packed_reorder_depth: int = 4096
    line_bank_depth: int = 2048
    ifm_fifo_depth: int = 1024
    dma_max_length: int = DMA_SIMPLE_MAX_LENGTH
    bias_window_bytes: int = BIAS_WINDOW_BYTES
    weight_window_bytes: int = WEIGHT_WINDOW_BYTES


R5_LIMITS = HardwareLimits()


@dataclass(frozen=True)
class ConvLayer:
    """One physical convolution dispatch in graph execution order."""

    layer_id: str
    model_index: int
    detect_index: int | None
    input_tensor: str
    output_tensor: str
    fm_h: int
    fm_w: int
    cin: int
    cout: int
    kernel: int
    stride: int
    pad: int
    pool_stride: int
    tile_h: int
    activation_mode: int = 2

    @property
    def native_1x1(self) -> bool:
        return self.kernel == 1


@dataclass(frozen=True)
class LayerSchedule:
    layer: ConvLayer
    conv_h: int
    conv_w: int
    output_h: int
    output_w: int
    k_total: int
    k_passes: int
    cout_blocks: int
    cout_tail_channels: int
    tile_count: int
    last_tile_h: int
    max_tile_pixels: int
    max_tile_output_pixels: int
    materialized_entries: int
    packed_reorder_entries: int
    line_words: int
    ifm_bytes: int
    ofm_bytes: int
    bias_packets: int
    weight_packets: int
    bias_bytes: int
    weight_bytes: int

    @property
    def expected_contexts(self) -> int:
        return self.weight_packets


@dataclass(frozen=True)
class PlanSummary:
    layer_count: int
    total_ifm_bytes: int
    total_ofm_bytes: int
    total_bias_packets: int
    total_weight_packets: int
    total_bias_bytes: int
    total_weight_bytes: int
    max_bias_transfer_bytes: int
    max_weight_transfer_bytes: int
    max_ifm_transfer_bytes: int
    max_ofm_transfer_bytes: int
    max_materialized_entries: int
    max_packed_reorder_entries: int
    max_line_words: int


@dataclass(frozen=True)
class HardwarePlan:
    magic: str
    version: int
    limits: HardwareLimits
    layers: tuple[LayerSchedule, ...]
    summary: PlanSummary

    def to_manifest(self) -> dict[str, object]:
        return {
            "magic": self.magic,
            "version": self.version,
            "array": {
                "rows": self.limits.rows,
                "cols": self.limits.cols,
                "cout_tile": self.limits.cout_tile,
            },
            "limits": asdict(self.limits),
            "layers": [
                {
                    "layer": asdict(schedule.layer),
                    "schedule": {
                        key: value
                        for key, value in asdict(schedule).items()
                        if key != "layer"
                    },
                }
                for schedule in self.layers
            ],
            "summary": asdict(self.summary),
        }

    def sha256(self) -> str:
        payload = json.dumps(
            self.to_manifest(), sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()


def _layer(
    layer_id: str,
    model_index: int,
    input_tensor: str,
    output_tensor: str,
    fm_h: int,
    fm_w: int,
    cin: int,
    cout: int,
    kernel: int,
    tile_h: int,
    *,
    pool_stride: int = 0,
    detect_index: int | None = None,
) -> ConvLayer:
    return ConvLayer(
        layer_id=layer_id,
        model_index=model_index,
        detect_index=detect_index,
        input_tensor=input_tensor,
        output_tensor=output_tensor,
        fm_h=fm_h,
        fm_w=fm_w,
        cin=cin,
        cout=cout,
        kernel=kernel,
        stride=1,
        pad=1 if kernel == 3 else 0,
        pool_stride=pool_stride,
        tile_h=tile_h,
    )


# This is a release contract, rather than a tile-height search result.  Early
# layers retain their board-proven heights.  Route-producing layers use larger
# legal tiles to keep the repeated parameter image inside the existing DDR
# windows.  Model19 is deliberately fixed at six rows: seven rows would need
# 26*7*192 = 34,944 materialized entries and is rejected by r5.
COCO80_CONV_LAYERS: tuple[ConvLayer, ...] = (
    _layer("m0", 0, "input", "pool1", 416, 416, 3, 16, 3, 2, pool_stride=2),
    _layer("m2", 2, "pool1", "pool3", 208, 208, 16, 32, 3, 4, pool_stride=2),
    _layer("m4", 4, "pool3", "pool5", 104, 104, 32, 64, 3, 8, pool_stride=2),
    _layer("m6", 6, "pool5", "pool7", 52, 52, 64, 128, 3, 8, pool_stride=2),
    _layer("m8", 8, "pool7", "m8", 26, 26, 128, 256, 3, 13),
    _layer("m10", 10, "pool9", "m10", 13, 13, 256, 512, 3, 13),
    _layer("m13", 13, "pool12", "m13", 13, 13, 512, 1024, 3, 8),
    _layer("m14", 14, "m13", "m14", 13, 13, 1024, 256, 1, 13),
    _layer("m15", 15, "m14", "m15", 13, 13, 256, 512, 3, 13),
    _layer("m16", 16, "m14", "m16", 13, 13, 256, 128, 1, 13),
    _layer("m19", 19, "concat18", "m19", 26, 26, 384, 256, 3, 6),
    _layer("p4_detect", 20, "m19", "p4_detect", 26, 26, 256, 255, 1, 13, detect_index=0),
    _layer("p5_detect", 20, "m15", "p5_detect", 13, 13, 512, 255, 1, 13, detect_index=1),
)

SAFE_TILE_HEIGHTS: Mapping[str, int] = MappingProxyType(
    {layer.layer_id: layer.tile_h for layer in COCO80_CONV_LAYERS}
)


def ceil_div(value: int, divisor: int) -> int:
    if isinstance(value, bool) or isinstance(divisor, bool):
        raise PlanValidationError("boolean geometry fields are invalid")
    if value < 0 or divisor <= 0:
        raise PlanValidationError("ceil_div requires value>=0 and divisor>0")
    return (value + divisor - 1) // divisor


def conv_output_dim(size: int, kernel: int, stride: int, pad: int) -> int:
    if min(size, kernel, stride) <= 0 or pad < 0:
        raise PlanValidationError("invalid convolution geometry")
    extent = size + 2 * pad - kernel
    if extent < 0:
        raise PlanValidationError("kernel exceeds padded feature map")
    return extent // stride + 1


def _require_int(name: str, value: int, minimum: int = 0) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise PlanValidationError(f"{name} must be an integer >= {minimum}")


def schedule_layer(
    layer: ConvLayer, limits: HardwareLimits = R5_LIMITS
) -> LayerSchedule:
    """Validate and materialize one descriptor using the RTL capacity math."""

    if not isinstance(layer, ConvLayer):
        raise PlanValidationError("layer must be a ConvLayer")
    for name in (
        "model_index", "fm_h", "fm_w", "cin", "cout", "kernel",
        "stride", "pad", "pool_stride", "tile_h", "activation_mode",
    ):
        _require_int(f"{layer.layer_id}.{name}", getattr(layer, name))
    if not layer.layer_id or not layer.input_tensor or not layer.output_tensor:
        raise PlanValidationError("layer identifiers and tensor names must be non-empty")
    if layer.kernel not in (1, 3):
        raise PlanValidationError(f"{layer.layer_id}: r5 supports only 1x1/3x3")
    if layer.stride not in (1, 2):
        raise PlanValidationError(f"{layer.layer_id}: convolution stride must be 1/2")
    if layer.pool_stride not in (0, 2):
        raise PlanValidationError(f"{layer.layer_id}: fused pool is bypass or 2x2/s2")
    if layer.fm_h > limits.fm_h_max or layer.fm_w > limits.fm_w_max:
        raise PlanValidationError(f"{layer.layer_id}: feature map exceeds r5 maximum")
    if not (3 <= layer.cin <= limits.max_channels):
        raise PlanValidationError(f"{layer.layer_id}: Cin exceeds r5 range")
    if not (1 <= layer.cout <= limits.max_channels):
        raise PlanValidationError(f"{layer.layer_id}: Cout exceeds r5 range")
    if limits.rows != ROWS or limits.cols != COLS or limits.cout_tile != COUT_TILE:
        raise PlanValidationError("plan is bound to the r5 18x16/COUT32 ABI")

    conv_h = conv_output_dim(layer.fm_h, layer.kernel, layer.stride, layer.pad)
    conv_w = conv_output_dim(layer.fm_w, layer.kernel, layer.stride, layer.pad)
    if not (1 <= layer.tile_h <= conv_h):
        raise PlanValidationError(f"{layer.layer_id}: invalid tile_h")
    if layer.pool_stride:
        if conv_h % 2 or conv_w % 2 or layer.tile_h % 2:
            raise PlanValidationError(
                f"{layer.layer_id}: fused pool requires even H/W/tile_h"
            )
        output_h, output_w = conv_h // 2, conv_w // 2
    else:
        output_h, output_w = conv_h, conv_w

    k_total = layer.cin * layer.kernel * layer.kernel
    k_passes = ceil_div(k_total, limits.rows)
    cout_blocks = ceil_div(layer.cout, limits.cout_tile)
    tile_count = ceil_div(conv_h, layer.tile_h)
    last_tile_h = conv_h - (tile_count - 1) * layer.tile_h
    if layer.pool_stride and last_tile_h % 2:
        raise PlanValidationError(
            f"{layer.layer_id}: final fused-pool tile height is odd"
        )
    if k_total > limits.max_k_total or k_passes > limits.max_passes:
        raise PlanValidationError(f"{layer.layer_id}: K/pass capacity exceeded")

    max_tile_pixels = conv_w * layer.tile_h
    max_tile_output_pixels = (
        (conv_w // 2) * (layer.tile_h // 2)
        if layer.pool_stride
        else max_tile_pixels
    )
    materialized_entries = max_tile_pixels * k_passes
    packed_reorder_entries = max_tile_output_pixels * cout_blocks
    line_words = ceil_div(layer.cin, 4) * ceil_div(layer.fm_w, 2)
    if max_tile_pixels > limits.psum_depth:
        raise PlanValidationError(f"{layer.layer_id}: PSUM tile capacity exceeded")
    if materialized_entries > limits.materialized_depth:
        raise PlanValidationError(
            f"{layer.layer_id}: materialized cache capacity exceeded "
            f"({materialized_entries}>{limits.materialized_depth})"
        )
    if packed_reorder_entries > limits.packed_reorder_depth:
        raise PlanValidationError(
            f"{layer.layer_id}: packed reorder capacity exceeded"
        )
    if line_words > limits.line_bank_depth:
        raise PlanValidationError(f"{layer.layer_id}: row-store capacity exceeded")
    if layer.native_1x1 and max_tile_pixels > limits.ifm_fifo_depth:
        raise PlanValidationError(f"{layer.layer_id}: native1x1 FIFO capacity exceeded")

    ifm_bytes = layer.fm_h * layer.fm_w * layer.cin
    ofm_bytes = output_h * output_w * layer.cout
    bias_packets = tile_count * cout_blocks
    weight_packets = bias_packets * k_passes
    bias_bytes = bias_packets * BIAS_PACKET_BYTES
    weight_bytes = weight_packets * WEIGHT_PACKET_BYTES
    for name, size in (
        ("bias", bias_bytes), ("weight", weight_bytes),
        ("IFM", ifm_bytes), ("OFM", ofm_bytes),
    ):
        if size <= 0 or size >= limits.dma_max_length:
            raise PlanValidationError(
                f"{layer.layer_id}: {name} DMA length {size} is invalid"
            )

    return LayerSchedule(
        layer=layer,
        conv_h=conv_h,
        conv_w=conv_w,
        output_h=output_h,
        output_w=output_w,
        k_total=k_total,
        k_passes=k_passes,
        cout_blocks=cout_blocks,
        cout_tail_channels=layer.cout - (cout_blocks - 1) * limits.cout_tile,
        tile_count=tile_count,
        last_tile_h=last_tile_h,
        max_tile_pixels=max_tile_pixels,
        max_tile_output_pixels=max_tile_output_pixels,
        materialized_entries=materialized_entries,
        packed_reorder_entries=packed_reorder_entries,
        line_words=line_words,
        ifm_bytes=ifm_bytes,
        ofm_bytes=ofm_bytes,
        bias_packets=bias_packets,
        weight_packets=weight_packets,
        bias_bytes=bias_bytes,
        weight_bytes=weight_bytes,
    )


def _summary(layers: Sequence[LayerSchedule]) -> PlanSummary:
    return PlanSummary(
        layer_count=len(layers),
        total_ifm_bytes=sum(item.ifm_bytes for item in layers),
        total_ofm_bytes=sum(item.ofm_bytes for item in layers),
        total_bias_packets=sum(item.bias_packets for item in layers),
        total_weight_packets=sum(item.weight_packets for item in layers),
        total_bias_bytes=sum(item.bias_bytes for item in layers),
        total_weight_bytes=sum(item.weight_bytes for item in layers),
        max_bias_transfer_bytes=max(item.bias_bytes for item in layers),
        max_weight_transfer_bytes=max(item.weight_bytes for item in layers),
        max_ifm_transfer_bytes=max(item.ifm_bytes for item in layers),
        max_ofm_transfer_bytes=max(item.ofm_bytes for item in layers),
        max_materialized_entries=max(item.materialized_entries for item in layers),
        max_packed_reorder_entries=max(item.packed_reorder_entries for item in layers),
        max_line_words=max(item.line_words for item in layers),
    )


def build_hardware_plan(
    specs: Iterable[ConvLayer] = COCO80_CONV_LAYERS,
    limits: HardwareLimits = R5_LIMITS,
    *,
    enforce_release_contract: bool = True,
) -> HardwarePlan:
    specs_tuple = tuple(specs)
    if not specs_tuple:
        raise PlanValidationError("hardware plan is empty")
    ids = [item.layer_id for item in specs_tuple]
    if len(ids) != len(set(ids)):
        raise PlanValidationError("hardware plan contains duplicate layer_id")
    if enforce_release_contract:
        if specs_tuple != COCO80_CONV_LAYERS:
            raise PlanValidationError("COCO80 release layer table changed")
        if len(specs_tuple) != EXPECTED_LAYER_COUNT:
            raise PlanValidationError("COCO80 release plan must contain 13 convolutions")

    schedules = tuple(schedule_layer(item, limits) for item in specs_tuple)
    summary = _summary(schedules)
    if summary.total_bias_bytes > limits.bias_window_bytes:
        raise PlanValidationError("bias parameter image exceeds its DDR window")
    if summary.total_weight_bytes > limits.weight_window_bytes:
        raise PlanValidationError("weight parameter image exceeds its DDR window")
    if enforce_release_contract:
        if summary.total_bias_bytes != EXPECTED_BIAS_PACKAGE_BYTES:
            raise PlanValidationError("COCO80 bias byte contract changed")
        if summary.total_weight_bytes != EXPECTED_WEIGHT_PACKAGE_BYTES:
            raise PlanValidationError("COCO80 weight byte contract changed")
        p4, p5 = schedules[-2:]
        if (
            p4.layer.cout != 255
            or p5.layer.cout != 255
            or p4.cout_blocks != 8
            or p5.cout_blocks != 8
            or p4.cout_tail_channels != 31
            or p5.cout_tail_channels != 31
        ):
            raise PlanValidationError("COCO80 255-channel detector tail changed")

    return HardwarePlan(
        magic=HARDWARE_PLAN_MAGIC,
        version=HARDWARE_PLAN_VERSION,
        limits=limits,
        layers=schedules,
        summary=summary,
    )


COCO80_HARDWARE_PLAN = build_hardware_plan()


def get_schedule(layer_id: str, plan: HardwarePlan = COCO80_HARDWARE_PLAN) -> LayerSchedule:
    for schedule in plan.layers:
        if schedule.layer.layer_id == layer_id:
            return schedule
    raise KeyError(layer_id)


def main() -> None:
    print(json.dumps(COCO80_HARDWARE_PLAN.to_manifest(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
