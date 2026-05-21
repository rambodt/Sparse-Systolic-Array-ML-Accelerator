# Matrix-Multiply Benchmarks

These benchmarks compare large square matrix multiplication against the
accelerator by tiling the workload into 16x16 accelerator tile products.

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
