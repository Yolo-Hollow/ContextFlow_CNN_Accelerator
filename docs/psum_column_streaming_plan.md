# Column-Level Partial-PSUM Streaming

## Current Problem

The current continuous-PSUM path is still packet-granular:

```text
array column FIFOs
  -> collector waits until all columns are non-empty
  -> write one COLS*2 partial-PSUM packet
  -> next pass reads one full packet
  -> systolic_top skews each column by pc*4 cycles
```

This is correct, but it keeps the fixed systolic column wave inside the
feedback boundary. Backend full-tile reduced spatial tile overhead, but the
remaining counters still show low array utilization.

## Direction

Move non-final partial-PSUM feedback from packet-granular storage to
column-granular storage:

```text
column FIFO c
  -> write column c partial result as soon as it appears
  -> next pass reads column c with the same pc*4 delay currently applied after
     full-packet reads
```

The existing full-packet path remains the safe default until top-level
byte-exact tests pass.

## Implemented Foundation

New modules:

```text
systolic/psum_column_pingpong_buffer.v
systolic/psum_column_stream_feeder.v
tb/tb_psum_column_stream.v
```

`psum_column_pingpong_buffer` provides two-bank partial-PSUM storage split by
output column. Each column has independent write and read enable/address/data.

`psum_column_stream_feeder` delays each column's read request by `col*4` cycles.
That produces the same top-row timing shape as the current full-packet reader
followed by per-column skew, while making availability guard and storage
column-local.

## Validation

```text
tb_psum_column_stream     PASS, 32 pass / 0 fail
tb_psum_stream_feeder     PASS, 32 pass / 0 fail
tb_psum_output_collector  PASS
```

`tb_psum_stream_feeder` is now included in the xsim regression list, so the old
full-packet feedback path has direct coverage.

## Next Step

Add an opt-in top-level experiment bit for non-final continuous-PSUM passes:

```text
STREAM_CFG[6] = column_psum_enable
```

When enabled for Conv5/6/8 raw-HWC tests:

- collector writes non-final column outputs into `psum_column_pingpong_buffer`;
- later K passes use `psum_column_stream_feeder`;
- final pass still uses the current full-packet path toward requant/activation;
- disabled mode must remain byte-exact with the current board-validated path.

First acceptance target is xsim byte-exact on Conv5/Conv6/Conv8 raw-HWC tiles.
Only after that should this path be synthesized or tested on KV260.
