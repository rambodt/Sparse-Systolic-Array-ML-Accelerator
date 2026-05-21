# ASIC Optimization Log

## Baseline: `build_runs/rtl_funcfix_5ns`

- Functional RTL fixes for SRAM read latency and two-stage PE timing were already in place.
- RTL simulation passed for `accel_top_tb`.
- PAR completed, but was not timing clean at 5 ns:
  - Setup WNS: `-0.563 ns`
  - Reg-to-reg WNS: `-0.275 ns`
  - Hold WNS: positive
- Worst setup paths were clock-gating setup checks from the top-level `start`
  input into generated output-buffer clock gates.
- Magic DRC reported `392` errors, dominated by met5/met4 spacing near the SRAM
  macro and generated power straps.
- Innovus marker file still reported antenna markers.

## Experiment: `build_runs/opt_nocg_met5block_5ns`

Config-only changes:

- Set `synthesis.clock_gating_mode: empty` to disable automatic Genus clock
  gating for timing closure. This trades power for easier 5 ns timing and
  removes the `start -> clock gate enable` critical path class.
- Set `par.blockage_spacing_top_layer: met5` so power strap generation respects
  SRAM macro blockages on met5 instead of only through met4.

Planned validation:

- RTL functional simulation: passed at 16x16, `5 passed / 0 failed`.
- Synthesis: passed.
  - Setup WNS: `-1.3 ps`
  - TNS: `-66.3 ps`
  - Violating paths: `77`
  - Clock-gating paths: none
  - Remaining critical path: bottom-row PE `psum_out_reg` into
    `output_buffer.buf_r` accumulation.
- Synthesized functional simulation: passed at 16x16, `5 passed / 0 failed`.
  The testbench was updated from 4x4 to 16x16 so the fixed-parameter mapped
  netlist ports match the testbench widths.
- PAR completed, but was not clean:
  - Setup WNS: `-0.628 ns`
  - Setup TNS: `-1030.292 ns`
  - Reg-to-reg WNS: `-0.180 ns`
  - Hold WNS: `+0.080 ns`
  - Final Innovus DB saved `1` geometry DRC marker and `23` antenna markers.
- Worst default path: top-level `host_wr_en` through DMA/scratchpad control to
  `u_scratchpad/act_wmask_r`.
- Worst reg-to-reg path: one PE's `act_out` feeding the next PE's multiplier
  input.

## Experiment: `build_runs/opt_boundary_pepipe_5ns`

RTL/config changes:

- Register top-level `start` and host write inputs in `accel_top`.
- Register scratchpad SRAM command pins before the SRAM macros.
- Keep PE at the existing two-stage MAC timing. A deeper PE pipeline was tried
  and reverted because it broke functional timing without a full schedule
  re-derivation.
- Shift left-bank weight SRAM macros from `x=300` to `x=340` to move the
  failing met5 signal/VDD spacing marker away from the macro edge.

Validation/results:

- RTL simulation: passed at 16x16, `5 passed / 0 failed`.
- Synthesis: passed, nearly clean at 5 ns.
  - Setup WNS: `-0.014 ns`
  - TNS: `-0.559 ns`
  - Violating paths: `101`
- Synthesized functional simulation: passed at 16x16, `5 passed / 0 failed`.
- PAR completed but was not clean:
  - Setup WNS: `-0.534 ns`
  - Setup TNS: `-1179.4 ns`
  - Setup violating paths: `8768`
  - Reg-to-reg WNS: `-0.265 ns`
  - Hold WNS: `+0.095 ns`
  - DRVs: none
  - Innovus route DRC: `0` geometry violations
  - Innovus saved markers: `37` antenna markers
- Worst default paths were from top-level `rst_n` into output-buffer/scratchpad
  D inputs. This is reset deassertion being timed as a normal input data path.

## Experiment: `build_runs/opt_reset_falsepath_5ns`

Config-only change:

- Add `set_false_path -from [get_ports rst_n]` in `constraints.tcl`. `rst_n` is
  asynchronous reset, so reset deassertion should not consume the normal 5 ns
  synchronous input timing budget.

Planned validation:

- Functional simulation should be unchanged because this is an SDC-only change.
- Rerun synthesis and PAR in this separate build directory, then inspect whether
  the remaining critical paths are real datapath/output-delay paths.

Validation/results:

- RTL simulation: passed at 16x16, `5 passed / 0 failed`.
- Synthesis completed but was barely failing at 5 ns:
  - Setup WNS: `-0.050 ns`
  - TNS: `-13.406 ns`
  - Violating paths: `1008`
- Synthesized functional simulation: passed at 16x16, `5 passed / 0 failed`.
- PAR completed but was not clean:
  - Setup WNS: `-0.115 ns`
  - Setup TNS: `-21.881 ns`
  - Setup violating paths: `750`
  - Hold WNS: positive
  - Innovus route DRC: `0` geometry violations
  - Innovus saved markers: antenna-only markers
- Remaining limiter was the PE `psum` path into the output-buffer
  accumulation logic.

## Experiment: `build_runs/opt_obuf_pipe_5ns`

RTL changes:

- Add a pipeline stage on PE `psum` inputs before the output-buffer
  accumulation path.

Validation/results:

- RTL simulation: passed at 16x16, `5 passed / 0 failed`.
- Synthesis was timing clean at 5 ns:
  - Setup WNS: `0.000 ns`
  - TNS: `0.000 ns`
  - Violating paths: `0`
- Synthesized functional simulation: passed at 16x16, `5 passed / 0 failed`.
- PAR did not close because a top-level `rd_row` to output-buffer read-data
  path became the limiter, with pre-CTS WNS around `-6.494 ns`.
- Conclusion: the accumulator path improved, but the output read mux needed a
  registered read address/data path.

## Experiment: `build_runs/opt_obuf_pipe_readaddr_5ns`

RTL/testbench changes:

- Pipeline the output-buffer read address/data path.
- Adjust the testbench expected output read latency to 4 cycles.

Validation/results:

- RTL simulation: passed at 16x16, `5 passed / 0 failed`.
- Synthesis was timing clean at 5 ns:
  - Setup WNS: `0.000 ns`
  - TNS: `0.000 ns`
  - Violating paths: `0`
- Synthesized functional simulation: passed at 16x16, `5 passed / 0 failed`.
- PAR completed but was not clean:
  - Setup WNS: `-0.225 ns`
  - Setup TNS: `-161.770 ns`
  - Setup violating paths: `3124`
  - Reg-to-reg WNS: `-0.225 ns`
  - Hold WNS: `+0.100 ns`
  - Innovus route DRC: `0` geometry violations
  - Innovus saved markers: antenna-only markers
- Worst path was the 32-bit output-buffer accumulation from `psum_pipe_r` into
  `buf_r`.
- Conclusion: the read path was fixed, but the accumulator adder needed to be
  split across cycles.

## Experiment: `build_runs/opt_acc_halfpipe_5ns`

RTL changes:

- Split output-buffer accumulation into request, low-half sum, and final
  high-half/carry completion stages.
- Delay the DMA drain threshold from `3 * ARRAY_SIZE - 2` to
  `3 * ARRAY_SIZE` to account for the added output-buffer pipeline latency.

Validation/results:

- RTL simulation: passed at 16x16, `5 passed / 0 failed`.
- Synthesis was timing clean at 5 ns:
  - Setup WNS: `0.000 ns`
  - TNS: `0.000 ns`
  - Violating paths: `0`
  - Cell area: `2,171,534`
  - Leaf instances: `212,136`
- Synthesized functional simulation: passed at 16x16, `5 passed / 0 failed`.
- PAR completed and was timing clean at 5 ns:
  - Setup WNS: `+0.006 ns`
  - Setup TNS: `0.000 ns`
  - Setup violating paths: `0`
  - Reg-to-reg WNS: `+0.006 ns`
  - Hold WNS: `+0.100 ns`
  - DRVs: clean
  - Innovus route DRC: `0` geometry violations
  - Innovus saved markers: antenna-only markers; antenna is currently being
    disregarded.
- New limiting path is inside a PE multiplier input/register path, not the
  output buffer:
  - Example endpoint: `u_array/row_gen[6].col_gen[6].u_pe/mult_r_reg[14]/D`
  - Final slack: `+0.006 ns`
- This is the first run that closes 5 ns post-route, equivalent to 200 MHz.

Signoff checks:

- Magic DRC did not pass:
  - Flat DRC error count: `188`
  - All listed errors are `Metal5 spacing < 1.6um (met5.2)`.
  - The coordinates line up with the placed `fakeram_d64_w32` scratchpad
    macros, and Innovus route geometry DRC was clean.
  - The configured macro GDS, `asic/macro_gds/fakeram_d64_w32.gds`, is only
    `182` bytes. It is a placeholder macro geometry, not a real signoff SRAM
    layout.
  - Current interpretation: this is a fakeram placeholder/macro-abstraction
    issue, not a top-level routed-signal issue.
- LVS did not pass:
  - Circuit 1, extracted layout: `222664` devices and `228957` nets.
  - Circuit 2, schematic: `222680` devices and `228987` nets.
  - Difference is exactly the `16` `fakeram_d64_w32` instances: the schematic
    netlist contains them, but the extracted layout SPICE does not preserve
    them as LVS devices.
  - The top-level Magic `.ext` file has `use fakeram_d64_w32` entries, but
    `ext2spice` output omits the `fakeram` subckt instances. LVS therefore
    fails on SRAM macro recognition, not on the optimized RTL datapath.
  - To get clean full-chip LVS/DRC with SRAMs, this flow needs a real LVS/GDS
    view for `fakeram_d64_w32` or a course-approved SRAM black-box/abstract
    LVS setup.

## Experiment: `build_runs/opt_acc_halfpipe_nogds_5ns`

Configuration change:

- Removed the manual `vlsi.technology.extra_libraries` entry that merged
  `asic/macro_gds/fakeram_d64_w32.gds`.
- This matches the course `bsg_tag_hard_ram` fakeram approach: use generated
  fakeram LEF/lib/Verilog views and let Magic/ext2spice preserve the SRAM as a
  black-box abstract macro instead of merging a placeholder GDS.

Validation/results:

- RTL simulation: passed at 16x16, `5 passed / 0 failed`.
- Synthesis was timing clean at 5 ns:
  - Setup WNS: `0.000 ns`
  - TNS: `0.000 ns`
  - Violating paths: `0`
  - Cell area: `2,171,534`
  - Leaf instances: `212,136`
- Synthesized functional simulation: passed at 16x16, `5 passed / 0 failed`.
- PAR completed and was timing clean at 5 ns:
  - Setup WNS: `+0.006 ns`
  - Setup TNS: `0.000 ns`
  - Setup violating paths: `0`
  - Reg-to-reg WNS: `+0.006 ns`
  - Hold WNS: `+0.100 ns`
  - DRVs: clean
  - Innovus route DRC: `0` geometry violations
  - Innovus saved markers: antenna-only markers; antenna is currently being
    disregarded.
  - Runtime: about `51 min` real time.
- Magic DRC passed:
  - `No errors found`
  - Flat DRC error count: `0`

LVS status:

- The normal Hammer `make ... lvs` run no longer has the SRAM macro mismatch:
  - Circuit 1, extracted layout: `222680` devices and `228987` nets.
  - Circuit 2, schematic: `222680` devices and `228987` nets.
  - Both sides contain `16` `fakeram_d64_w32` instances.
  - Netgen reports `Netlists match uniquely` and `Circuits match correctly`.
- Hammer still marks the default LVS run as failed because the generated
  Innovus LVS netlist has top-level `VDD` and `VSS` pins, while Magic's
  extracted top-level core view does not expose those as top pins:
  - `(no matching pin) | VSS`
  - `(no matching pin) | VDD`
  - This same top-level supply-pin behavior appears in the course
    `bsg_tag_hard_ram` LVS log.
- A focused netgen retry using a copy of the LVS schematic with only the
  top-level `VDD/VSS` ports removed passed:
  - File: `lvs-rundir/accel_top.lvs.nopg.v`
  - Log: `lvs-rundir/accel_top.nopg.lvs.log`
  - Result: `Circuits match uniquely`

Conclusion:

- Removing the placeholder fakeram GDS fixed the real SRAM signoff issue:
  Magic DRC is clean and LVS now preserves/matches all 16 SRAM macros.
- The only remaining default Hammer LVS failure is a top-level supply-port
  bookkeeping issue, not a device, net, or SRAM mismatch.

## Post-PAR simulation cleanup for `build_runs/opt_acc_halfpipe_nogds_5ns`

Issue:

- `sim-par-functional` passed, but the first strict `sim-par` attempts failed
  because the testbench was not written in a gate-level/SDF-safe timing style.
- Hammer/VCS compiles simulations with `-override_timescale=1ps/1ps`, while
  the testbench originally used `always #5 clk = ~clk`. Under the override,
  that made the testbench clock 10 ps instead of 10 ns.
- After fixing the clock period, strict SDF still exposed input/readback races:
  the testbench changed top-level inputs 1 ps after the ideal clock edge, while
  SDF includes real internal clock-tree latency.

Testbench changes:

- Added explicit `timeunit 1ps` / `timeprecision 1ps`.
- Changed the testbench clock to `always #2500`, giving a 5 ns period that
  matches the ASIC timing constraint.
- Moved reset release, `start`, host writes, and output read-address launches
  to the falling clock edge so inputs are stable before the next rising edge.
- Sampled `rd_data` later in the cycle and waited five rising edges for the
  routed output-buffer read pipeline.

Validation/results:

- `make OBJ_DIR=build_runs/opt_acc_halfpipe_nogds_5ns redo-sim-par-functional`
  passed:
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- `make OBJ_DIR=build_runs/opt_acc_halfpipe_nogds_5ns redo-sim-par` passed
  with SDF annotation:
  - SDF annotation summary: `Total errors: 0`, `Total warnings: 0`
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- The SDF build log still reports negative interconnect delay warnings around
  generated fakeram/scratchpad paths. VCS clamps those individual negative
  interconnect delays to zero; this did not prevent the final strict SDF
  post-route simulation from passing.

Physical checks for the same build:

- `make OBJ_DIR=build_runs/opt_acc_halfpipe_nogds_5ns drc lvs` found both
  targets already up to date.
- Existing Magic DRC remains clean with flat DRC error count `0`.
- Existing LVS status remains unchanged:
  - Default Hammer LVS reports `Netlists match uniquely` and
    `Circuits match correctly`, then fails only on top-level `VDD/VSS` pin
    bookkeeping.
  - The no-power-pin retry, `accel_top.nopg.lvs.log`, reports
    `Circuits match uniquely`.
