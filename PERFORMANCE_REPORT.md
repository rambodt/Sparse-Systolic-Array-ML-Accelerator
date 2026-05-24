# Performance Report

Date: 2026-05-23

This report summarizes the matrix-multiply benchmark results collected for the
systolic-array accelerator and CPU baselines. Accelerator runtimes are hardware
estimates from simulated cycle counts:

```text
hardware_time = cycles * 5.0 ns
```

VCS wall time is not hardware runtime. It is the time required to simulate the
RTL cycle by cycle.

## Current Benchmark Setup

- Accelerator clock used for reporting: `5.0 ns` / `200 MHz`
- Accelerator array size: `16 x 16`
- Data width: 8-bit inputs, 32-bit accumulation
- Rectangular accelerator benchmark command:

```bash
cd /homes/rambodt/Sparse-Systolic-Array-ML-Accelerator/asic/build_runs/rect_bench/sim-rtl-rundir
./simv +M=<M> +K=<K> +N=<N> +MODE=<dense|sparse50|sparse75|sparse90> +CHECK=<full|sample|checksum|none>
```

- Rectangular CPU benchmark command:

```bash
cd /homes/rambodt/Sparse-Systolic-Array-ML-Accelerator/benchmarks
./cpu_rect_matmul_bench <M> <K> <N> <dense|sparse50|sparse75|sparse90> <reps>
```

## Main ML-Style Result

Shape:

```text
A[1024,768] * B[768,768] = C[1024,768]
MACs = 1024 * 768 * 768 = 603,979,776
```

This shape is representative of a transformer hidden-dimension projection, for
example processing `1024` token rows with hidden size `768`.

| Platform | Shape | Mode | Time / Matmul | GMAC/s | GOPS/s | Notes |
|---|---:|---|---:|---:|---:|---|
| Accelerator RTL-derived hardware estimate | `1024x768x768` | dense | `91.914 ms` | `6.571` | `13.142` | `CHECK=sample`, PASS |
| i9-14900 CPU | `1024x768x768` | dense | `271.169 ms` | `2.227` | `4.455` | `reps=10`, PASS |
| i5-1335U CPU | `1024x768x768` | dense | `61.507 ms` | `9.820` | `19.639` | Windows/MinGW, `reps=10`, PASS |

Compared with the i9-14900 CPU run collected locally, the accelerator hardware
estimate is:

```text
271.169 ms / 91.914 ms = 2.95x faster than the i9-14900 CPU baseline
```

Compared with the i5-1335U CPU result collected on Windows/MinGW, the CPU is:

```text
91.914 ms / 61.507 ms = 1.49x faster than the accelerator hardware estimate
```

The VCS simulation wall time for the accelerator run was about `2579.510 s`
(`~43.0 min`). This is simulator wall time, not chip runtime.

Raw accelerator result:

```text
BENCH_RESULT status=PASS
BENCH_RESULT m=1024 k=768 n=768 mode=dense check=sample tile_runs=147456
BENCH_RESULT accel_cycles=17986561
BENCH_RESULT read_cycles=245760
BENCH_RESULT end_to_end_cycles=18382849
BENCH_RESULT cycle_time_ps=5000
BENCH_RESULT accel_time_ns=89932805.000
BENCH_RESULT end_to_end_time_ns=91914245.000
BENCH_RESULT macs=603979776 ops=1207959552
BENCH_RESULT accel_gmac_s=6.715901
BENCH_RESULT accel_gops_s=13.431801
BENCH_RESULT end_to_end_gmac_s=6.571123
BENCH_RESULT end_to_end_gops_s=13.142245
BENCH_RESULT checked_outputs=3629
BENCH_RESULT mismatches=0
```

Raw i9 CPU result:

```text
CPU_RESULT status=PASS
CPU_RESULT m=1024 k=768 n=768 mode=dense reps=10
CPU_RESULT total_time_s=2.711688380
CPU_RESULT time_per_matmul_s=0.271168838
CPU_RESULT macs=603979776 ops=1207959552
CPU_RESULT gmac_s=2.227320
CPU_RESULT gops_s=4.454640
CPU_RESULT checksum=38661030315
```

Raw i5 CPU result:

```text
CPU_RESULT status=PASS
CPU_RESULT m=1024 k=768 n=768 mode=dense reps=10
CPU_RESULT total_time_s=0.615071500
CPU_RESULT time_per_matmul_s=0.061507150
CPU_RESULT macs=603979776 ops=1207959552
CPU_RESULT gmac_s=9.819668
CPU_RESULT gops_s=19.639335
CPU_RESULT checksum=38661030315
```

## 128 x 128 Baseline

Shape:

```text
A[128,128] * B[128,128] = C[128,128]
MACs = 2,097,152
```

| Platform | Shape | Mode | Time / Matmul | GMAC/s | GOPS/s | Notes |
|---|---:|---|---:|---:|---:|---|
| Accelerator RTL-derived hardware estimate | `128x128x128` | dense | `353.285 us` | `5.936` | `11.872` | post-PAR benchmark result |
| i5-1335U CPU | `128x128x128` | dense | `242.002 us` | `8.666` | `17.332` | user-provided, `reps=200000` |
| i9-14900 CPU | `128x128x128` | dense | `154.500 us` approx | `13.592` | `27.184` | local run, `reps=200000` |

For small `128x128` matmuls, the CPUs are faster because the accelerator pays
fixed overheads for tile setup and output readback.

Raw i5 CPU result:

```text
CPU_RESULT status=PASS
CPU_RESULT n=128 mode=dense reps=200000
CPU_RESULT total_time_s=48.400433400
CPU_RESULT time_per_matmul_s=0.000242002
CPU_RESULT macs=2097152 ops=4194304
CPU_RESULT gmac_s=8.665840
CPU_RESULT gops_s=17.331680
CPU_RESULT checksum=134355460
```

## Intermediate Rectangular Results

These runs were used to validate the rectangular testbench and compare scaling.

| Platform | Shape | Mode | Time / Matmul | GMAC/s | GOPS/s | Notes |
|---|---:|---|---:|---:|---:|---|
| Accelerator | `128x256x256` | dense | `1.331 ms` | `6.302` | `12.603` | PASS |
| i9-14900 CPU | `128x256x256` | dense | `0.712 ms` | `11.781` | `23.561` | `reps=50000` |
| Accelerator | `256x256x256` | dense | `2.662 ms` | `6.302` | `12.603` | PASS |
| i9-14900 CPU | `256x256x256` | dense | `1.451 ms` | `11.561` | `23.122` | `reps=20000` |
| Accelerator | `256x64x256` | dense | `0.788 ms` | `5.319` | `10.639` | PASS |
| i9-14900 CPU | `256x64x256` | dense | `0.362 ms` | `11.586` | `23.172` | `reps=50000` |

Raw accelerator results:

```text
128x256x256 dense:
tile_runs=2048
accel_cycles=249729
read_cycles=10240
end_to_end_cycles=266241
accel_gmac_s=6.718169
end_to_end_gmac_s=6.301515

256x256x256 dense:
tile_runs=4096
accel_cycles=499457
read_cycles=20480
end_to_end_cycles=532481
accel_gmac_s=6.718182
end_to_end_gmac_s=6.301527

256x64x256 dense:
tile_runs=1024
accel_cycles=124673
read_cycles=20480
end_to_end_cycles=157697
accel_gmac_s=6.728488
end_to_end_gmac_s=5.319447
```

Raw i9 CPU results:

```text
128x256x256 dense:
time_per_matmul_s=0.000712071
gmac_s=11.780571

256x256x256 dense:
time_per_matmul_s=0.001451162
gmac_s=11.561227

256x64x256 dense:
time_per_matmul_s=0.000362012
gmac_s=11.586088
```

## Rectangular Testbench Validation

The new rectangular RTL benchmark supports:

```text
M <= 1024
K <= 768
N <= 768
```

It supports these check modes:

```text
+CHECK=full
+CHECK=sample
+CHECK=checksum
+CHECK=none
```

Checking is done after `bench_end_cycle`, so reference checking does not inflate
the reported hardware cycle count.

Validation runs:

```text
64x64x64 dense, CHECK=full:
status=PASS
tile_runs=64
accel_cycles=7793
end_to_end_cycles=9857
end_to_end_gmac_s=5.318941
mismatches=0

64x128x64 dense, CHECK=full:
status=PASS
tile_runs=128
accel_cycles=15601
end_to_end_cycles=17665
end_to_end_gmac_s=5.935896
mismatches=0

128x64x192 sparse75:
status=PASS
tile_runs=384
accel_cycles=46753
end_to_end_cycles=59137
end_to_end_gmac_s=5.319391
mismatches=0

1024x16x16 dense, CHECK=sample:
status=PASS
mismatches=0

16x768x16 dense, CHECK=sample:
status=PASS
mismatches=0

16x16x768 dense, CHECK=sample:
status=PASS
mismatches=0
```

## Timing Signoff Recommendation

The aggressive `4.9 ns` target was close, but Tempus showed a small setup
violation while Innovus reported pass. For final reporting, use:

```text
Clock period: 5.0 ns
Frequency: 200 MHz
```

Recommended report wording:

```text
The design was implemented with an aggressive 4.9 ns target, but signoff timing
in Tempus showed a small setup violation. Final reported performance uses a
conservative 5.0 ns clock period, corresponding to 200 MHz.
```

## Sparse Mode Notes

The current sparse support is functional, but random unstructured sparsity does
not currently provide large latency speedups. The design still uses a mostly
fixed dense tiled schedule, so it pays nearly the same cost for tile loading,
tile execution, and output readback.

Recommended report wording:

```text
Although the design includes sparse operand handling, the current implementation
uses a mostly fixed dense tiled schedule. As a result, random unstructured
sparsity does not significantly reduce latency. The sparse logic is better
viewed as a first step toward sparsity-aware execution, with future work needed
for tile-level skipping or compressed sparse scheduling.
```

Potential improvements:

- Add tile-level nonzero metadata.
- Skip entire `16x16` tile products when an A tile or B tile is all zero.
- Add counters for possible tile runs, executed tile runs, skipped tile runs,
  and useful nonzero MACs.
- Add operand gating to reduce multiplier/adder switching when operands are
  zero.

## Power and Energy Plan

Existing vectorless Innovus power is not sufficient for dense-vs-sparse energy
claims because it does not use benchmark switching activity.

Recommended energy flow:

```text
1. Use timing-clean 5.0 ns PAR/signoff implementation.
2. Run dense/sparse simulations and dump switching activity, preferably SAIF.
3. Feed activity into Innovus/Voltus/Tempus power analysis.
4. Report average power and energy.
```

Energy formula:

```text
energy = average_power * hardware_runtime
```

Useful report metrics:

```text
Average power
Energy per matmul
GMAC/J
GOPS/J
Dense vs sparse50/sparse75/sparse90 power
```

## Recommended Final Tables

For the final report, include:

- Area: total area, cell area, memory/register contribution if available
- Timing: clock period, frequency, WNS/TNS from Tempus
- Performance: cycles, latency, GMAC/s, GOPS/s
- Energy: average power, energy per matmul, GMAC/J
- CPU comparison: i9-14900 and i5-1335U on the same shapes
- Sparse discussion: functional sparse support, current latency limitation,
  and future tile-level skipping
