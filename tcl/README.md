# Vivado/XSIM build infrastructure

All synthesis, Block Design packaging, and XSIM flows consume
`rtl_sources.tcl`.  The manifest check fails on a missing/duplicate entry or a
new `.v`/`.sv` file under `cal/`, `com/`, or `systolic/` that was not registered.
`run_xsim_regression.tcl` is the authoritative 161-test component manifest:
132 normal tests, 28 mandatory stress tests, and one exact-signature xfail.
`tb_abi_v2_release_ten_layer_chain` is the single standalone system gate and is
run by `run_abi_v2_chain_xsim.tcl`; the infrastructure check rejects any other
unregistered `tb/tb_*.v` file.  Both runners reject Vivado/XSIM versions other
than 2022.2.  They explicitly use xelab O2 and elaborate with debug disabled
unless waves are requested; O3 is not used because representative Conv9
measurement showed no end-to-end gain.  The ABI-v2 verification flow invokes
XSIM exclusively.
Direct Tcl invocation is also fail-closed: before any fixture-backed test, it
runs the repository fixture checker and validates source fingerprints, output
sets, sizes, and SHA256 values rather than accepting a merely present manifest.
Each PowerShell regression invocation writes a timestamp/PID-qualified driver
log, so manifest checks and targeted diagnostics do not contend with a running
full regression.  The ten-layer test emits a heartbeat every 50,000 simulated
cycles; this is observation-only and is not part of any performance counter.
Every chain invocation stores range/config/run-ID-qualified JSON and JUnit in
its immutable run directory.  Only a no-wave/no-trace Conv0--Conv9 run at
`STREAM_CFG=0xBF` from a clean Git commit that passes all exact traffic and
performance gates may
atomically update the canonical `build_xsim/abi_v2_chain_results.*` files;
single-layer and staged runs leave that evidence untouched.
Component regressions follow the same rule: every invocation writes its own
timestamp/PID-qualified report with `run_complete` and
`release_gate_passed`.  Only a clean-commit, completed 161-test run with 160
PASS results and the one exact xfail atomically publishes canonical
`build_xsim/regression_results.*`; targeted, normal-only, wave, failed, and
interrupted runs cannot replace it.
Both XSIM runners recheck Git provenance at compile/elaboration boundaries and
before canonical publication.  Their reports record start/end SHA and dirty
state; a change makes provenance sticky-unstable and prevents publication.

The mandatory release E2E runs the exact 18x16/COUT32/FIFO256 profile at
`STREAM_CFG=0xBF` with Cin=37 (three K passes) and fixed seeds 3, 11, and 29.
Targeted invocations may select the serial bring-up configurations with
`-layer_long_stream_cfg 03` or `-layer_long_stream_cfg 0b`; the override is
recorded in JSON and JUnit and cannot publish canonical release evidence.
Four focused wrappers lock the per-spatial-tile boundaries at 1, 169, 936, and
1024 pixels.  Each wrapper
uses two tiles, so `p1024` means two 32x32 tiles (2048 layer pixels), not a
1024-pixel layer.  The `p1` case uses Cin=1024; the 169-pixel 3x3 case uses
odd Cin=3; and the 936/1024-pixel cases use Cin=19 to force an 18-row full
K-pass followed by a one-row tail and a live partial-PSUM handoff.

The E2E also requests datapath reset only after tagged IFM ownership,
partial-PSUM ownership, and a backpressured packed-OFM drain overlap.  Reset is
active for four PL cycles.  Because the packed-slot validity bitmap is
distributed RAM, an interrupted bank then clears its captured dense span
sequentially through the existing write port; new tile admission remains
backpressured until this bounded scrub completes.  The formal maximum is 4096
cycles (40.96 us at 100 MHz) and affects recovery only, not normal inference.

## Build profiles

`abi_v2_release` selects the 18x16/32-channel layer-long packed-HWC path,
tagged context, URAM-backed tagged IFM epoch banks, reduced 256-entry result
FIFOs, and lean diagnostics.  Its Block Design statically omits the legacy
AXI GPIO/status service and ties `ifm_line_words` to the invalid value zero;
the control SmartConnect therefore has five, rather than six, manager ports.
Its DSP-cascade OOC gate is LUT<=83000, logic LUT<=72000, LUT memory<=8000,
CLB site<=85%, BRAM<=90, URAM<=48, DSP<=720, WNS>=0.5 ns, and TNS>=0.
The complete-system pre-route gate is LUT<=90000, LUT memory<=8000,
CLB site<=90%, DSP<=720, post-place WNS>=0.3 ns, and congestion level<=4.
The routed-system gate additionally requires WNS>=0.1 ns, TNS>=0, zero timing
failing endpoints, WHS/THS>=0, zero hold and pulse-width failing endpoints,
zero accelerator-scoped blank-source-clock `(none)` Max/Min Delay endpoints,
zero routing errors, and zero DRC errors or critical warnings across the
post-route default and bitstream-check decks.

`abi_v2_release_200` preserves that exact ABI/topology at 200 MHz.  It tightens
the full-system CLB ceiling to 85% and requires exactly 48 URAM.  Its OOC,
post-place, and routed setup gates require non-negative WNS and zero TNS;
hold, pulse-width, constraint-coverage, congestion, route, and DRC gates remain
unchanged.
The profile drives the OOC clock period, PS `pl_clk0`, accelerator `CLOCK_HZ`,
metadata clock, and weight-DMA MM2S burst=64 from the same locked settings.

`legacy_r18c8_debug` selects the supported 18x8/16-channel byte-address debug
path with detailed tracing and retains the GPIO/status hierarchy and its
`0xA0010000` mapping.  It does not enable gates by default because the historical
debug artifacts predate the ABI-v2 budgets.

Profiled builds fail if the active Vivado version is not 2022.2.  Legacy
commands without `-profile` retain the historical version behavior.

`abi_v2_release` is immutable after command-line parsing: the project and BD
names, target part/board, datapath/cache parameters, release features, and
mandatory gates cannot be downgraded.  Numeric gate overrides may only tighten
its limits; `-no_gates` is rejected, and the complete-system flow also rejects
`-reuse_synth`.  Commands
without `-profile` and the legacy profile retain configurable debug behavior.
Implementation and standalone-BD `-build_dir` values for this profile must be
dedicated top-level `build_*abi_v2_release*` directories.  Paths under
`release/`, nested source paths, paths outside the repository, and names that
contain `legacy` are rejected before stale artifacts can be removed.
All profiles also reject a project directory anywhere under the immutable
`release/` tree; publishing signed artifacts is a separate step.
`abi_v2_release` requires an explicit `-ooc` on the OOC synthesis command.
Profiled OOC filenames encode the tagged,
diagnostic, layer-long, result-FIFO, IFM epoch-memory, and OOC-mode choices
(for example `_eu1_ooc1`) so phase-1 and final checkpoints cannot silently
overwrite one another.

The staged 125/150/175 MHz sweeps must name `abi_v2_release_200`, use an
explicit dedicated `build_*abi_v2_frequency_sweep_<MHz>*` directory, and may
change only the physical clock and the two derived WNS admission thresholds
described below.  All topology, feature, DMA burst, resource,
and non-WNS timing-gate locks still come from `abi_v2_release_200`; the
post-place WNS threshold is derived from 1% of the constrained period and the
routed WNS threshold remains zero.  Their metadata uses
a non-release `abi_v2_frequency_sweep_<MHz>` identity.  The 125 MHz identity
may be bound only to the isolated one-run development functional flow; it is
explicitly ineligible for release, 30/100-run performance signoff, or soak.
The 150/175 MHz sweep identities remain rejected by candidate tooling.

```powershell
# Final ABI-v2 OOC gate.
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\run_synth_xck26.tcl -tclargs `
  -profile abi_v2_release -ooc

# Placed OOC frequency sweep (repeat for 125, 150, and 175).
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\run_synth_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -ooc -development_clock_mhz 150 `
  -build_dir build_ooc_abi_v2_frequency_sweep_150

# Full staged implementations used after the OOC sweep.  These remain
# non-release artifacts even when timing closes.
foreach ($MHz in 125, 150, 175) {
  & 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
    -source tcl\build_kv260_system_xck26.tcl -tclargs `
    -profile abi_v2_release_200 -development_clock_mhz $MHz `
    -build_dir "build_system_abi_v2_frequency_sweep_${MHz}" -jobs 12
}

# One-shot continuation for the already generated 125 MHz full-system
# post-phys-opt checkpoint.  Commit the gate/audit tooling first and keep the
# worktree clean and unchanged between preflight and the actual run.
$ResumeGitSha = (git rev-parse HEAD).Trim()
tclsh tcl\resume_system_route_xck26.tcl `
  -source_build_dir build_system_abi_v2_frequency_sweep_125 `
  -profile abi_v2_release_200 -development_clock_mhz 125 `
  -expected_resume_git_sha $ResumeGitSha -jobs 12 -check_only
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\resume_system_route_xck26.tcl -tclargs `
  -source_build_dir build_system_abi_v2_frequency_sweep_125 `
  -profile abi_v2_release_200 -development_clock_mhz 125 `
  -expected_resume_git_sha $ResumeGitSha -jobs 12

# Formal 200 MHz OOC and full-system builds.
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\run_synth_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -ooc
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\build_kv260_system_xck26.tcl -tclargs `
  -profile abi_v2_release_200 -jobs 12

# Pre-tag resource-headroom gate from phase 1.
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\run_synth_xck26.tcl -tclargs `
  -name pretag_resource_headroom -enable_packed_hwc_ofm 1 `
  -enable_layer_tile_sequencer 1 -enable_layer_long_hwc_ifm 1 `
  -enable_tagged_context 0 -ifm_epoch_use_uram 0 `
  -enable_detailed_trace 0 -psum_fifo_depth 256 -psum_fifo_aw 8 -ooc `
  -max_lut 94000 -max_bram 116 -max_uram 48 -max_dsp 410 `
  -min_wns 0.1 -min_tns 0

# Complete KV260 implementation.  A profile-specific build directory is used
# unless -build_dir is supplied.
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\build_kv260_system_xck26.tcl -tclargs `
  -profile abi_v2_release -jobs 12

# Stop after the mandatory post-place resource/timing/congestion gate.  This
# writes a place DCP and SHA but cannot route or publish a bitstream/XSA.
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\build_kv260_system_xck26.tcl -tclargs `
  -profile abi_v2_release -place_only -jobs 12

# Historical debug profile.
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\run_synth_xck26.tcl -tclargs `
  -profile legacy_r18c8_debug -ooc
```

`resume_system_route_xck26.tcl` is deliberately bound to the existing
`abi_v2_frequency_sweep_125` XPR and its known synth/opt/place/phys-opt SHA256
values.  It first re-runs the corrected live post-place audit and the 0.08 ns
development gate, then continues only the managed `route_design` step.  The
earlier DCP hashes and step-marker timestamps must remain unchanged before a
zero-slack routed gate can publish a bitstream and bit-inclusive XSA.  Metadata
keeps the original hardware source Git SHA separately from the clean resume
tooling SHA and marks every resumed artifact `UNQUALIFIED`,
`formal_release_qualified=0`, and `release_eligible=0`.  A route attempt is
one-shot: any pre-existing route/bit marker or artifact is rejected instead of
being reset or overwritten.  Candidate manifests bind the clean hardware and
software Git SHAs independently; the original hardware SHA therefore remains
authoritative while the later clean resume/software SHA is recorded separately.
Generic `git_*_end`/`provenance_stable` fields from the aborted source report
are never propagated into the resumed metadata; only the explicit
`resume_git_*` stability record describes this continuation.

For custom/debug builds, `-enforce_gates` and `-no_gates` select the policy and
at least one threshold is required when enabling gates.  Thresholds use
`-max_lut`, `-max_bram`, `-max_uram`, `-max_dsp`, `-min_wns`, and `-min_tns`;
the system build also accepts
`-max_failing_endpoints`, `-max_hold_failing_endpoints`,
`-max_pulse_width_failing_endpoints`, `-max_accel_none_delay_endpoints`,
`-max_route_errors`, `-max_drc_errors`, and `-max_drc_critical_warnings`.

Each OOC run first removes only its exact same-name prior reports/DCP/SHA, then
writes reports and a build-profile record before evaluating its gate.  The
record includes Vivado version and Git SHA/dirty state.  The formal DCP and its
SHA256 manifest are published only after that gate passes; a failed gated run
therefore cannot expose an older same-name checkpoint as its result.
A complete system build, including a synthesis- or place-only attempt, removes
only the exact stale `.bit`, `.xsa`, place DCP, and synthesis/place/final SHA
manifest paths inside the selected profile directory.  A `-place_only` build
stops at the pre-route checkpoint after the release phys-opt passes, emits flat
and hierarchical utilization, timing and congestion reports, enforces the
physical pre-gate, and writes a hashed DCP before exiting.  The ABI-v2 release
uses a managed `AggressiveExplore` pass followed by a second margin pass.  The
second pass temporarily applies 0.450 ns setup uncertainty so Vivado can work
on near-critical paths, then restores user uncertainty to 0.000 ns before the
managed checkpoint, timing report, gate, and route.  Therefore the
`WNS>=0.3 ns` pre-route gate is evaluated against the real 100 MHz constraint,
not the temporary margin constraint.  It is an implementation-margin gate;
the final routed release remains independently gated at `WNS>=0.1 ns`.
Congestion reports explicitly request windows from level 3.  A no-window
summary is interpreted conservatively as the report threshold rather than as
level zero, so the release `level<=4` gate cannot be bypassed by Vivado's
default level-5 report filter.
A full build then implements through `route_design` and emits post-route flat
and hierarchical utilization, timing, route-status, DRC, and congestion reports
before evaluating the final gate.
At both post-place and post-route, the accelerator supplemental
unconstrained-path gate selects only FDRE/D destinations below `*/accel/inst`,
then performs flat fan-in discovery and timing-path queries against the
complete open design.  Its candidate launch points are real sequential
FD*/LD* fabric primitives with a blank source clock.  Complete-design top input
ports are legal and excluded; expanded DSP/RAM timing-model internal nodes are
also recorded as excluded rather than misclassified as fabric launches.  Macro
clock coverage remains enforced by the independent full-design `no_clock` and
`unconstrained_internal_endpoints` gates.
This avoids the synthetic `(none)` startpoints that Vivado 2022.2 creates when
`report_timing_summary -cells` cuts a clocked PS/DMA/AXI path at the
accelerator hierarchy boundary.  The historical
`-max_accel_none_delay_endpoints` option now limits this live FDRE/D audit;
missing hierarchy/endpoints, unexpected object classes, or a timing query that
hits its cap fail closed with `status=ERROR`.
Neither `write_bitstream`, XSA export, nor final SHA generation runs until that
gate passes.  A failed gate therefore leaves no stale or newly published
candidate artifacts.

Formal complete-system `abi_v2_release` candidates require a clean Git
worktree.  Build metadata records the profile, Vivado version, Git SHA/dirty
state, accelerator
parameters, DMA topology (bias/weight/IFM MM2S direct to HP0/HP1/HP2 and OFM
S2MM direct to HP3),
100 MHz clock, no-ILA policy, and gate limits.  The final SHA manifest covers
both the `.bit` and `.xsa`.
The implementation rechecks the same clean SHA after the post-route gate and
again before writing the final hash manifest; a late mismatch removes the
newly generated bitstream/XSA.  Do not modify the worktree concurrently with a
formal XSIM or implementation run.
`-reuse_synth` is forbidden for `abi_v2_release`; legacy/debug reuse verifies
recorded profile and hardware parameters when metadata is present.

Run the non-mutating infrastructure check without Vivado:

```powershell
tclsh tcl/check_build_infra.tcl
tclsh tcl/run_synth_xck26.tcl -check_only -profile abi_v2_release -ooc
tclsh tcl/create_ps_dma_bd_xck26.tcl -check_only -profile abi_v2_release
tclsh tcl/build_kv260_system_xck26.tcl -check_only -profile abi_v2_release
```

For a quick standalone estimate of the collector tag-check cost, run:

```powershell
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\probe_psum_collector.tcl -tclargs 0
& 'C:\Xilinx\Vivado\2022.2\bin\vivado.bat' -mode batch `
  -source tcl\probe_psum_collector.tcl -tclargs 1
```
