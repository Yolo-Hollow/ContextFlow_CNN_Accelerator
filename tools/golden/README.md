# Golden Generation Tools

These scripts generate software and RTL-semantic golden data used by the RTL
testbenches.

Default external data root:

```text
D:/MPSoC/python_prj
```

Override the root with either:

```powershell
$env:PYTHON_PRJ = "D:\MPSoC\python_prj"
```

or a script argument:

```powershell
C:\Users\hp\.conda\envs\pytorch_env\python.exe tools\golden\export_rtl_layer06_golden.py --project D:\MPSoC\python_prj
```

Scripts default to writing full generated data back to the external
`python_prj/rtl_golden` directory. Do not write large layer dumps into this repo
unless they are intentionally curated as small regression fixtures.
