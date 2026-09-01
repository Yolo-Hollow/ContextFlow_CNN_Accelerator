# Demo performance tools

`single_scale_cycle_model.py` is the architecture-independent reference for
the Conv0--Conv9 useful-cycle count, logical HWC traffic, and the locked
100 MHz acceptance budget.

```powershell
# Target 18x16 / COUT_TILE=32 model
python tools/demo/single_scale_cycle_model.py

# Confirm the stable 18x8 useful-cycle baseline
python tools/demo/single_scale_cycle_model.py --rows 18 --cols 8

# Check simulation or board counters; exit status is 0 only when every gate passes
python tools/demo/single_scale_cycle_model.py --metrics-json metrics.json

# Machine-readable model and result
python tools/demo/single_scale_cycle_model.py --metrics-json metrics.json --json
```

The useful-cycle formula for each layer is:

```text
conv_pixels * ceil((CIN * kernel * kernel) / ROWS) * ceil(COUT / COUT_TILE)
```

The acceptance JSON root is an object with these total counters:

```json
{
  "compute_fire_cycles": 3889197,
  "pl_busy_cycles": 7000000,
  "feeder_unhidden_cycles": 2000000,
  "context_psum_gap_cycles": 300000,
  "drain_ofm_post_cycles": 600000,
  "bias_weight_wait_cycles": 200000,
  "unclassified_cycles": 10000,
  "prefetch_miss_count": 0,
  "ifm_underflow_count": 0,
  "psum_underflow_count": 0,
  "fifo_drop_count": 0,
  "epoch_mismatch_count": 0,
  "context_full_stall_cycles": 0,
  "ifm_pack_us": 0,
  "ofm_parse_us": 0,
  "ifm_dma_starts": 10,
  "ofm_dma_starts": 10,
  "ifm_bytes": 2249728,
  "ofm_bytes": 1734616,
  "ofm_beats": 216827,
  "layers": {
    "conv0_pool": {"busy_cycles": 750000},
    "conv1_pool": {"busy_cycles": 750000},
    "conv2_pool": {"busy_cycles": 700000},
    "conv3_pool": {"busy_cycles": 650000},
    "conv4_pool": {"busy_cycles": 550000},
    "conv5": {"busy_cycles": 550000},
    "conv6": {"busy_cycles": 2100000},
    "conv7_native1x1": {"busy_cycles": 350000},
    "conv8": {"busy_cycles": 550000},
    "conv9_detect_native1x1": {"busy_cycles": 50000}
  }
}
```

Missing counters fail closed. Layer keys may alternatively use `conv0` through
`conv9`. Run the executable regression with:

```powershell
python -m unittest discover -s tools/demo/tests -v
```
