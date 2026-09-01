# ABI v2 18x16 density-closure evidence

This note records the physical delta for the tagged-context resource-density
work.  All numbers are from Vivado 2022.2, XCK26 out-of-context placement at
100 MHz, with the `abi_v2_release` profile.

## Packed mesh baseline versus scalar DSP cascade

| Metric | Two-cycle packed mesh | Scalar DSP cascade | Delta |
|---|---:|---:|---:|
| CLB LUT | 58,528 | 36,582 | -21,946 |
| Logic LUT | 52,604 | 31,684 | -20,920 |
| LUT memory | 5,924 | 4,898 | -1,026 |
| CLB register | 96,197 | 30,376 | -65,821 |
| CLB site | 13,840 / 14,640 (94.54%) | 7,716 / 14,640 (52.70%) | -6,124 sites |
| BRAM tile | 88 | 88 | 0 |
| URAM | 48 | 48 | 0 |
| DSP | 367 | 655 | +288 |
| WNS | +0.499 ns | +0.501 ns | +0.002 ns |
| TNS | 0 | 0 | 0 |

The array hierarchy itself changed from `22,868 LUT / 72,791 FF / 288 DSP`
to `2,452 LUT / 10,557 FF / 576 DSP`.  The placed congestion report contains
no congestion window above level 5.

The structural gate found exactly 32 scalar lanes, 18 DSP48E2 stages per lane,
576 DSPs and 544 adjacent PCOUT-to-PCIN links.  Every lane occupies one DSP X
column with contiguous Y coordinates.  The placed checkpoint SHA256 is:

`765337bd544cb20f8f13f37504ef66f5368e6d88d7d67b766c7a4a5bc1128eba`

The checkpoint and reports are under `build_synth_xck26/` with prefix
`abi_v2_release_conv_accel_core_axi_lite_axis_stream_r18_c16_cout32_`.

## Functional evidence before placement

- Scalar lane: 256 continuous signed-random tokens, exact 19-sample latency.
- Cascade array: 56 checks covering row/lane mapping, both weight banks,
  continuous tags, collision diagnostics and reset flush.
- Tagged top and A/B/C interleave: lockstep columns, overlapping banks,
  retirement, immediate bank reuse and queued full-tag preservation all pass.
- Release boundaries `1`, `169`, `936` and `1024` pixels pass XSIM.
- The `169`, `936` and `1024` cases use Cin=19 partial-PSUM handoff and three
  fixed stress seeds; the 1024-pixel case completes 3,398 checks with no error.

This is an OOC closure point, not a release artifact.  The checkpoint metadata
records a dirty worktree because the commit is deliberately created only after
the physical gate passes.  A clean full-BD implementation remains required.
