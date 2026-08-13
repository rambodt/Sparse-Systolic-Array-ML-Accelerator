# Sparse Systolic Array ML Accelerator

This repository contains a 16 x 16 INT8 systolic-array matrix-multiply
accelerator written in SystemVerilog, with directed verification, benchmark
testbenches, CPU comparison code, and project-specific ASIC flow configuration
targeting SKY130 through Hammer, Cadence Genus, Innovus, Tempus, and Voltus.

The project explores the performance, energy, and physical-design tradeoffs of
a small matrix-multiply accelerator for machine-learning workloads.

Full technical report:
[Systolic Array ML Accelerator Report](https://drive.google.com/file/d/1wQedxlc6-jpjAiKoh0OO9AEU2tDd5kII/view?usp=sharing)

## Highlights

- 16 x 16 systolic array of processing elements
- INT8 activation and weight inputs
- INT32 partial-sum accumulation
- Weight-stationary dataflow
- Ping-pong scratchpad for activation and weight tile storage
- Output accumulation buffer for accumulating across K tiles
- Sparse activation and weight zero-detection with switching reduction
- Overlapped tile prefetch and compute (next tile loads while current tile runs)
- Rectangular GEMM benchmark support for ML-style shapes
- ASIC implementation in SKY130 with post-route timing, area, and power reports

## Architecture

At a high level, the accelerator contains:

- `accel_top`: top-level integration
- `dma_ctrl`: tile controller -- separate prefetch and compute FSMs run
  concurrently so the next tile loads while the current one is computing
- `scratchpad`: ping-pong activation/weight storage
- `sparsity_unit`: zero-activation detection and skip-signal generation
- `array_top`: 16 x 16 systolic PE grid
- `pe`: pipelined INT8 multiply and INT32 accumulate processing element
- `output_buffer`: C-tile accumulation and host readback

The accelerator computes tiled GEMMs of the form:

```text
C[M, N] += A[M, K] x B[K, N]
```

The hardware operates on 16 x 16 tiles. Larger rectangular GEMMs are handled by
the testbench/software loop, which feeds the accelerator one tile product at a
time and uses the output buffer to accumulate partial sums across K tiles.

## Sparse Mode

Sparse mode detects zero values on both sides of the multiply -- a zero
activation (from `sparsity_unit`) or a zero stationary weight -- and gates the
multiplier for either case. It reduces switching power but not cycle count;
the controller runs the same dense tile schedule regardless of how sparse the
data is.

Measured post-PAR Voltus activity-based power on `1024x768x768`, both operands
sparsified independently at the same target density:

| Mode | Total Power | Switching Power | Reduction |
|---|---:|---:|---:|
| Dense | 1.347 W | 396.111 mW | baseline |
| Sparse 50% | 1.128 W | 283.284 mW | 16.23% |
| Sparse 75% | 0.929 W | 180.023 mW | 31.02% |
| Sparse 90% | 0.738 W | 79.844 mW | 45.18% |

## Verification

Verification uses directed SystemVerilog testbenches simulated with Synopsys
VCS. Each major block has a dedicated testbench:

| Testbench | Purpose |
|---|---|
| `tb/sparsity_unit_tb.sv` | Zero detection, skip alignment, and counters |
| `tb/accel_top_tb.sv` | Integrated 16 x 16 GEMM against a golden model |
| `tb/accel_benchmark_tb.sv` | Square tiled GEMM benchmarks |
| `tb/accel_rect_benchmark_tb.sv` | Rectangular ML-style GEMM benchmarks |

The rectangular benchmark supports:

```text
+M=<rows> +K=<inner dimension> +N=<columns>
+MODE=<dense|sparse50|sparse75|sparse90>
+CHECK=<full|sample|checksum|none>
```

Selected validation cases passed with zero mismatches, including dense and
sparse rectangular GEMMs.

## Performance Summary

Accelerator runtime is reported from simulated cycle count at the signed-off
6.0 ns clock period:

```text
hardware_time = cycles x 6.0 ns
```

Representative accelerator results, `SCHED=pipelined_reuse` (weight reuse
across row-tiles, non-blocking tile issuance, all 4 accumulator slots used
concurrently):

| Shape | Time / Matmul | Throughput | Avg Power | Energy Efficiency |
|---|---:|---:|---:|---:|
| 128 x 128 x 128 | 0.1123 ms | 18.67 GMAC/s | 0.995 W | 18.76 GMAC/J |
| 256 x 256 x 256 | 0.6981 ms | 24.03 GMAC/s | 1.207 W | 19.90 GMAC/J |
| 1024 x 768 x 768 | 20.321 ms | 29.72 GMAC/s | 1.347 W | 22.07 GMAC/J |
| 1024 x 768 x 3072 | 81.282 ms | 29.72 GMAC/s | 1.347 W | 22.07 GMAC/J |
| 1024 x 3072 x 768 | 74.066 ms | 32.62 GMAC/s | 1.347 W | 24.22 GMAC/J |

The table below summarizes the measured CPU comparison for two representative
systems. The CPU baseline is a simple C implementation, not an optimized
BLAS/GEMM library, so it should be treated as a straightforward implementation
baseline rather than peak CPU performance.

| Shape | Accelerator | Intel i5-1335U | Ryzen 9 7900X |
|---|---:|---:|---:|
| 128 x 128 x 128 | 18.67 GMAC/s, 18.76 GMAC/J | 6.97 GMAC/s, 0.675 GMAC/J | 14.47 GMAC/s, 0.466 GMAC/J |
| 256 x 256 x 256 | 24.03 GMAC/s, 19.90 GMAC/J | 8.94 GMAC/s, 0.719 GMAC/J | 14.42 GMAC/s, 0.388 GMAC/J |
| 1024 x 768 x 768 | 29.72 GMAC/s, 22.07 GMAC/J | 7.84 GMAC/s, 0.633 GMAC/J | 13.45 GMAC/s, 0.471 GMAC/J |
| 1024 x 768 x 3072 | 29.72 GMAC/s, 22.07 GMAC/J | 8.09 GMAC/s, 0.578 GMAC/J | 14.30 GMAC/s, 0.488 GMAC/J |
| 1024 x 3072 x 768 | 32.62 GMAC/s, 24.22 GMAC/J | 5.38 GMAC/s, 0.427 GMAC/J | 9.66 GMAC/s, 0.294 GMAC/J |

CPU GMAC/J above is net of idle power: `GMAC/s / (gross power - idle power)`,
using measured idle draw of 4.83 W (i5-1335U) and 48.58 W (Ryzen 9 7900X).

## ASIC Results

The final reported ASIC implementation is `obuf_psumfix_3000_6ns`, generated
with the 6.0 ns timing configuration in `asic/cfg/timing_6ns.yml` and the
3000x3000 um floorplan in `asic/cfg/floorplan_3000.yml`. Generated build
directories are not committed by default; key results are summarized below.

Timing signoff was performed with Tempus using a 6.0 ns clock target.

| Check | Corner | Worst Slack | Status |
|---|---|---:|---|
| Setup | ss 100 C / 1.60 V | +0.039 ns | PASS |
| Hold | ff -40 C / 1.95 V | +0.109 ns | PASS |

Physical implementation summary:

| Metric | Value |
|---|---:|
| Clock target | 6.0 ns / 166.67 MHz |
| Die size | 3 mm x 3 mm |
| Cell area | 4.991 mm2 |
| Density | 55.46% |
| Instances | 545,937 leaf cells |
| Activity-based dense power | 0.995 W - 1.347 W (varies by workload shape) |

Area by top-level block (no SRAM macros in this design -- everything is
standard-cell/flip-flop based):

| Block | Area | Share |
|---|---:|---:|
| `u_obuf` | 2.844 mm2 | 57.0% |
| `u_array` | 1.787 mm2 | 35.8% |
| `u_scratchpad` | 0.323 mm2 | 6.5% |
| `u_sparsity` | 0.012 mm2 | 0.2% |
| `u_dma` | 0.002 mm2 | 0.03% |

Physical verification status:

- DRC: Clean - 0 errors (Magic)
- LVS: Clean - netlists match uniquely and circuits match correctly

## Repository Layout

```text
source/                                  SystemVerilog RTL
tb/                                      SystemVerilog testbenches
benchmarks/                              CPU benchmark source and notes
scripts/                                 helper scripts and golden-model utilities
asic/                                    Hammer/Cadence ASIC flow configuration
```

## Running RTL Simulations

The ASIC flow uses Hammer-generated VCS run directories. Typical simulation
commands are run from the relevant generated simulation directory:

```bash
./simv +M=1024 +K=768 +N=768 +MODE=dense +CHECK=checksum
```

For the rectangular benchmark:

```bash
./simv +M=<M> +K=<K> +N=<N> +MODE=<dense|sparse50|sparse75|sparse90> +CHECK=<full|sample|checksum|none>
```

## Running the ASIC Flow

Run commands from `asic/` after connecting the project configuration to a
compatible Hammer/SKY130/Cadence environment. The repository includes the
project-specific RTL, testbenches, and Hammer YAML/TCL configuration files, but
does not include the external CAD framework or licensed tool setup.

```bash
cd asic
make syn
make par
```

The final signed-off build used the 6.0 ns timing configuration and the
3000x3000 um floorplan override:

```bash
make OBJ_DIR=build_runs/obuf_psumfix_3000_6ns \
  INPUT_CFGS="cfg/floorplan_3000.yml cfg/systolic_array_cfg.yml cfg/systolic_array_src.yml cfg/timing_6ns.yml" \
  syn

make OBJ_DIR=build_runs/obuf_psumfix_3000_6ns \
  INPUT_CFGS="cfg/floorplan_3000.yml cfg/systolic_array_cfg.yml cfg/systolic_array_src.yml cfg/timing_6ns.yml" \
  par
```

## Notes and Limitations

- Sparse mode currently reduces switching activity, not runtime.
- Matrix dimensions used by the benchmark flow are multiples of 16.
- Larger GEMMs are tiled by the testbench/software loop rather than by an
  autonomous hardware DMA engine.
- CPU benchmark comparisons are against simple C code, not optimized BLAS.
- Power comparison is not perfectly apples-to-apples: CPU power is package/PPT
  measured power, while accelerator power is post-PAR EDA-estimated chip power.

## License

This project is licensed under the MIT License. See `LICENSE` for details.