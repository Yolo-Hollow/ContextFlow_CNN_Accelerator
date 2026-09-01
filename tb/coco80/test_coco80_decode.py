"""Build and execute the freestanding COCO80 C host regressions."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
INCLUDE = ROOT / "sw" / "vitis_2022_2" / "src"


def _compiler_candidates() -> list[str]:
    candidates = [
        os.environ.get("CC"),
        r"C:\Xilinx\Vivado\2022.2\tps\mingw\6.2.0\win64.o\nt\bin\gcc.exe",
        shutil.which("gcc"),
        r"C:\msys64\ucrt64\bin\gcc.exe",
    ]
    result = []
    for candidate in candidates:
        if candidate and candidate not in result and Path(candidate).is_file():
            result.append(candidate)
    return result


def _build_and_run(sources: list[Path], executable: Path) -> None:
    failures = []
    for compiler in _compiler_candidates():
        command = [
            compiler,
            "-std=c99",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I",
            str(INCLUDE),
            *(str(source) for source in sources),
            "-lm",
            "-o",
            str(executable),
        ]
        completed = subprocess.run(command, text=True, capture_output=True)
        if completed.returncode != 0:
            failures.append(
                f"{compiler}: compile rc={completed.returncode}\n"
                f"{completed.stdout}{completed.stderr}"
            )
            continue
        run = subprocess.run([str(executable)], text=True, capture_output=True)
        if run.returncode == 0:
            assert run.stdout.startswith("PASS:"), run.stdout
            return
        failures.append(
            f"{compiler}: run rc={run.returncode}\n{run.stdout}{run.stderr}"
        )
    raise AssertionError("no host C compiler completed the regression:\n" + "\n".join(failures))


def test_coco80_decode_and_sd_protocol_c() -> None:
    with tempfile.TemporaryDirectory(prefix="coco80_c_") as directory:
        temporary = Path(directory)
        _build_and_run(
            [
                INCLUDE / "coco80_decode.c",
                ROOT / "tb" / "test_coco80_decode.c",
            ],
            temporary / "test_coco80_decode.exe",
        )
        _build_and_run(
            [
                INCLUDE / "coco80_decode.c",
                INCLUDE / "coco80_sd_protocol.c",
                ROOT / "tb" / "test_coco80_sd_protocol.c",
            ],
            temporary / "test_coco80_sd_protocol.exe",
        )
        _build_and_run(
            [
                INCLUDE / "coco80_decode.c",
                INCLUDE / "coco80_sd_protocol.c",
                INCLUDE / "coco80_sd_index.c",
                ROOT / "tb" / "test_coco80_sd_index.c",
            ],
            temporary / "test_coco80_sd_index.exe",
        )
        _build_and_run(
            [
                INCLUDE / "coco80_tensor_ops.c",
                ROOT / "tb" / "test_coco80_tensor_ops.c",
            ],
            temporary / "test_coco80_tensor_ops.exe",
        )


if __name__ == "__main__":
    test_coco80_decode_and_sd_protocol_c()
    print("PASS: COCO80 C build regressions")
