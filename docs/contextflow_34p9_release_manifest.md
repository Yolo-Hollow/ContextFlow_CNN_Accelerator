# ContextFlow 34.9 ms release manifest

This release branch reorganizes the final source snapshot from commit
`38ecaba807a733216bf1f5164dd703b112a88953` into reviewable hardware,
software, reproducibility, and evidence commits.

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
`paper/lasa_journal_cn/data/evidence_snapshot.json`.

Two nearby numbers use different measurement scopes and must not replace the
headline value:

- **34.978146 ms** is the final `0xBF` controlled-ablation stage recorded in
  `paper/lasa_journal_cn_academic/data/ablation_snapshot.json`.
- **34.925 ms** is a shorter SD cold-boot repeatability run (20 warmups and 100
  timed images) described in `paper/lasa_journal_cn/sections/08_results.tex`.

## Hardware identity

The canonical evidence snapshot records the 200 MHz `abi_v2_release_200`
implementation with the following hashes:

- XSA SHA256: `42d761b1cc77f1a7988d40dd71f0a1c7e1987a057bc457c7d5b55613637e3030`
- bitstream SHA256: `1ac606a279d60290935f32c5bc1a028b017d6cca4f22e623bd0bbb4baa3a613e`

These final binary artifacts are not bundled in this branch. The existing
`release/kv260_hwcreplay_22` directory is a legacy raw-HWC replay handoff whose
README reports approximately 280.340 ms; it is not the 34.943 ms release
hardware.

## Evidence boundaries

Generated build directories, local `results/` captures, temporary files, and
rendered publication PDFs remain outside the release commits. Their relevant
hashes and summarized measurements are retained by the evidence snapshot and
generated evidence manifest under `paper/lasa_journal_cn/`.
