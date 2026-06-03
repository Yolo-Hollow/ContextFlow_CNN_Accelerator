# Golden Data Policy

This directory is reserved for small, stable golden data that is useful for
daily RTL regression.

Do not put full datasets, model checkpoints, or large full-layer dumps here by
default. The current large facemask YOLOv3-tiny golden data remains external:

```text
D:/MPSoC/python_prj/rtl_golden/
```

The checked-in golden generator scripts live in:

```text
tools/golden/
```

They default to the external data root `D:/MPSoC/python_prj`. Override it with
either the `PYTHON_PRJ` environment variable or the script `--project` argument.

Current useful commands:

```powershell
C:\Users\hp\.conda\envs\pytorch_env\python.exe tools\golden\export_yolov3tiny_facemask_golden.py
C:\Users\hp\.conda\envs\pytorch_env\python.exe tools\golden\export_rtl_conv0_golden.py
C:\Users\hp\.conda\envs\pytorch_env\python.exe tools\golden\export_rtl_layer06_golden.py
```

Generated full-layer outputs should stay under the external `python_prj`
directory unless they are intentionally curated into this repository as a small
regression fixture.
