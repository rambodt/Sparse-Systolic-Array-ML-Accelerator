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

## RTL benchmark optimization: row writes and on-chip K accumulation

RTL changes:

- Changed the host tile-load interface from one 8-bit element per cycle to one
  128-bit row per cycle.
- Changed `dma_ctrl` load counters from 256 element writes per tile to 16 row
  writes per tile.
- Changed `scratchpad` writes to update all four 32-bit SRAM lanes for a row
  in the same cycle.
- Added `clear_accum` to `accel_top` so the benchmark can clear the output
  buffer only on the first K tile for each C tile.
- Updated the benchmark to keep partial sums on chip across the K-tile loop and
  read each final 16x16 C tile once.

Functional validation:

- `make OBJ_DIR=build_runs/row_accum_rtl sim-rtl` passed the normal
  `accel_top_tb` regression:
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- Direct VCS runs of the updated unit testbenches passed:
  - `dma_ctrl_tb`: `61 passed / 0 failed`
  - `scratchpad_tb`: `89 passed / 0 failed`
- `make OBJ_DIR=build_runs/row_accum_bench TB_CFGS=cfg/systolic_array_benchmark_tb.yml sim-rtl`
  passed the 64x64 dense benchmark with `mismatches=0`.
- Running the same benchmark simulator with `./simv +N=128 +MODE=dense`
  passed with `mismatches=0`.
- Running the same benchmark simulator with `./simv +N=256 +MODE=dense`
  passed with `mismatches=0`.

Measured RTL benchmark results at the 5 ns ASIC cycle estimate:

| Size | Mode | Tile runs | Accelerator cycles | Read cycles | End-to-end cycles | Accel GMAC/s | End-to-end GMAC/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 64x64 | dense | 64 | 7,793 | 20,480 | 29,057 | 6.728 | 1.804 |
| 128x128 | dense | 512 | 62,401 | 81,920 | 147,457 | 6.722 | 2.844 |
| 256x256 | dense | 4,096 | 499,457 | 327,680 | 839,681 | 6.718 | 3.996 |

Comparison to the previous byte-write/host-partial benchmark:

- 64x64 end-to-end cycles improved from `123521` to `29057`, about `4.25x`.
- 128x128 accelerator cycles improved from `307713` to `62401`, about `4.93x`.
- 128x128 end-to-end cycles improved from `988161` to `147457`, about `6.70x`.

ASIC status:

- These RTL/interface changes have passed RTL simulation only so far.
- Synthesis/PAR/signoff should be rerun in a new build directory before
  replacing the current 5 ns closed ASIC result, because the top-level host
  write bus is now wider and the `clear_accum` control is new.

## RTL benchmark optimization: row-wide output read

RTL changes:

- Added a row-wide output read port, `rd_row_data[ARRAY_SIZE]`, from
  `output_buffer` through `accel_top`.
- Kept the existing scalar `rd_data` port for compatibility with the original
  integration testbench.
- Updated the benchmark to read one complete 16-element output row per read
  request instead of reading 256 scalar outputs for each C tile.

Feasibility note on the next proposed optimizations:

- Better tile scheduling/data reuse and load/compute double-buffer overlap are
  not independent small edits in the current RTL.
- The current design has one active C tile in the output buffer and one active
  scratchpad bank for both weights and activations. Reusing A/B tiles across
  different output tiles or loading the next tile while computing the current
  one requires a new multi-tile execution protocol and separate scratchpad bank
  ownership/prefetch control.
- This pass therefore keeps the physical-design run scoped to the verified,
  high-impact row-wide output read rather than mixing in a larger controller
  rewrite before signoff.

Functional validation:

- `make OBJ_DIR=build_runs/row_read_rtl sim-rtl` passed the normal
  `accel_top_tb` regression:
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- `make OBJ_DIR=build_runs/row_read_bench TB_CFGS=cfg/systolic_array_benchmark_tb.yml sim-rtl`
  passed the 64x64 dense benchmark with `mismatches=0`.
- Running the same benchmark simulator with `./simv +N=128 +MODE=dense`
  passed with `mismatches=0`.
- Running the same benchmark simulator with `./simv +N=256 +MODE=dense`
  passed with `mismatches=0`.

Measured RTL benchmark results at the 5 ns ASIC cycle estimate:

| Size | Mode | Tile runs | Accelerator cycles | Read cycles | End-to-end cycles | Accel GMAC/s | End-to-end GMAC/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 64x64 | dense | 64 | 7,793 | 1,280 | 9,857 | 6.728 | 5.319 |
| 128x128 | dense | 512 | 62,401 | 5,120 | 70,657 | 6.722 | 5.936 |
| 256x256 | dense | 4,096 | 499,457 | 20,480 | 532,481 | 6.718 | 6.302 |

Comparison:

- 128x128 improved from `147457` to `70657` end-to-end cycles compared with
  the row-write/on-chip-accumulation design, about `2.09x` faster.
- 128x128 improved from `988161` to `70657` end-to-end cycles compared with
  the original byte-write/host-partial benchmark, about `13.99x` faster.

ASIC status:

- Replaced by the more complete request-pipelined implementation below.

## ASIC closure: row-wide output read plus output-buffer request pipeline

RTL changes:

- Kept the row-wide output read port, `rd_row_data`, so the benchmark reads one
  full 16-element output row per request.
- Added request registers in `output_buffer` before the SRAM/read-modify-write
  accumulation path. This gives the placed design more timing margin without
  changing the programmer-visible benchmark behavior.
- Kept the scalar `rd_data` path for the original integration testbench.

Functional validation before physical design:

- `make OBJ_DIR=build_runs/obuf_reqpipe_rtl sim-rtl` passed:
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- `make OBJ_DIR=build_runs/obuf_reqpipe_bench TB_CFGS=cfg/systolic_array_benchmark_tb.yml sim-rtl`
  passed the dense 64x64 benchmark:
  - `tile_runs=64`
  - `accel_cycles=7793`
  - `read_cycles=1280`
  - `end_to_end_cycles=9857`
  - `mismatches=0`

First 5 ns physical attempt, `build_runs/obuf_reqpipe_5ns`:

- Synthesis was timing clean at 5 ns:
  - Setup WNS: `0.000 ns`
  - TNS: `0.000 ns`
  - Violating paths: `0`
  - Cell area: `2,187,334`
  - Leaf instances: `213,010`
- Synthesized functional simulation passed:
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- PAR completed but missed nominal 5 ns by a small amount:
  - Setup WNS: `-0.049 ns`
  - Setup TNS: `-0.049 ns`
  - Violating paths: `1`
  - Hold WNS: `+0.071 ns`
  - Innovus route geometry DRC: `0`
  - Antenna markers: ignored for now
- Worst path moved into one PE multiplier register path, not the output read
  or output-buffer accumulation logic.

Overconstrained implementation, `build_runs/obuf_reqpipe_4p9ns`:

- Added an implementation-only timing override:
  - File: `cfg/constraints_4p9.tcl`
  - File: `cfg/timing_4p9.yml`
  - Clock period: `4.9 ns`
- Synthesis was timing clean at 4.9 ns:
  - Setup WNS: `0.000 ns`
  - TNS: `0.000 ns`
  - Violating paths: `0`
  - Cell area: `2,210,324`
  - Leaf instances: `220,013`
- Synthesized functional simulation passed:
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- PAR completed and was timing clean at 4.9 ns:
  - Setup WNS: `+0.017 ns`
  - Setup TNS: `0.000 ns`
  - Setup violating paths: `0`
  - Hold WNS: `+0.108 ns`
  - Hold TNS: `0.000 ns`
  - Hold violating paths: `0`
  - DRVs: clean
  - Innovus route geometry DRC: `0`
  - Antenna markers: `61`, ignored for now
- Effective closed period is about `4.883 ns`, or about `204.8 MHz`. Since
  this passes a 4.9 ns implementation target, it has margin against the
  original 5 ns target.
- Post-PAR functional simulation passed:
  - `make OBJ_DIR=build_runs/obuf_reqpipe_4p9ns ... sim-par-functional`
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`

Physical checks for `build_runs/obuf_reqpipe_4p9ns`:

- Magic DRC passed:
  - `No errors found`
  - Flat DRC error count: `0`
- LVS device/net matching is clean, but the default Hammer LVS target still
  reports fail on top-level power pin bookkeeping:
  - Extracted layout: `229497` device instances and `235664` nets.
  - Schematic netlist: `229497` device instances and `235664` nets.
  - Both sides contain `16` `fakeram_d64_w32` instances.
  - Netgen reports `Netlists match uniquely` and `Circuits match correctly`.
  - The only listed pin mismatches are `(no matching pin) | VSS` and
    `(no matching pin) | VDD`.
- The SRAM macro itself is now preserved in LVS and no longer causes the
  earlier missing-macro mismatch. The remaining LVS issue is the same
  top-level supply-port bookkeeping class seen in previous course-flow
  experiments, not an RTL or datapath mismatch.

Current conclusion:

- The row-wide output read optimization is functionally verified and closes
  post-route timing beyond the requested 5 ns target.
- DRC is clean.
- LVS is electrically matching at the device/net level, with only the
  top-level `VDD/VSS` pin presentation keeping Hammer's default LVS target
  from reporting a clean pass.
- Better tile scheduling/data reuse and double-buffer load/compute overlap
  were intentionally not mixed into this run. They are larger controller
  changes and are now throughput optimizations, not required for 5 ns timing
  closure.

## Sparse multiplier gating pass, 2026-05-21

Build directory: `build_runs/sparse_mul_gate_4p9ns`

RTL change:

- Updated `source/pe.sv` so `skip_en` gates the PE multiplier path:
  skipped activations now drive the registered multiply result to zero instead
  of always evaluating `weight_r * act_in` and only bypassing the accumulator
  one stage later.
- This is intended as a sparse-power optimization. It does not change the
  controller schedule, so dense/sparse runtime is expected to stay identical.

Functional verification:

- RTL integration simulation passed:
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- RTL benchmark simulation passed:
  - 64x64 dense: `7793` accelerator cycles, `9857` end-to-end cycles
  - 128x128 dense: `62401` accelerator cycles, `70657` end-to-end cycles
  - 128x128 sparse75: `62401` accelerator cycles, `70657` end-to-end cycles
  - 128x128 sparse90: `62401` accelerator cycles, `70657` end-to-end cycles
  - All modes reported `mismatches=0`

ASIC flow:

- Synthesis at 4.9 ns passed:
  - Setup WNS: `0.000 ns`
  - TNS: `0.000 ns`
  - Violating paths: `0`
  - Cell area: `2,217,170`
  - Leaf instances: `223,289`
  - Sequential instances: `37,223`
  - Combinational instances: `186,066`
- Synthesized functional simulation passed:
  - `5 passed / 0 failed`
  - `ALL TESTS PASSED`
- PAR at 4.9 ns passed timing:
  - Setup WNS: `+0.020 ns`
  - Setup TNS: `0.000 ns`
  - Setup violating paths: `0`
  - Hold WNS: `+0.091 ns`
  - Hold TNS: `0.000 ns`
  - Hold violating paths: `0`
  - Glitch violations: `0`
  - Innovus route geometry DRC: `0`
  - Antenna markers: `63`, ignored for now
- Post-PAR functional simulation passed with the benchmark testbench:
  - 64x64 dense: `7793` accelerator cycles, `9857` end-to-end cycles
  - 128x128 dense/sparse75/sparse90: `62401` accelerator cycles,
    `70657` end-to-end cycles
  - Testbench default time at 5 ns: `353.285 us` end-to-end for 128x128
  - Using the clean 4.9 ns post-route timing target: about `346.219 us`
    end-to-end for 128x128
- The Innovus power report is vectorless (`Activity File: N.A.`), so it is
  not a valid dense-vs-sparse power comparison. The vectorless total power is
  essentially unchanged from the prior build (`680.1 mW` vs `680.7 mW`).
  Sparse power benefit should be measured next with activity from dense,
  sparse75, and sparse90 simulations.

Physical checks:

- Magic DRC passed:
  - `No errors found`
  - Flat DRC error count: `0`
- LVS has the same status as `obuf_reqpipe_4p9ns`:
  - Netgen reports `Netlists match uniquely` and `Circuits match correctly`.
  - Extracted and schematic netlists both contain `231525` devices and
    `237207` nets.
  - Both sides contain `16` `fakeram_d64_w32` instances.
  - Hammer still marks LVS failed because only the top-level `VDD/VSS` pins
    are not matched by name/presentation.

Tile reuse scheduling note:

- I did not implement the proposed tile-reuse scheduler in this pass. In the
  current architecture, the output buffer stores one 16x16 C tile at a time.
  Reusing an A or B tile across multiple output tiles would require either
  multiple resident C tiles or an external partial-sum spill/reload path.
  A scheduler-only loop reorder would overwrite partial results or force extra
  reload/writeback traffic, so it would not be a safe low-risk optimization.
- The next safe performance step is an architectural partial-C path: either a
  multi-tile output buffer or explicit partial-sum load/store support.
