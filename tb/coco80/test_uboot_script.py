from __future__ import annotations

import struct
import unittest

from tools.coco80.uboot_script import (
    HEADER_BYTES,
    MAGIC,
    UBootScriptError,
    build_image,
    verify_image,
)


class UBootScriptTests(unittest.TestCase):
    def test_builds_deterministic_arm64_script_image(self) -> None:
        script = b"echo test\ngo 0x7c000000\n"
        first = build_image(script)
        second = build_image(script)
        self.assertEqual(first, second)
        self.assertEqual(struct.unpack_from(">I", first, 0)[0], MAGIC)
        self.assertEqual(first[28:32], bytes((5, 22, 6, 0)))
        self.assertEqual(verify_image(first, script), script)
        self.assertEqual(len(first) - HEADER_BYTES, 8 + ((len(script) + 3) & ~3))

    def test_crc_and_script_mismatches_fail_closed(self) -> None:
        script = b"echo test\n"
        image = bytearray(build_image(script))
        image[-1] ^= 1
        with self.assertRaises(UBootScriptError):
            verify_image(bytes(image), script)
        with self.assertRaises(UBootScriptError):
            verify_image(build_image(script), b"echo other\n")

    def test_rejects_invalid_input(self) -> None:
        with self.assertRaises(UBootScriptError):
            build_image(b"")
        with self.assertRaises(UBootScriptError):
            build_image(b"bad\x00script")
        with self.assertRaises(UBootScriptError):
            build_image(b"ok\n", "x" * 33)


if __name__ == "__main__":
    unittest.main()
