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
- Sparse activation detection with multiplier/adder switching reduction
- Rectangular GEMM benchmark support for ML-style shapes
- ASIC implementation in SKY130 with post-route timing, area, and power reports

## Architecture

At a high level, the accelerator contains:

- `accel_top`: top-level integration
- `dma_ctrl`: tile-load and compute controller
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

Sparse mode detects zero activations and suppresses the corresponding MAC
datapath activity. In the current design, sparsity reduces switching power but
does not reduce cycle count because the controller still follows the dense tile
schedule.

Measured post-PAR Voltus activity-based power showed reduced switching power as
activation sparsity increased:

| Mode | Total Power | Switching Power |
|---|---:|---:|
| Dense | 538.295 mW | 160.672 mW |
| Sparse 50% | 533.070 mW | 157.904 mW |
| Sparse 75% | 524.987 mW | 153.197 mW |
| Sparse 90% | 515.493 mW | 147.764 mW |

## Verification

Verification uses directed SystemVerilog testbenches simulated with Synopsys
VCS. Each major block has a dedicated testbench:

| Testbench | Purpose |
|---|---|
| `tb/pe_tb.sv` | PE MAC, skip behavior, and pipeline timing |
| `tb/array_top_tb.sv` | Systolic-array data movement and psum output |
| `tb/scratchpad_tb.sv` | Banked scratchpad write/read and ping-pong swap |
| `tb/dma_ctrl_tb.sv` | Controller state sequencing and output controls |
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

Accelerator runtime is reported from simulated cycle count at a 5.0 ns clock
period:

```text
hardware_time = cycles x 5.0 ns
```

Representative accelerator results:

| Shape | Time / Matmul | Throughput | Avg Power | Energy Efficiency |
|---|---:|---:|---:|---:|
| 128 x 128 x 128 | 0.353 ms | 5.936 GMAC/s | 0.5381 W | 11.03 GMAC/J |
| 256 x 256 x 256 | 2.662 ms | 6.302 GMAC/s | 0.5381 W | 11.71 GMAC/J |
| 1024 x 768 x 768 | 91.914 ms | 6.571 GMAC/s | 0.5381 W | 12.21 GMAC/J |
| 1024 x 768 x 3072 | 367.657 ms | 6.571 GMAC/s | 0.5381 W | 12.21 GMAC/J |
| 1024 x 3072 x 768 | 361.759 ms | 6.678 GMAC/s | 0.5381 W | 12.41 GMAC/J |

The table below summarizes the measured CPU comparison for two representative
systems. The CPU baseline is a simple C implementation, not an optimized
BLAS/GEMM library, so it should be treated as a straightforward implementation
baseline rather than peak CPU performance.

| Shape | Accelerator | Intel i5-1335U | Ryzen 9 7900X |
|---|---:|---:|---:|
| 128 x 128 x 128 | 5.936 GMAC/s, 11.03 GMAC/J | 6.97 GMAC/s, 0.460 GMAC/J | 14.47 GMAC/s, 0.182 GMAC/J |
| 256 x 256 x 256 | 6.302 GMAC/s, 11.71 GMAC/J | 8.94 GMAC/s, 0.518 GMAC/J | 14.42 GMAC/s, 0.168 GMAC/J |
| 1024 x 768 x 768 | 6.571 GMAC/s, 12.21 GMAC/J | 7.84 GMAC/s, 0.456 GMAC/J | 13.45 GMAC/s, 0.174 GMAC/J |
| 1024 x 768 x 3072 | 6.571 GMAC/s, 12.21 GMAC/J | 8.09 GMAC/s, 0.430 GMAC/J | 14.30 GMAC/s, 0.184 GMAC/J |
| 1024 x 3072 x 768 | 6.678 GMAC/s, 12.41 GMAC/J | 5.38 GMAC/s, 0.309 GMAC/J | 9.66 GMAC/s, 0.119 GMAC/J |



## ASIC Results

The final reported ASIC implementation was generated with the 4.9 ns timing
configuration in `asic/cfg/timing_4p9.yml`. Generated build directories are not
committed by default; key results are summarized below.

Timing signoff was performed with Tempus using a 5.0 ns clock target:

| Check | Corner | Worst Slack | Status |
|---|---|---:|---|
| Setup | ss 100 C / 1.60 V | +0.057 ns | PASS |
| Hold | ff -40 C / 1.95 V | +0.175 ns | PASS |

Physical implementation summary:

| Metric | Value |
|---|---:|
| Clock target | 5.0 ns / 200 MHz |
| Die size | 5 mm x 5 mm |
| Cell area | 2.262 mm2 |
| Density | 8.6% |
| Instances | 231 K leaf cells |
| Activity-based dense power | about 538 mW |

Physical verification status:

- DRC: no rule violations listed in the Magic DRC output
- LVS: internal subcircuits match, but a top-level VDD/VSS power-pin mismatch
  remains in the Netgen LVS report

## Repository Layout

```text
source/                                  SystemVerilog RTL
tb/                                      SystemVerilog testbenches
benchmarks/                              CPU benchmark source and notes
scripts/                                 helper scripts and golden-model utilities
asic/                                    Hammer/Cadence ASIC flow configuration
Systolic_Array_Architecture_Design_Document.md
                                        combined design, verification, and result report
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

The final project build used the 4.9 ns timing configuration:

```bash
make OBJ_DIR=build_runs/sparse_mul_gate_4p9ns \
  INPUT_CFGS="cfg/systolic_array_cfg.yml cfg/systolic_array_src.yml cfg/timing_4p9.yml" \
  syn

make OBJ_DIR=build_runs/sparse_mul_gate_4p9ns \
  INPUT_CFGS="cfg/systolic_array_cfg.yml cfg/systolic_array_src.yml cfg/timing_4p9.yml" \
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
- The current floorplan is conservative and not area-optimized.

## Future Work

- Add true sparse scheduling to skip zero tiles/cycles
- Add boundary masking or zero-padding for non-multiple-of-16 shapes
- Integrate a real system memory/DMA interface
- Optimize the floorplan for smaller die area and shorter routes
- Compare against optimized CPU BLAS and GPU GEMM libraries

## License

This project is licensed under the MIT License. See `LICENSE` for details.