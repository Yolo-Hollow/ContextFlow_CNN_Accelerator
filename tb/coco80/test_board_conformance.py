from pathlib import Path
import tempfile
import unittest

import torch

from tools.coco80.board_conformance import (
    BoardConformanceError,
    _f32_bits,
    _tensor_hwc_bytes,
    _validate_raw_package,
)
from tools.coco80.sd_pack import P4_BYTES, P5_BYTES, pack_raw_heads


class BoardConformanceTest(unittest.TestCase):
    def test_nchw_tensor_is_compared_as_hwc_bytes(self):
        tensor = torch.tensor(
            [[[[1, 2], [3, 4]], [[11, 12], [13, 14]], [[21, 22], [23, 24]]]],
            dtype=torch.uint8,
        )
        self.assertEqual(
            _tensor_hwc_bytes(tensor),
            bytes((1, 11, 21, 2, 12, 22, 3, 13, 23, 4, 14, 24)),
        )
        with self.assertRaises(BoardConformanceError):
            _tensor_hwc_bytes(tensor.to(torch.int16))

    def test_raw_package_contract_and_crc_tamper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            p4 = root / "p4.bin"
            p5 = root / "p5.bin"
            package = root / "raw.c8rh"
            p4.write_bytes(bytes((index * 7) & 0xFF for index in range(P4_BYTES)))
            p5.write_bytes(bytes((index * 11) & 0xFF for index in range(P5_BYTES)))
            pack_raw_heads(
                package,
                p4=p4,
                p5=p5,
                p4_scale=0.25,
                p4_zero_point=17,
                p5_scale=0.5,
                p5_zero_point=19,
                input_package=0x12345678,
                parameter_package=0x87654321,
            )
            raw = package.read_bytes()
            actual_p4, actual_p5 = _validate_raw_package(
                raw,
                input_crc32=0x12345678,
                parameter_crc32=0x87654321,
                p4_scale_bits=_f32_bits(0.25),
                p4_zero_point=17,
                p5_scale_bits=_f32_bits(0.5),
                p5_zero_point=19,
            )
            self.assertEqual(actual_p4, p4.read_bytes())
            self.assertEqual(actual_p5, p5.read_bytes())
            damaged = bytearray(raw)
            damaged[-1] ^= 1
            with self.assertRaisesRegex(BoardConformanceError, "header/binding"):
                _validate_raw_package(
                    bytes(damaged),
                    input_crc32=0x12345678,
                    parameter_crc32=0x87654321,
                    p4_scale_bits=_f32_bits(0.25),
                    p4_zero_point=17,
                    p5_scale_bits=_f32_bits(0.5),
                    p5_zero_point=19,
                )


if __name__ == "__main__":
    unittest.main()
