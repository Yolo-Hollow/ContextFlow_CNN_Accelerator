"""Small, dependency-free reference for the r5 byte/quant graph semantics.

The functions in this module intentionally model the implemented RTL, rather
than a framework's preferred quantization convention.  In particular the
requantizer always adds a positive half-LSB before an arithmetic right shift,
so negative half-way cases round toward positive infinity.  Convolution
results are clamped to signed int8 and then reinterpreted as an unsigned LUT
address.  The LUT output is the uint8 tensor transported through DDR.

Pooling, upsample and route/concat are software graph operations.  They are
kept here beside the RTL arithmetic so host tests can prove that the boundary
does not accidentally change tensor layout or rounding.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence


class RtlSemanticError(ValueError):
    """An operand cannot be represented by the released RTL/software ABI."""


def _integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise RtlSemanticError(f"{label} must be an integer")
    return value


def _byte(value: object, label: str) -> int:
    result = _integer(value, label)
    if not 0 <= result <= 255:
        raise RtlSemanticError(f"{label} must be a uint8 value")
    return result


def _s8(value: object, label: str) -> int:
    result = _integer(value, label)
    if not -128 <= result <= 127:
        raise RtlSemanticError(f"{label} must be a signed int8 value")
    return result


def _u8_tensor(data: Iterable[int], expected: int, label: str) -> tuple[int, ...]:
    try:
        values = tuple(data)
    except TypeError as error:
        raise RtlSemanticError(f"{label} must be an iterable of uint8 values") from error
    if len(values) != expected:
        raise RtlSemanticError(
            f"{label} contains {len(values)} bytes, expected {expected}"
        )
    return tuple(_byte(value, f"{label}[{index}]") for index, value in enumerate(values))


def _geometry(height: int, width: int, channels: int, label: str) -> tuple[int, int, int]:
    result = []
    for name, value in (("height", height), ("width", width), ("channels", channels)):
        checked = _integer(value, f"{label}.{name}")
        if checked <= 0:
            raise RtlSemanticError(f"{label}.{name} must be positive")
        result.append(checked)
    return result[0], result[1], result[2]


def clamp_s8(value: int) -> int:
    """Saturate an integer exactly as ``requant.v::clamp8`` does."""

    checked = _integer(value, "value")
    return max(-128, min(127, checked))


saturate_s8 = clamp_s8


def clamp_u8(value: int) -> int:
    checked = _integer(value, "value")
    return max(0, min(255, checked))


def s8_to_u8(value: int) -> int:
    """Return the two's-complement byte used as the activation-LUT address."""

    return _s8(value, "value") & 0xFF


def u8_to_s8(value: int) -> int:
    checked = _byte(value, "value")
    return checked - 256 if checked & 0x80 else checked


def center_u8_byte(value: int, input_zero_point: int) -> int:
    """Model IFM materializer ``sat_s8(raw_u8 - input_zero_point)``."""

    raw = _byte(value, "value")
    zero_point = _byte(input_zero_point, "input_zero_point")
    return clamp_s8(raw - zero_point)


def center_u8_to_s8(
    data: Iterable[int], input_zero_point: int
) -> tuple[int, ...]:
    zero_point = _byte(input_zero_point, "input_zero_point")
    try:
        values = tuple(data)
    except TypeError as error:
        raise RtlSemanticError("data must be an iterable of uint8 values") from error
    return tuple(
        clamp_s8(_byte(value, f"data[{index}]") - zero_point)
        for index, value in enumerate(values)
    )


def rtl_round_shift(value: int, shift: int) -> int:
    """Add a positive half and arithmetic-shift, matching the RTL bit rule."""

    checked = _integer(value, "value")
    amount = _integer(shift, "shift")
    if amount <= 0:
        raise RtlSemanticError("shift must be positive")
    return (checked + (1 << (amount - 1))) >> amount


def symmetric_round_shift(value: int, shift: int) -> int:
    """PS affine requant rounding: nearest, half-way cases away from zero."""

    checked = _integer(value, "value")
    amount = _integer(shift, "shift")
    if amount <= 0:
        raise RtlSemanticError("shift must be positive")
    half = 1 << (amount - 1)
    if checked >= 0:
        return (checked + half) >> amount
    return -((-checked + half) >> amount)


@dataclass(frozen=True)
class RequantParams:
    """AXI-Lite convolution requantization fields.

    ``shift`` is the four-bit programmed shift.  The RTL adds the Q15
    multiplier's fifteen fractional bits internally.
    """

    mult: int
    shift: int
    output_zero_point: int

    def __post_init__(self) -> None:
        if not 1 <= _integer(self.mult, "mult") <= 65535:
            raise RtlSemanticError("mult must be in 1..65535")
        if not 0 <= _integer(self.shift, "shift") <= 15:
            raise RtlSemanticError("shift must be in 0..15")
        _byte(self.output_zero_point, "output_zero_point")

    @property
    def effective_shift(self) -> int:
        return self.shift + 15


def rtl_requantize_psum(value: int, params: RequantParams) -> int:
    """Return the signed byte emitted by ``requant.v`` before activation."""

    if not isinstance(params, RequantParams):
        raise RtlSemanticError("params must be RequantParams")
    psum = _integer(value, "value")
    rounded = rtl_round_shift(psum * params.mult, params.effective_shift)
    return clamp_s8(rounded + params.output_zero_point)


def requantize_psum(
    value: int, mult: int, shift: int, output_zero_point: int
) -> int:
    """Convenience wrapper accepting the three programmed register fields."""

    return rtl_requantize_psum(value, RequantParams(mult, shift, output_zero_point))


def requantize_psums(
    values: Iterable[int], params: RequantParams
) -> tuple[int, ...]:
    try:
        source = tuple(values)
    except TypeError as error:
        raise RtlSemanticError("values must be an iterable of integers") from error
    return tuple(rtl_requantize_psum(value, params) for value in source)


def validate_lut(lut: Iterable[int]) -> bytes:
    """Validate and freeze the 256 AXI-Lite-programmed activation bytes."""

    return bytes(_u8_tensor(lut, 256, "lut"))


def apply_activation_lut(signed_values: Iterable[int], lut: Iterable[int]) -> bytes:
    table = validate_lut(lut)
    try:
        values = tuple(signed_values)
    except TypeError as error:
        raise RtlSemanticError("signed_values must be iterable") from error
    return bytes(table[s8_to_u8(_s8(value, f"signed_values[{index}]"))] for index, value in enumerate(values))


def requantize_and_lut(
    psums: Iterable[int], params: RequantParams, lut: Iterable[int]
) -> bytes:
    """Model the full convolution PSUM -> signed clamp -> LUT uint8 path."""

    return apply_activation_lut(requantize_psums(psums, params), lut)


@dataclass(frozen=True)
class U8RequantParams:
    """PS route requantization between two uint8 activation domains.

    Unlike the convolution registers, ``shift`` is the complete software
    affine shift (normally 8..30) and ``mult`` is a positive int32.  PS uses
    symmetric nearest rounding with ties away from zero.
    """

    input_zero_point: int
    mult: int
    shift: int
    output_zero_point: int

    def __post_init__(self) -> None:
        _byte(self.input_zero_point, "input_zero_point")
        if not 1 <= _integer(self.mult, "mult") <= 0x7FFFFFFF:
            raise RtlSemanticError("mult must be in 1..2147483647")
        if not 1 <= _integer(self.shift, "shift") <= 30:
            raise RtlSemanticError("shift must be in 1..30")
        _byte(self.output_zero_point, "output_zero_point")


def requantize_u8_byte(value: int, params: U8RequantParams) -> int:
    """Requantize one route byte and clamp in its uint8 destination domain."""

    if not isinstance(params, U8RequantParams):
        raise RtlSemanticError("params must be U8RequantParams")
    centered = _byte(value, "value") - params.input_zero_point
    scaled = symmetric_round_shift(centered * params.mult, params.shift)
    return clamp_u8(scaled + params.output_zero_point)


def requantize_u8_tensor(data: Iterable[int], params: U8RequantParams) -> bytes:
    try:
        values = tuple(data)
    except TypeError as error:
        raise RtlSemanticError("data must be an iterable of uint8 values") from error
    return bytes(
        requantize_u8_byte(_byte(value, f"data[{index}]"), params)
        for index, value in enumerate(values)
    )


def maxpool2d_u8(
    data: Iterable[int],
    height: int,
    width: int,
    channels: int,
    *,
    kernel: int = 2,
    stride: int = 2,
    pad: tuple[int, int, int, int] = (0, 0, 0, 0),
    pad_value: int = 0,
) -> tuple[bytes, int, int]:
    """PS HWC uint8 max-pool with explicit (top,bottom,left,right) padding."""

    h, w, c = _geometry(height, width, channels, "pool")
    source = _u8_tensor(data, h * w * c, "data")
    k = _integer(kernel, "kernel")
    step = _integer(stride, "stride")
    if k <= 0 or step <= 0:
        raise RtlSemanticError("kernel and stride must be positive")
    if not isinstance(pad, tuple) or len(pad) != 4:
        raise RtlSemanticError("pad must be a four-element tuple")
    pads = tuple(_integer(value, f"pad[{index}]") for index, value in enumerate(pad))
    if any(value < 0 for value in pads):
        raise RtlSemanticError("padding must be non-negative")
    fill = _byte(pad_value, "pad_value")
    top, bottom, left, right = pads
    padded_h = h + top + bottom
    padded_w = w + left + right
    if padded_h < k or padded_w < k:
        raise RtlSemanticError("pool kernel exceeds the padded tensor")
    out_h = (padded_h - k) // step + 1
    out_w = (padded_w - k) // step + 1
    result = bytearray(out_h * out_w * c)
    destination = 0
    for oy in range(out_h):
        for ox in range(out_w):
            for channel in range(c):
                maximum = 0
                for ky in range(k):
                    iy = oy * step + ky - top
                    for kx in range(k):
                        ix = ox * step + kx - left
                        value = (
                            source[(iy * w + ix) * c + channel]
                            if 0 <= iy < h and 0 <= ix < w
                            else fill
                        )
                        if value > maximum:
                            maximum = value
                result[destination] = maximum
                destination += 1
    return bytes(result), out_h, out_w


def maxpool2x2_stride2_u8(
    data: Iterable[int], height: int, width: int, channels: int
) -> bytes:
    pooled, _, _ = maxpool2d_u8(data, height, width, channels)
    return pooled


def maxpool2x2_stride1_pad_right_bottom_u8(
    data: Iterable[int],
    height: int,
    width: int,
    channels: int,
    *,
    pad_value: int,
) -> bytes:
    """Darknet's 13x13 special maxpool: pad bottom/right, preserve H/W."""

    pooled, out_h, out_w = maxpool2d_u8(
        data,
        height,
        width,
        channels,
        kernel=2,
        stride=1,
        pad=(0, 1, 0, 1),
        pad_value=pad_value,
    )
    if (out_h, out_w) != (height, width):  # Defensive contract guard.
        raise RtlSemanticError("special pool did not preserve spatial shape")
    return pooled


def nearest_upsample_u8(
    data: Iterable[int],
    height: int,
    width: int,
    channels: int,
    *,
    factor: int = 2,
) -> tuple[bytes, int, int]:
    """Nearest-neighbour HWC expansion with no arithmetic conversion."""

    h, w, c = _geometry(height, width, channels, "upsample")
    source = _u8_tensor(data, h * w * c, "data")
    scale = _integer(factor, "factor")
    if scale <= 0:
        raise RtlSemanticError("factor must be positive")
    out_h, out_w = h * scale, w * scale
    result = bytearray(out_h * out_w * c)
    destination = 0
    for oy in range(out_h):
        iy = oy // scale
        for ox in range(out_w):
            ix = ox // scale
            start = (iy * w + ix) * c
            result[destination : destination + c] = bytes(source[start : start + c])
            destination += c
    return bytes(result), out_h, out_w


def nearest_upsample2x_u8(
    data: Iterable[int], height: int, width: int, channels: int
) -> bytes:
    upsampled, _, _ = nearest_upsample_u8(data, height, width, channels, factor=2)
    return upsampled


def upsample_requant_concat_u8(
    primary: Iterable[int],
    primary_height: int,
    primary_width: int,
    primary_channels: int,
    skip: Iterable[int],
    skip_height: int,
    skip_width: int,
    skip_channels: int,
    skip_requant: U8RequantParams,
    *,
    factor: int = 2,
) -> tuple[bytes, int, int, int]:
    """Upsample primary, requantize skip, then HWC-concat primary first.

    This is YOLOv3-tiny route18's exact channel order: model16/upsample17
    channels precede the preserved model8 channels.
    """

    ph, pw, pc = _geometry(
        primary_height, primary_width, primary_channels, "primary"
    )
    sh, sw, sc = _geometry(skip_height, skip_width, skip_channels, "skip")
    upsampled, out_h, out_w = nearest_upsample_u8(
        primary, ph, pw, pc, factor=factor
    )
    if (sh, sw) != (out_h, out_w):
        raise RtlSemanticError(
            "skip H/W must match the upsampled primary tensor"
        )
    requantized_skip = requantize_u8_tensor(
        _u8_tensor(skip, sh * sw * sc, "skip"), skip_requant
    )
    result = bytearray(out_h * out_w * (pc + sc))
    destination = 0
    for pixel in range(out_h * out_w):
        p_start = pixel * pc
        s_start = pixel * sc
        result[destination : destination + pc] = upsampled[p_start : p_start + pc]
        destination += pc
        result[destination : destination + sc] = requantized_skip[s_start : s_start + sc]
        destination += sc
    return bytes(result), out_h, out_w, pc + sc


requant_concat_u8 = upsample_requant_concat_u8


__all__ = [
    "RequantParams",
    "RtlSemanticError",
    "U8RequantParams",
    "apply_activation_lut",
    "center_u8_byte",
    "center_u8_to_s8",
    "clamp_s8",
    "clamp_u8",
    "maxpool2d_u8",
    "maxpool2x2_stride1_pad_right_bottom_u8",
    "maxpool2x2_stride2_u8",
    "nearest_upsample2x_u8",
    "nearest_upsample_u8",
    "requant_concat_u8",
    "requantize_and_lut",
    "requantize_psum",
    "requantize_psums",
    "requantize_u8_byte",
    "requantize_u8_tensor",
    "rtl_requantize_psum",
    "rtl_round_shift",
    "s8_to_u8",
    "saturate_s8",
    "symmetric_round_shift",
    "u8_to_s8",
    "upsample_requant_concat_u8",
    "validate_lut",
]
