# ContextFlow 34.9 ms release manifest

**Language / 语言: [中文](contextflow_34p9_release_manifest.md) | English**

## Canonical performance result

The headline result is the complete resident inference measurement:

- resident mean: **34.942764 ms** (reported as **34.943 ms**)
- resident P95: **34.964939 ms**
- throughput: **28.618 FPS**
- PL mean: **33.607297 ms**
- effective throughput: **165.588 GOPS**
- array utilization: **71.87%**
- measurement set: 3 runs, 20 warmups per run, 1000 timed images per run

The canonical machine-readable source is
`repro/evidence/contextflow_34p9_evidence.json`.

The nearby number below uses a different measurement scope and must not replace the
headline value:

- **34.978146 ms** is the final `0xBF` controlled-ablation stage recorded in
  `repro/evidence/contextflow_ablation.json`.

## Hardware identity

The canonical evidence snapshot records the 200 MHz `abi_v2_release_200`
implementation with the following hashes:

- XSA SHA256: `42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030`
- bitstream SHA256: `1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e`

The matching binaries are bundled in `release/contextflow_34p9/`:

- `conv_accel_ps_dma_minimal.xsa`
- `conv_accel_ps_dma_wrapper.bit`

## Evidence locations

Performance, ablation, and same-board CPU evidence is stored under
`repro/evidence/`. The final preprint is available at
`output/pdf/ContexFlow_preprint_thesis.pdf`.
