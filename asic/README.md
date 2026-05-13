# Systolic Array ASIC Flow

This directory wraps the accelerator RTL in the EE-477 Hammer CAD flow and targets
SKY130 synthesis with Cadence Genus.

## Setup

Run commands from this directory:

```bash
cd /homes/rambodt/systolic-array-accelerator/asic
make syn
```

The Makefile uses the local CAD checkout at `../ee477-hammer-cad`.

## Inputs

- Top module: `accel_top`
- RTL: `../source/*.sv`
- First-pass clock: 5.0 ns, or 200 MHz
- Scratchpad: synthesized as registers for the first bring-up

## Reports

After synthesis completes, check:

```bash
build/syn-rundir/reports/final_time_ss_100C_1v60.setup_view.rpt
build/syn-rundir/reports/final_area.rpt
```

Generated Hammer and Cadence output should stay under `build/`.
