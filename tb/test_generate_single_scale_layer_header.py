import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "sw" / "vitis_2022_2" / "scripts" / "generate_single_scale_layer_header.py"
SPEC = importlib.util.spec_from_file_location("generate_single_scale_layer_header", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def main():
    cin = 2
    cout = 3
    native = bytes([
        1, 2,
        3, 4,
        5, 6,
    ])
    packed, hw_kernel = MODULE.pack_weight_kco(
        native,
        cin,
        cout,
        kernel=1,
        emulate_1x1_as_3x3=True,
    )

    assert hw_kernel == 3
    assert len(packed) == cin * 9 * cout
    for ch in range(cin):
        for ker in range(9):
            for co in range(cout):
                got = packed[(ch * 9 + ker) * cout + co]
                expected = native[co * cin + ch] if ker == 4 else 0
                assert got == expected, (ch, ker, co, got, expected)

    packed_native, native_kernel = MODULE.pack_weight_kco(
        native,
        cin,
        cout,
        kernel=1,
        emulate_1x1_as_3x3=False,
    )
    assert native_kernel == 1
    assert len(packed_native) == cin * cout
    for ch in range(cin):
        for co in range(cout):
            assert packed_native[ch * cout + co] == native[co * cin + ch]

    stream = MODULE.pack_weight_stream(packed_native, cin, cout)
    assert len(stream) == 18 * 16
    for ch in range(cin):
        for co in range(cout):
            assert stream[ch * 16 + co] == packed_native[ch * cout + co]
    assert all(value == 0 for value in stream[cout:16])
    assert all(value == 0 for value in stream[cin * 16:])

    print("PASS: native, sparse 3x3, and prepacked weight layouts")


if __name__ == "__main__":
    main()
