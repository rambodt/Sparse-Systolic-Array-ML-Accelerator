# Matrix-Multiply Benchmarks

These benchmarks compare large square matrix multiplication against the
accelerator by tiling the workload into 16x16 accelerator tile products. The
current accelerator interface loads each 16-byte tile row in one cycle, keeps
partial sums in the output buffer across the K-tile loop, then reads each final
16x16 output tile one row at a time.

Supported matrix sizes:

- `64`
- `128`
- `256`

Supported data modes:

- `dense`
- `sparse50`
- `sparse75`
- `sparse90`

## CPU Benchmark

Build:

```bash
cd /home/rambodt/Sparse-Systolic-Array-ML-Accelerator/benchmarks
make
```

Run:

```bash
./cpu_matmul_bench 64 dense 100
./cpu_matmul_bench 128 dense 20
./cpu_matmul_bench 256 dense 5
./cpu_matmul_bench 128 sparse75 20
```

Arguments are:

```text
./cpu_matmul_bench <N> <mode> <repetitions>
```

Use enough repetitions that the runtime is comfortably measurable.

## Accelerator RTL Benchmark

Build/run the default `64x64` dense benchmark:

```bash
cd /home/rambodt/Sparse-Systolic-Array-ML-Accelerator/asic
make OBJ_DIR=build_bench TB_CFGS=cfg/systolic_array_benchmark_tb.yml sim-rtl
```

After the simulator is built, run other benchmark sizes/modes directly:

```bash
cd /home/rambodt/Sparse-Systolic-Array-ML-Accelerator/asic/build_bench/sim-rtl-rundir
./simv +N=64  +MODE=dense
./simv +N=128 +MODE=dense
./simv +N=256 +MODE=dense
./simv +N=128 +MODE=sparse75
```

The accelerator benchmark prints `BENCH_RESULT` lines with:

- tile count
- accelerator cycles
- readout cycles
- end-to-end cycles
- 5 ns ASIC timing estimate
- effective accelerator-only and end-to-end GMAC/s and GOPS
- correctness status

For the ASIC result, use the printed `cycle_time_ps=5000`, which matches the
current 5 ns post-route timing closure.

## Current RTL Results

Measured with the 5 ns ASIC timing estimate:

| Size | Mode | Tile runs | Accelerator cycles | End-to-end cycles | Accel GMAC/s | End-to-end GMAC/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 64x64 | dense | 64 | 7,793 | 9,857 | 6.728 | 5.319 |
| 128x128 | dense | 512 | 62,401 | 70,657 | 6.722 | 5.936 |
| 256x256 | dense | 4,096 | 499,457 | 532,481 | 6.718 | 6.302 |

Compared with the older byte-write plus host-side partial-accumulation
benchmark, the 128x128 dense case improved from `988161` to `147457`
end-to-end cycles after row writes/on-chip accumulation, then to `70657`
cycles after row-wide output reads. Overall, that is about `13.99x` faster
than the original benchmark.
