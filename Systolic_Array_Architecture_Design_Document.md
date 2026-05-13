# Architecture Design Document

# Sparse Systolic Array Matrix Accelerator

with Scratchpad Memory, DMA Tiling, and Hardware Sparsity Skipping

EE-470 Computer Architecture II · University of Washington · Spring 2026

Version 1.0 · Language: SystemVerilog · Target: Intel Cyclone V FPGA

## Table of Contents

1. Project Overview & Goals

2. System-Level Architecture

3. Global Design Parameters & Conventions

4. Module: Processing Element (pe.sv)

5. Module: Array Top (array_top.sv)

6. Module: Scratchpad SRAM (scratchpad.sv)

7. Module: DMA Tiling Controller (dma_ctrl.sv)

8. Module: Sparsity Detection Unit (sparsity_unit.sv)

9. Module: Output Accumulation Buffer (output_buffer.sv)

10. Module: Accelerator Top (accel_top.sv)

11. Dataflow & Timing Diagrams

12. Verification Architecture

13. FPGA Synthesis Plan

14. Performance Analysis & Roofline

15. Known Risks & Design Rules

## 1. Project Overview & Goals

### 1.1 What We Are Building

A synthesizable, parameterized hardware accelerator for General Matrix Multiply (GEMM) --- the foundational compute primitive of every modern neural network. The accelerator is built around a systolic array, a 2D grid of identical Processing Elements (PEs) where data flows in a rhythmic, pipelined fashion. Weights are stationary inside the PEs; input activations flow left to right; partial sums accumulate downward.

The design is not a simulator and not a full NPU. It is real, synthesizable RTL that runs on an FPGA and performs one operation --- matrix multiplication --- with a memory system that handles matrices larger than the array and a hardware unit that exploits sparsity to skip wasted computation.

### 1.2 Why This Architecture

General-purpose CPUs waste transistors on branch prediction, out-of-order execution, and deep cache hierarchies --- none of which benefit matrix multiplication. A systolic array eliminates this waste: every PE does useful work every clock cycle, data reuse is maximized, and no global bus is required. This is why Google\'s TPU (256×256 systolic array) and NVIDIA\'s tensor cores (tiled MAC arrays) dominate neural network inference.

The weight-stationary dataflow was chosen specifically because it minimizes weight memory traffic: each weight is read from SRAM once but used ARRAY_SIZE times. This is optimal when weight reuse is high, which is true for all standard matrix multiply shapes.

### 1.3 Design Goals

-   Correct GEMM output for arbitrary matrix sizes (tiled automatically by the DMA controller)

-   Fully parameterized design --- changing ARRAY_SIZE alone scales the entire system

-   Hardware sparsity exploitation: zero-valued activations skip MAC computation

-   Functionally verified via UVM with constrained-random stimulus and cycle-accurate scoreboard

-   Synthesizable and timing-closed on Intel Cyclone V FPGA at 100 MHz minimum

-   Roofline characterization: quantify where each workload is compute-bound vs. memory-bound

### 1.4 What This Design Does NOT Include

-   No activation functions (ReLU, GELU, sigmoid) --- GEMM only

-   No convolution, pooling, normalization, or any other neural network operation

-   No compiler or programming model --- the host feeds raw matrix tiles

-   No memory coalescing --- that is a separate research project

-   No multi-precision support --- INT8 inputs, INT32 accumulators only in this version

## 2. System-Level Architecture

### 2.1 Block Diagram Description

The accelerator is composed of six subsystems. Data flows from left to right through the system:

  -----------------------------------------------------------------------------------------------------------------------------------------------------
  **Block**                    **File**               **Role**
  ---------------------------- ---------------------- -------------------------------------------------------------------------------------------------
  Host Interface               (external)             Writes matrix data into scratchpad, asserts start, reads output buffer when done

  Scratchpad SRAM              scratchpad.sv          Dual-bank ping-pong SRAM holding weight and activation tiles on-chip

  DMA Tiling Controller        dma_ctrl.sv            FSM that orchestrates tile loading, weight preload, computation sequencing, and output draining

  Sparsity Detection Unit      sparsity_unit.sv       Inspects each activation before array entry; generates skip signals for zero-valued inputs

  PE Array (16×16)             array_top.sv + pe.sv   The compute engine: 256 MACs operating in parallel with weight-stationary dataflow

  Output Accumulation Buffer   output_buffer.sv       Collects partial sums from the bottom row of the array and accumulates across tile iterations
  -----------------------------------------------------------------------------------------------------------------------------------------------------

### 2.2 Data Path

The end-to-end data path for a matrix multiply C = A × B:

-   Host writes matrix A (activations) and matrix B (weights) tile by tile into the scratchpad SRAM via the write interface.

-   Host asserts start. DMA controller takes over.

-   DMA preloads one B tile (weight tile) into the PE weight registers via a systolic shift-in sequence.

-   DMA streams one A tile (activation tile) into the left column of the array, one row per cycle, staggered by one cycle per column. The sparsity unit inspects each value and asserts skip_en for zeros.

-   Partial sums flow downward through the array. After ARRAY_SIZE + ARRAY_SIZE - 1 cycles, the bottom row produces valid output.

-   DMA drains the bottom row outputs into the output accumulation buffer. For multi-tile computation (K \> ARRAY_SIZE), this accumulates: C += A_tile × B_tile for each K slice.

-   When all tiles are processed, DMA asserts done. Host reads the output buffer.

### 2.3 Control Path

The DMA controller is the sole master of the system during computation. It drives:

-   weight_load_en to the PE array during weight preload

-   act_vld and act_data to the scratchpad read interface during compute

-   bank_sel to the scratchpad to control which bank is active

-   accum_en and accum_clear to the output buffer

-   done to the host interface

The host only has control during IDLE state. Once start is asserted, all control belongs to the DMA FSM until done is returned.

## 3. Global Design Parameters & Conventions

### 3.1 Top-Level Parameters

These parameters live at the top of accel_top.sv and are passed down to all submodules. Never hardcode these values anywhere in the design.

  -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **Parameter**      **Default**   **Type**   **Description**
  ------------------ ------------- ---------- -----------------------------------------------------------------------------------------------------------------------------
  ARRAY_SIZE         16            integer    PE grid dimension. Array is always square (ARRAY_SIZE × ARRAY_SIZE). Changing this alone scales the full design.

  DATA_WIDTH         8             integer    Bit width of activations and weights. INT8 for inference-era quantized models.

  ACC_WIDTH          32            integer    Accumulator bit width. Must be large enough to hold ARRAY_SIZE accumulated products: 8×8×16 = 1024 \< 2\^32. INT32 is safe.

  TILE_SIZE          16            integer    Tile dimension fed to array per compute pass. Must equal ARRAY_SIZE. Kept separate for clarity.

  SCRATCHPAD_DEPTH   4096          integer    Number of DATA_WIDTH-wide words per scratchpad bank. Must hold at least 2 × TILE_SIZE × TILE_SIZE words.

  NUM_BANKS          2             integer    Number of ping-pong scratchpad banks. Fixed at 2 for this design.
  -------------------------------------------------------------------------------------------------------------------------------------------------------------------------

### 3.2 RTL Coding Conventions

These conventions are mandatory across all files. Inconsistency between teammates causes integration bugs.

**Naming**

  ----------------------------------------------------------------------------------------
  **Category**         **Convention**             **Example**
  -------------------- -------------------------- ----------------------------------------
  Module names         snake_case                 pe, array_top, dma_ctrl, sparsity_unit

  Parameters           ALL_CAPS with underscore   ARRAY_SIZE, DATA_WIDTH, ACC_WIDTH

  Input ports          \_in suffix                act_in, weight_in, psum_in

  Output ports         \_out suffix               act_out, psum_out

  Registered signals   \_r suffix                 weight_r, psum_r

  Next-state signals   \_next suffix              state_next, psum_next

  Enable signals       \_en suffix                weight_load_en, skip_en, accum_en

  Valid signals        \_vld suffix               act_vld, out_vld

  Ready signals        \_rdy suffix               array_rdy

  Active-low signals   \_n suffix                 rst_n
  ----------------------------------------------------------------------------------------

**Reset**

Active-low synchronous reset throughout. No asynchronous resets anywhere.

> always_ff @(posedge clk) begin
>
> if (!rst_n) begin
>
> // reset all registers to known state
>
> end else begin
>
> // normal operation
>
> end
>
> end

**Combinational vs Sequential**

-   All combinational logic: always_comb blocks. Assign all outputs in every branch --- no unintentional latches.

-   All sequential logic: always_ff @(posedge clk) blocks only.

-   Never mix combinational and sequential in the same always block.

**Other Rules**

-   No implicit nets. Declare every signal explicitly with its type and width.

-   No magic numbers. Every numeric constant that relates to design parameters must reference a parameter.

-   Single clock domain. No clock gating, no clock muxing, no generated clocks in RTL.

## 4. Module: Processing Element (pe.sv)

### 4.1 Purpose

The PE is the atomic compute unit of the systolic array. It performs one multiply-accumulate (MAC) operation per clock cycle. There are ARRAY_SIZE × ARRAY_SIZE PE instances in the design --- 256 for the default 16×16 configuration. All PEs are identical; no PE has any special-case behavior.

### 4.2 Interface

  -----------------------------------------------------------------------------------------------------------------------------------------
  **Signal**       **Direction**   **Width**    **Description**
  ---------------- --------------- ------------ -------------------------------------------------------------------------------------------
  clk              input           1            System clock

  rst_n            input           1            Active-low synchronous reset

  weight_in        input           DATA_WIDTH   Weight value presented during the preload phase

  act_in           input           DATA_WIDTH   Activation value streaming in from the left neighbor (or left boundary)

  psum_in          input           ACC_WIDTH    Partial sum arriving from the PE directly above (or 0 for top row)

  weight_load_en   input           1            When high: latch weight_in into the internal weight register. Driven by DMA controller.

  skip_en          input           1            When high: do not compute --- pass psum_in directly to psum_out. Driven by sparsity unit.

  act_out          output          DATA_WIDTH   Activation passed to the right neighbor. Registered copy of act_in (one cycle latency).

  weight_out       output          DATA_WIDTH   Weight passed to the PE below. Registered copy of weight_reg (not weight_in).

  psum_out         output          ACC_WIDTH    Result of MAC or passthrough, registered and passed downward.
  -----------------------------------------------------------------------------------------------------------------------------------------

### 4.3 Internal Architecture

**Weight Register**

A DATA_WIDTH-wide register that holds the weight for the current tile. It is loaded during the weight preload phase when weight_load_en is asserted, and does not change during the compute phase. This is the defining characteristic of weight-stationary dataflow: the weight stays stationary while activations flow through.

**MAC Unit**

Each cycle during the compute phase, the PE computes:

> psum_out = psum_in + (weight_reg \* act_in)

The multiply produces a (DATA_WIDTH + DATA_WIDTH)-wide product. This is zero-extended and added to the ACC_WIDTH-wide psum_in. The result is ACC_WIDTH wide. No saturation logic is needed --- the accumulator is wide enough to prevent overflow for all valid input ranges (8-bit × 8-bit × 16 accumulations = maximum value of 255 × 255 × 16 = 1,040,400 which is well within 32-bit range).

**Skip Logic**

When skip_en is asserted by the sparsity unit (because act_in is zero), the MAC is bypassed:

> psum_out = (skip_en) ? psum_in : psum_in + (weight_reg \* act_in)

This is a multiplexer in front of the accumulator. The multiply still technically occurs in hardware (combinationally), but the result is discarded. For power optimization, the multiplier inputs could be gated --- but for this design, behavioral correctness is the goal. Synthesis tools may apply power gating automatically.

**Passthrough Registers**

act_out is a registered copy of act_in. This one-cycle latency is what creates the diagonal wavefront propagation that makes systolic arrays work --- each column sees its activation one cycle later than the previous column, maintaining alignment with the accumulating partial sums.

weight_out is a registered copy of weight_reg. In weight-stationary dataflow, weights do not flow downward during computation. weight_out is used only during the preload phase to shift weights into the PEs below via a systolic weight load sequence.

### 4.4 Behavior by Phase

  --------------------------------------------------------------------------------------------------------------------------------------------------------
  **Phase**          **weight_load_en**   **skip_en**   **PE Behavior**
  ------------------ -------------------- ------------- --------------------------------------------------------------------------------------------------
  Reset              X                    X             All registers cleared to 0

  Weight Preload     1                    0             weight_reg ← weight_in. act_out ← act_in (passes through). psum_out ← psum_in (no accumulation).

  Compute (dense)    0                    0             psum_out ← psum_in + (weight_reg × act_in). act_out ← act_in (registered).

  Compute (sparse)   0                    1             psum_out ← psum_in (skip --- no accumulation). act_out ← act_in (registered).

  Idle / Drain       0                    0             Continues passing psum_in to psum_out until pipeline is flushed.
  --------------------------------------------------------------------------------------------------------------------------------------------------------

### 4.5 Implementation Notes

-   The PE must be fully registered --- all outputs update on the rising clock edge. No combinational output paths.

-   The multiplier will be inferred as a DSP block by Quartus. Do not instantiate DSP primitives manually.

-   Reset all registers to 0 on rst_n low. This includes weight_reg, act_out, and psum_out.

-   The PE has no knowledge of its position in the array. Position-dependent behavior (e.g., staggering) is handled by the array top level, not the PE.

## 5. Module: Array Top (array_top.sv)

### 5.1 Purpose

array_top.sv instantiates the full ARRAY_SIZE × ARRAY_SIZE grid of PEs using nested generate loops and wires their interconnect. It also contains the activation stagger shift registers that create the diagonal wavefront, and the weight preload shift chain.

### 5.2 Interface

  ---------------------------------------------------------------------------------------------------------------------------------
  **Signal**       **Direction**   **Width**                 **Description**
  ---------------- --------------- ------------------------- ----------------------------------------------------------------------
  clk              input           1                         Clock

  rst_n            input           1                         Active-low synchronous reset

  act_col_in       input           DATA_WIDTH × ARRAY_SIZE   One activation value per row, fed into the left column each cycle

  act_col_vld      input           1                         Valid signal: activations on act_col_in are valid this cycle

  weight_load_in   input           DATA_WIDTH × ARRAY_SIZE   One weight value per column, fed into the top row during preload

  weight_load_en   input           1                         Drives weight_load_en of all PEs simultaneously during preload phase

  skip_en_col      input           ARRAY_SIZE                One skip_en bit per row from the sparsity unit

  psum_out_row     output          ACC_WIDTH × ARRAY_SIZE    Partial sum output from the bottom row, one per column

  psum_out_vld     output          1                         Valid signal: psum_out_row contains valid data this cycle
  ---------------------------------------------------------------------------------------------------------------------------------

### 5.3 PE Grid Wiring

The generate loop creates the PE grid and wires the interconnect buses:

> // Internal buses
>
> logic \[DATA_WIDTH-1:0\] act_bus \[ARRAY_SIZE\]\[ARRAY_SIZE+1\];
>
> logic \[DATA_WIDTH-1:0\] wgt_bus \[ARRAY_SIZE+1\]\[ARRAY_SIZE\];
>
> logic \[ACC_WIDTH-1:0\] psum_bus \[ARRAY_SIZE+1\]\[ARRAY_SIZE\];
>
> // Left column receives staggered activations
>
> // act_bus\[row\]\[0\] driven by stagger shift registers (see Section 5.4)
>
> // Top row receives psum = 0
>
> // psum_bus\[0\]\[col\] = \'0 for all col
>
> // Bottom row psum goes to output buffer
>
> // psum_out_row\[col\] = psum_bus\[ARRAY_SIZE\]\[col\]
>
> genvar i, j;
>
> generate
>
> for (i = 0; i \< ARRAY_SIZE; i++) begin : row_gen
>
> for (j = 0; j \< ARRAY_SIZE; j++) begin : col_gen
>
> pe #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_pe (
>
> .clk (clk),
>
> .rst_n (rst_n),
>
> .weight_in (wgt_bus\[i\]\[j\]),
>
> .act_in (act_bus\[i\]\[j\]),
>
> .psum_in (psum_bus\[i\]\[j\]),
>
> .weight_load_en (weight_load_en),
>
> .skip_en (skip_en_col\[i\]),
>
> .act_out (act_bus\[i\]\[j+1\]),
>
> .weight_out (wgt_bus\[i+1\]\[j\]),
>
> .psum_out (psum_bus\[i+1\]\[j\])
>
> );
>
> end
>
> end
>
> endgenerate

### 5.4 Activation Stagger

For correct systolic operation, row i must receive its activation one cycle later than row i-1. This creates the diagonal wavefront. The stagger is implemented with shift registers at the left column input:

> // Stagger shift registers --- row i delays by i cycles
>
> logic \[DATA_WIDTH-1:0\] stagger_sr \[ARRAY_SIZE\]\[ARRAY_SIZE-1\]; // row, delay stage
>
> always_ff @(posedge clk) begin
>
> if (!rst_n) begin
>
> // clear all shift registers
>
> end else begin
>
> for (int r = 0; r \< ARRAY_SIZE; r++) begin
>
> if (r == 0) begin
>
> act_bus\[0\]\[0\] \<= act_col_in\[0\]; // row 0: no delay
>
> end else begin
>
> stagger_sr\[r\]\[0\] \<= act_col_in\[r\]; // stage 0
>
> for (int s = 1; s \< r; s++)
>
> stagger_sr\[r\]\[s\] \<= stagger_sr\[r\]\[s-1\]; // shift
>
> act_bus\[r\]\[0\] \<= stagger_sr\[r\]\[r-1\]; // r cycles delayed
>
> end
>
> end
>
> end
>
> end
>
> *The stagger means the compute phase takes ARRAY_SIZE + ARRAY_SIZE - 1 cycles to fully flush --- ARRAY_SIZE cycles to feed all rows plus ARRAY_SIZE-1 cycles for the last row\'s activation to propagate to the last column.*

### 5.5 Weight Preload Chain

During weight preload, weights are shifted into the PE grid column by column. The DMA controller presents one weight value per column on weight_load_in, and asserts weight_load_en for ARRAY_SIZE cycles. Each PE latches its weight on the rising edge when weight_load_en is high. Since weight_out passes the weight downward (registered), the weights propagate row by row through the column in ARRAY_SIZE cycles.

> *Weight preload takes exactly ARRAY_SIZE clock cycles --- one cycle per row. During this time, no activation data flows.*

## 6. Module: Scratchpad SRAM (scratchpad.sv)

### 6.1 Purpose

The scratchpad holds weight and activation tiles on-chip in fast SRAM while the PE array computes. It uses a ping-pong (double-buffering) scheme: one bank feeds the array while the other is preloaded with the next tile from the host. This hides memory latency and allows sustained compute throughput.

### 6.2 Interface

  -----------------------------------------------------------------------------------------------------------------------
  **Signal**      **Direction**   **Width**                **Description**
  --------------- --------------- ------------------------ --------------------------------------------------------------
  clk             input           1                        Clock

  rst_n           input           1                        Reset

  wr_en           input           1                        Write enable --- host writing tiles into the inactive bank

  wr_addr         input           log2(SCRATCHPAD_DEPTH)   Write address within the bank

  wr_data         input           DATA_WIDTH               Write data (one word per cycle)

  wr_bank_sel     input           1                        Which bank the host is writing into (0 = Bank A, 1 = Bank B)

  rd_en           input           1                        Read enable --- DMA controller reading from the active bank

  rd_addr         input           log2(SCRATCHPAD_DEPTH)   Read address within the bank

  rd_data         output          DATA_WIDTH               Read data (one cycle latency --- registered output)

  rd_bank_sel     input           1                        Which bank the DMA controller is reading from
  -----------------------------------------------------------------------------------------------------------------------

### 6.3 Memory Map Within Each Bank

Each bank stores one complete weight tile followed by one complete activation tile:

  ---------------------------------------------------------------------------------------------------------
  **Address Range**              **Contents**                                 **Size**
  ------------------------------ -------------------------------------------- -----------------------------
  0 to TILE_SIZE²-1              Weight tile (B matrix tile, row-major)       TILE_SIZE × TILE_SIZE words

  TILE_SIZE² to 2×TILE_SIZE²-1   Activation tile (A matrix tile, row-major)   TILE_SIZE × TILE_SIZE words
  ---------------------------------------------------------------------------------------------------------

> *For default ARRAY_SIZE=16: each tile is 16×16=256 words. Each bank holds 512 words total. SCRATCHPAD_DEPTH of 4096 provides ample headroom for future extension.*

### 6.4 Ping-Pong Operation

The DMA controller manages bank swapping:

-   During LOAD phase: host writes into the inactive bank (the one not currently feeding the array).

-   During COMPUTE phase: DMA reads from the active bank to feed the PE array.

-   At the end of each tile computation: the DMA controller swaps banks --- inactive becomes active and vice versa.

-   This overlap --- loading the next tile while computing the current tile --- eliminates memory stall cycles between tiles.

### 6.5 Implementation Notes

-   Implement banks as 2D SystemVerilog arrays: logic \[DATA_WIDTH-1:0\] bank\[NUM_BANKS\]\[SCRATCHPAD_DEPTH\]

-   Quartus will automatically infer these as FPGA block RAMs (BRAMs). Do not instantiate altsyncram or any BRAM primitive manually.

-   Read latency is one cycle (registered output). The DMA controller must account for this in its address sequencing.

-   Simultaneous read and write to different banks is fully supported and expected during normal operation.

-   Simultaneous read and write to the same bank must never occur --- the DMA controller prevents this by design.

## 7. Module: DMA Tiling Controller (dma_ctrl.sv)

### 7.1 Purpose

The DMA controller is the most complex module in the design. It is a Moore FSM that orchestrates the entire computation sequence: it breaks large matrices into TILE_SIZE×TILE_SIZE tiles, sequences them through the array in the correct order, and accumulates partial results across tile iterations. It is the only master of the system during computation.

### 7.2 Interface

  --------------------------------------------------------------------------------------------------------------------
  **Signal**             **Direction**   **Width**     **Description**
  ---------------------- --------------- ------------- ---------------------------------------------------------------
  clk / rst_n            input           1             Clock and reset

  start                  input           1             Host asserts for one cycle to begin computation

  M_size                 input           16            Number of rows in matrix A (must be multiple of TILE_SIZE)

  K_size                 input           16            Shared inner dimension (must be multiple of TILE_SIZE)

  N_size                 input           16            Number of columns in matrix B (must be multiple of TILE_SIZE)

  sp_rd_en               output          1             Scratchpad read enable

  sp_rd_addr             output          log2(DEPTH)   Scratchpad read address

  sp_rd_bank             output          1             Which bank to read from

  array_weight_load_en   output          1             Drives weight_load_en of the PE array

  array_act_vld          output          1             Activation data on the bus is valid this cycle

  bank_swap              output          1             Pulses high for one cycle to trigger bank swap in scratchpad

  accum_en               output          1             Output buffer should accumulate this cycle\'s psum

  accum_clear            output          1             Clear output buffer (beginning of new output tile)

  done                   output          1             Computation complete. Pulses high for one cycle.
  --------------------------------------------------------------------------------------------------------------------

### 7.3 FSM States

  --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **State**      **Description**                                                                                                                                                                         **Duration**                                         **Next State**
  -------------- --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- ---------------------------------------------------- --------------------------
  IDLE           Waiting for start. All outputs deasserted.                                                                                                                                              Until start                                          LOAD_WEIGHTS on start

  LOAD_WEIGHTS   Sequences read addresses through the weight tile region of the active scratchpad bank. Drives array_weight_load_en high. Weights flow into PE registers via the weight preload chain.   ARRAY_SIZE cycles                                    LOAD_ACTS

  LOAD_ACTS      Sequences read addresses through the activation tile region. Drives array_act_vld high. The sparsity unit inspects each value as it exits the scratchpad.                               ARRAY_SIZE cycles (feeding one row per cycle)        COMPUTE

  COMPUTE        Continues streaming activations into the array. Array is actively computing MACs. Partial sums flow down toward the output row.                                                         ARRAY_SIZE + ARRAY_SIZE - 1 cycles total (stagger)   DRAIN

  DRAIN          Activations have finished entering. Array pipeline is flushing. Remaining partial sums propagate to the bottom row.                                                                     ARRAY_SIZE - 1 cycles                                ACCUMULATE

  ACCUMULATE     Asserts accum_en. Output buffer latches bottom row psum values and adds them to the running sum.                                                                                        1 cycle                                              Check: more K tiles?

  SWAP_BANKS     Asserts bank_swap. Scratchpad swaps active and inactive banks. Next tile becomes current tile.                                                                                          1 cycle                                              LOAD_WEIGHTS (next tile)

  DONE           All tiles processed. Asserts done for one cycle.                                                                                                                                        1 cycle                                              IDLE
  --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

### 7.4 Tiling Loop

For a full matrix multiply C\[M×N\] = A\[M×K\] × B\[K×N\], the DMA controller iterates over three nested tile loops:

> for (tile_m = 0; tile_m \< M_size/TILE_SIZE; tile_m++) // rows of A
>
> for (tile_n = 0; tile_n \< N_size/TILE_SIZE; tile_n++) // cols of B
>
> accum_clear = 1 // fresh output tile
>
> for (tile_k = 0; tile_k \< K_size/TILE_SIZE; tile_k++) // K slices
>
> load B tile \[tile_k\]\[tile_n\] → weight preload
>
> load A tile \[tile_m\]\[tile_k\] → activation stream
>
> compute → drain → accumulate
>
> output_buffer\[tile_m\]\[tile_n\] = accumulated result
>
> *The tile_k (K-dimension) loop is the critical inner loop. Each iteration produces a partial result that is accumulated into the output buffer. The output buffer is cleared (accum_clear) at the start of each new (tile_m, tile_n) output tile.*

### 7.5 Cycle Count Analysis

For a single tile computation:

  -----------------------------------------------------------------------------------
  **Phase**                                         **Cycles**
  ------------------------------------------------- ---------------------------------
  Weight preload (LOAD_WEIGHTS)                     ARRAY_SIZE

  Activation load + compute (LOAD_ACTS + COMPUTE)   ARRAY_SIZE + ARRAY_SIZE - 1

  Drain                                             ARRAY_SIZE - 1

  Accumulate + swap                                 2

  Total per tile                                    4 × ARRAY_SIZE
  -----------------------------------------------------------------------------------

For default ARRAY_SIZE=16: 64 cycles per tile. A 256×256×256 matrix multiply with 16×16 tiles requires (256/16)³ = 4096 tiles × 64 cycles = 262,144 cycles. At 100 MHz this is 2.6 ms.

## 8. Module: Sparsity Detection Unit (sparsity_unit.sv)

### 8.1 Purpose

The sparsity unit sits between the scratchpad output and the array left-column input. Its job is to detect zero-valued activations and signal the PE array to skip the corresponding MAC operations. This mirrors NVIDIA Ampere\'s sparse tensor core feature at a simpler granularity.

### 8.2 Interface

  --------------------------------------------------------------------------------------------------------------------------------
  **Signal**           **Direction**   **Width**                 **Description**
  -------------------- --------------- ------------------------- -----------------------------------------------------------------
  clk / rst_n          input           1                         Clock and reset

  act_in               input           DATA_WIDTH × ARRAY_SIZE   Activation values from scratchpad, one per row

  act_vld              input           1                         act_in is valid this cycle (from DMA controller)

  act_out              output          DATA_WIDTH × ARRAY_SIZE   Activations passed through to array (unchanged)

  skip_en              output          ARRAY_SIZE                One skip bit per row. High when that row\'s activation is zero.

  total_mac_cycles     output          32                        Running counter of cycles where act_vld was high

  skipped_mac_cycles   output          32                        Running counter of cycles where skip_en was asserted
  --------------------------------------------------------------------------------------------------------------------------------

### 8.3 Logic

The detection logic is purely combinational --- zero comparison is fast and the result is registered one cycle later alongside the activation data:

> always_comb begin
>
> for (int r = 0; r \< ARRAY_SIZE; r++) begin
>
> skip_en\[r\] = act_vld && (act_in\[r\] == \'0);
>
> end
>
> end
>
> // act_out is a direct passthrough --- no modification
>
> assign act_out = act_in;

### 8.4 Performance Counters

Two 32-bit saturating counters track MAC utilization:

> always_ff @(posedge clk) begin
>
> if (!rst_n) begin
>
> total_mac_cycles \<= \'0;
>
> skipped_mac_cycles \<= \'0;
>
> end else if (act_vld) begin
>
> total_mac_cycles \<= total_mac_cycles + 1;
>
> skipped_mac_cycles \<= skipped_mac_cycles + \|skip_en;
>
> end
>
> end

After done is asserted, the host reads these counters. Sparsity ratio = skipped_mac_cycles / total_mac_cycles. This is reported in the roofline analysis.

> *Using \|skip_en (OR-reduction) means skipped_mac_cycles counts cycles where at least one row was skipped, not total individual skips. For the analysis report, this is clearly defined and consistently applied.*

## 9. Module: Output Accumulation Buffer (output_buffer.sv)

### 9.1 Purpose

The output buffer collects partial sum results from the bottom row of the PE array and accumulates them across K-dimension tile iterations. After all K tiles for a given (M, N) output tile are processed, the buffer holds the final result and can be read by the host.

### 9.2 Interface

  ------------------------------------------------------------------------------------------------------------------------------------------------------
  **Signal**      **Direction**   **Width**                             **Description**
  --------------- --------------- ------------------------------------- --------------------------------------------------------------------------------
  clk / rst_n     input           1                                     Clock and reset

  psum_in         input           ACC_WIDTH × ARRAY_SIZE                Partial sums from bottom row of PE array, one per column

  psum_vld        input           1                                     psum_in is valid this cycle

  accum_en        input           1                                     When high: add psum_in to the running accumulator

  accum_clear     input           1                                     When high: clear all accumulator registers to 0 (beginning of new output tile)

  result_out      output          ACC_WIDTH × ARRAY_SIZE × ARRAY_SIZE   Full output tile, readable by host after done

  result_vld      output          1                                     result_out is valid (same cycle as done)
  ------------------------------------------------------------------------------------------------------------------------------------------------------

### 9.3 Implementation

The accumulator is a 2D register array, ARRAY_SIZE rows × ARRAY_SIZE columns × ACC_WIDTH bits wide:

> logic \[ACC_WIDTH-1:0\] accum \[ARRAY_SIZE\]\[ARRAY_SIZE\];
>
> always_ff @(posedge clk) begin
>
> if (!rst_n) begin
>
> // clear all accumulators
>
> end else if (accum_clear) begin
>
> for (int r = 0; r \< ARRAY_SIZE; r++)
>
> for (int c = 0; c \< ARRAY_SIZE; c++)
>
> accum\[r\]\[c\] \<= \'0;
>
> end else if (accum_en && psum_vld) begin
>
> for (int c = 0; c \< ARRAY_SIZE; c++)
>
> accum\[drain_row_counter\]\[c\] \<= accum\[drain_row_counter\]\[c\] + psum_in\[c\];
>
> end
>
> end
>
> *The drain_row_counter tracks which output row is being received from the bottom of the array during the drain phase. The DMA controller drives this counter and provides it to the output buffer.*

## 10. Module: Accelerator Top (accel_top.sv)

### 10.1 Purpose

accel_top.sv is the integration wrapper. It instantiates all five submodules and connects them. It also exposes the host-facing interface: scratchpad write port, control signals (start, M/K/N sizes), and output read port.

### 10.2 Host Interface

  -----------------------------------------------------------------------------------------------------------------------------------------
  **Signal**                 **Direction**   **Width**                             **Description**
  -------------------------- --------------- ------------------------------------- --------------------------------------------------------
  clk / rst_n                input           1                                     Clock and reset

  start                      input           1                                     Begin computation pulse

  M_size / K_size / N_size   input           16 each                               Matrix dimensions in elements (multiples of TILE_SIZE)

  sp_wr_en                   input           1                                     Host writes a word into the scratchpad

  sp_wr_addr                 input           log2(DEPTH)                           Scratchpad write address

  sp_wr_data                 input           DATA_WIDTH                            Write data

  sp_wr_bank                 input           1                                     Target bank for write

  result_out                 output          ACC_WIDTH × ARRAY_SIZE × ARRAY_SIZE   Output tile after done

  done                       output          1                                     Computation complete

  total_mac_cycles           output          32                                    From sparsity unit

  skipped_mac_cycles         output          32                                    From sparsity unit
  -----------------------------------------------------------------------------------------------------------------------------------------

### 10.3 Internal Connections Summary

The top level simply wires submodule ports together. No logic lives in accel_top.sv --- it is a structural wrapper only. The wiring follows the data path described in Section 2.2.

## 11. Dataflow & Timing Diagrams

### 11.1 Weight-Stationary Dataflow Explained

Consider a 4×4 array (simplified from 16×16 for illustration). The weight tile for B is:

> B = \| b00 b01 b02 b03 \|
>
> \| b10 b11 b12 b13 \|
>
> \| b20 b21 b22 b23 \|
>
> \| b30 b31 b32 b33 \|

After preload: PE\[row=r\]\[col=c\] holds weight b\[r\]\[c\]. During computation, activation row a\[0\] = \[a00, a01, a02, a03\] enters the left column:

> Cycle 1: PE\[0\]\[0\] computes: psum += b00 \* a00
>
> (act a00 starts propagating right, stagger delays rows 1,2,3)
>
> Cycle 2: PE\[0\]\[1\] computes: psum += b01 \* a00
>
> PE\[0\]\[0\] computes: psum += b00 \* a01 (next activation row)
>
> PE\[1\]\[0\] computes: psum += b10 \* a00 (stagger: row 1 delayed by 1)
>
> \...
>
> Cycle N: All PEs have accumulated their contribution to C\[row\]\[col\]

The bottom row of PEs outputs C\[row\]\[col\] values as the wavefront reaches the last row. These are the partial results that the output buffer accumulates.

### 11.2 Cycle-by-Cycle Timing for One Tile (ARRAY_SIZE=4 example)

  -------------------------------------------------------------------------------------------------------------------------------------------------
  **Cycle**   **FSM State**         **Activity**
  ----------- --------------------- ---------------------------------------------------------------------------------------------------------------
  0--3        LOAD_WEIGHTS          DMA shifts B tile into PE weight registers. PE\[0\]\[\*\] loads in cycle 0, PE\[1\]\[\*\] in cycle 1, etc.

  4--7        LOAD_ACTS + COMPUTE   Row 0 of A enters column 0. Staggered: row 1 delayed 1 cycle, row 2 delayed 2 cycles, row 3 delayed 3 cycles.

  8--10       DRAIN                 Last activations in pipeline. Array still accumulating. No new inputs.

  11          ACCUMULATE            Bottom row outputs valid. Output buffer latches and accumulates.

  12          SWAP / next tile      Banks swap. Next K tile begins if K \> TILE_SIZE.
  -------------------------------------------------------------------------------------------------------------------------------------------------

### 11.3 Ping-Pong Timing

While the array computes tile K=0, the host should already be writing tile K=1 into the inactive bank. When tile K=0 finishes and banks swap, tile K=1 is immediately available --- zero stall cycles between tile computations assuming the host keeps up with loading.

> *If the host is slow and the next tile is not ready when the bank swap occurs, the DMA controller must stall in SWAP_BANKS state until the host signals the new tile is ready. Add a tile_ready input from host for a robust implementation.*

## 12. Verification Architecture

### 12.1 Philosophy

Verification is done in two stages: directed tests first, random tests second. Never run random tests on a design that has not already passed directed tests. The directed tests establish baseline correctness; the random tests find corner cases.

### 12.2 Golden Model

A Python script (scripts/golden_model.py) implements the reference:

> import numpy as np
>
> def gemm_int8(A, B):
>
> \# A: \[M, K\] int8, B: \[K, N\] int8
>
> \# Returns C: \[M, N\] int32
>
> return A.astype(np.int32) @ B.astype(np.int32)

The scoreboard calls this function and compares output. The golden model must replicate tiling accumulation in the same order as hardware --- iterate tile_k in the same order and accumulate partial results identically.

### 12.3 UVM Environment

  ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **Component**           **File**            **Role**
  ----------------------- ------------------- -------------------------------------------------------------------------------------------------------------------------------------------
  mac_seq_item            mac_seq_item.sv     Transaction class. Fields: A matrix tile (int8), B matrix tile (int8), expected C (int32), sparsity density (0--100).

  mac_sequence_directed   mac_sequences.sv    Generates specific matrices: identity, all-ones, all-zeros, single nonzero, max values (127/-128), checkerboard sparse.

  mac_sequence_random     mac_sequences.sv    Constrained-random. Randomize all values. Constrain sparsity density as a bias on zero probability. Tile-aligned matrix dimensions.

  mac_driver              mac_driver.sv       Drives A and B tiles into scratchpad write port. Asserts start. Waits for done. Reports timing.

  mac_monitor             mac_monitor.sv      Captures result_out on the cycle done is asserted. Sends to scoreboard.

  mac_scoreboard          mac_scoreboard.sv   Receives DUT output and golden model output. Compares word by word. Fatal error on any mismatch with full matrix printout.

  mac_coverage            mac_coverage.sv     Covergroups: sparsity ratio bins (0%, 1--30%, 31--60%, 61--80%, 81--100%), matrix shapes, tile boundary hits, ping-pong bank transitions.

  mac_env                 mac_env.sv          Top-level UVM env. Instantiates all above.

  mac_test                mac_test.sv         Top-level test. Run directed suite. Then run random until all coverage bins are hit.

  tb_top                  tb_top.sv           Simulation top. Clock gen (10 ns period), reset gen, DUT instantiation, UVM run_test().
  ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

### 12.4 Directed Test Cases

  ----------------------------------------------------------------------------------------------------------------------------
  **Test Case**        **A Matrix**      **B Matrix**    **Purpose**
  -------------------- ----------------- --------------- ---------------------------------------------------------------------
  Identity             I (identity)      Random          Output = B. Verifies passthrough correctness.

  All-zeros A          All 0             Random          Output = 0. Verifies 100% sparsity path.

  All-ones             All 1             All 1           Output = ARRAY_SIZE at every position. Easy manual check.

  Max values           All 127           All 127         Tests accumulator for near-overflow. 127×127×16 = 258,064 \< 2\^32.

  Single nonzero       One 1, rest 0     Identity        Output has one nonzero entry. Isolates single PE path.

  Checkerboard         Alternating 0/1   All 1           50% sparsity. Verifies sparsity counter accuracy.

  Multi-tile (32×32)   Random 32×32      Random 32×32    First multi-tile test. Verifies tiling accumulation.

  Large (64×64)        Random 64×64      Random 64×64    Verifies full DMA tiling loop correctness.
  ----------------------------------------------------------------------------------------------------------------------------

### 12.5 ModelSim Commands

> \# Compile RTL
>
> vlog -sv +incdir+./rtl \\
>
> ./rtl/pe.sv ./rtl/array_top.sv ./rtl/scratchpad.sv \\
>
> ./rtl/dma_ctrl.sv ./rtl/sparsity_unit.sv \\
>
> ./rtl/output_buffer.sv ./rtl/accel_top.sv
>
> \# Compile testbench
>
> vlog -sv +incdir+./tb \\
>
> ./tb/mac_pkg.sv ./tb/mac_seq_item.sv ./tb/mac_sequences.sv \\
>
> ./tb/mac_driver.sv ./tb/mac_monitor.sv ./tb/mac_scoreboard.sv \\
>
> ./tb/mac_coverage.sv ./tb/mac_env.sv ./tb/mac_test.sv ./tb/tb_top.sv
>
> \# Run simulation
>
> vsim -c -do \"run -all; quit\" work.tb_top +UVM_TESTNAME=mac_test
>
> \# Run with waveform dump
>
> vsim -do \"log -r /\*; run -all; quit\" work.tb_top +UVM_TESTNAME=mac_test

## 13. FPGA Synthesis Plan

### 13.1 Target Device

Intel Cyclone V FPGA --- device 5CSEMA5F31C6 (or equivalent available in UW lab). This is the device on the DE1-SoC board.

### 13.2 Resource Expectations

  --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **Resource**                     **Expected Usage**       **Cyclone V Availability**   **Notes**
  -------------------------------- ------------------------ ---------------------------- -----------------------------------------------------------------------------------------------------
  DSP blocks (18×18 multipliers)   Up to 256 (one per PE)   87 DSPs on 5CSEMA5F31C6      Shortfall expected. Quartus will implement remainder in LUTs. Document this --- it shows awareness.

  Block RAMs (M10K)                \~2--4 blocks            308 M10K blocks              Scratchpad banks inferred as BRAMs. More than sufficient.

  LUTs (ALMs)                      \~5,000--15,000          32,070 ALMs                  Control logic, stagger registers, non-DSP MACs. Should be fine.

  Registers (FFs)                  \~3,000--8,000           64,140 FFs                   Pipeline registers. Fine.
  --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

### 13.3 Timing Strategy

-   Target: 100 MHz minimum (10 ns period). Stretch goal: 200 MHz.

-   Most likely critical path: the accumulator chain inside the PE (multiply result + psum_in). If timing fails, add a pipeline register between the multiply and the add --- this adds one cycle of latency to the PE but breaks the critical path.

-   Second most likely: the stagger shift register chain in array_top. If this is the critical path, check that the shift registers are properly registered and not combinationally chained.

-   Use Quartus TimeQuest Timing Analyzer after synthesis. Filter by \'Failing Paths\' and address the top critical path first.

### 13.4 Synthesis Checklist

-   All RTL files added to Quartus project in correct order (packages/parameters first)

-   Top-level module set to accel_top

-   Target device set correctly

-   Run Analysis & Synthesis first (catches most RTL errors without full place & route)

-   Run Fitter (place & route)

-   Run TimeQuest --- confirm timing closure at 100 MHz

-   Check resource utilization report --- record DSP count, BRAM count, ALM count

-   Record Fmax from TimeQuest slow corner analysis

## 14. Performance Analysis & Roofline

### 14.1 The Roofline Model

The roofline model is a visual performance model that shows whether a given workload is limited by compute throughput or memory bandwidth. It plots:

-   X-axis: Arithmetic Intensity (AI) --- operations per byte of memory traffic

-   Y-axis: Achieved performance (GOPS --- billion operations per second)

-   Compute ceiling: peak GOPS the array can deliver (ARRAY_SIZE² × 2 MACs/cycle × Fmax)

-   Memory ceiling: bandwidth × AI --- a diagonal line rising from left to right

A kernel is compute-bound when its AI is high enough to saturate compute. It is memory-bound when bandwidth is the bottleneck.

### 14.2 Formulas

  ----------------------------------------------------------------------------------------------------------------------
  **Metric**                        **Formula**
  --------------------------------- ------------------------------------------------------------------------------------
  Peak GOPS                         ARRAY_SIZE × ARRAY_SIZE × 2 × Fmax_Hz / 1e9

  Scratchpad bandwidth (GB/s)       (DATA_WIDTH / 8) × ARRAY_SIZE × 2 × Fmax_Hz / 1e9 \[2 for act + weight per cycle\]

  Arithmetic Intensity (OPs/byte)   (M × K × N × 2) / ((M × K + K × N) × DATA_WIDTH / 8)

  Achieved GOPS                     (M × K × N × 2) / total_cycles / 1e9 × Fmax_Hz

  PE Utilization                    Achieved GOPS / Peak GOPS × 100%

  Effective GOPS (with sparsity)    Achieved GOPS / (1 − skip_rate)
  ----------------------------------------------------------------------------------------------------------------------

### 14.3 Test Workloads

  -------------------------------------------------------------------------------------------------------------------------
  **Workload**       **M×K×N**     **Sparsity**   **Expected Bound**     **Why**
  ------------------ ------------- -------------- ---------------------- --------------------------------------------------
  Tiny dense         16×16×16      0%             Memory-bound           Single tile --- very low AI, bandwidth dominates

  Medium dense       64×64×64      0%             Compute-bound          Many K tiles --- high AI, compute saturates

  Large dense        256×256×256   0%             Compute-bound          Large --- definitively compute-bound

  50% sparse         64×64×64      50%            Reduced compute util   Half MACs skipped --- effective GOPS drops

  80% sparse         64×64×64      80%            Memory-bound           Most compute skipped --- memory dominates

  Tall-skinny        256×16×256    0%             Memory-bound           Low K dimension → few accumulations per tile

  Wide-flat          16×256×16     0%             Compute-bound          High K → many accumulations

  Real-world proxy   128×128×128   30%            Compute-bound          Typical inference workload shape
  -------------------------------------------------------------------------------------------------------------------------

### 14.4 Analysis Script (scripts/roofline.py)

The roofline.py script takes a CSV of (workload_name, M, K, N, sparsity, total_cycles, skipped_cycles, Fmax) and produces:

-   Roofline plot with compute and bandwidth ceilings as horizontal/diagonal lines

-   Each workload plotted as a point on the roofline

-   Bar chart: PE utilization with and without sparsity skipping, per workload

-   Table: all metrics printed to stdout for the report

## 15. Known Risks & Design Rules

### 15.1 Risk Register

  ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **Risk**                                                                   **Likelihood**   **Impact**                     **Mitigation**
  -------------------------------------------------------------------------- ---------------- ------------------------------ ------------------------------------------------------------------------------------------------------------
  Ping-pong FSM timing bug --- wrong bank active during compute              High             Wrong results                  Draw FSM state diagram on paper before coding. Test bank swap in isolation with directed test.

  Activation stagger off-by-one --- columns misaligned                       High             Wrong results                  Verify with identity matrix test --- output should equal B exactly.

  Tiling accumulation wrong --- partial sums not correctly summed across K   Medium           Wrong results for multi-tile   Test single-tile first. Multi-tile only after single-tile is clean. Golden model must match HW tile order.

  Quartus DSP inference failure --- multipliers in LUTs only                 Medium           Low Fmax, high LUT usage       Expected for 16×16. Document resource report. Meets design goals.

  Timing closure failure at 100 MHz                                          Medium           Must respin RTL                Pipeline accumulator in PE. Check critical path report before giving up.

  UVM scoreboard false pass --- golden model bug                             Low              Missed RTL bugs                Unit test golden model against numpy ground truth independently.

  Sparsity counter overcounting                                              Low              Wrong analysis numbers         Directed test with exactly 50% zeros --- verify counter ratio manually.
  ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

### 15.2 Absolute Design Rules

These rules must never be violated. If something seems like a good reason to break one of them, it isn\'t.

-   Never hardcode ARRAY_SIZE, DATA_WIDTH, or ACC_WIDTH. Always use parameters.

-   Never move to the next development phase until the current phase has passing tests.

-   Never simulate multi-tile behavior before single-tile is verified clean.

-   Never commit RTL that has unresolved latch warnings from ModelSim.

-   Never allow simultaneous read and write to the same scratchpad bank. The DMA FSM must prevent this by construction.

-   Always reset every register in every module. Uninitialized state causes intermittent failures that are very hard to debug.

-   Always run the golden model comparison for every test. Never eyeball waveforms as the only verification.

### 15.3 Integration Order

Build and verify in this exact order. Never integrate a module that has not passed its standalone tests.

  -------------------------------------------------------------------------------------------------------------
  **Step**   **Integrate**                          **Verify With**
  ---------- -------------------------------------- -----------------------------------------------------------
  1          pe.sv alone                            Directed SystemVerilog testbench. MAC, skip, passthrough.

  2          array_top.sv (PEs + stagger)           Single tile weight-stationary GEMM. Identity matrix test.

  3          scratchpad.sv alone                    Read-after-write test. Ping-pong bank isolation test.

  4          dma_ctrl.sv + scratchpad + array_top   Single tile end-to-end. No UVM yet --- directed only.

  5          sparsity_unit.sv integrated            All-zeros activation test. 50% sparse test.

  6          output_buffer.sv integrated            Full single-tile result verified vs golden model.

  7          Multi-tile (full accel_top)            32×32 then 64×64. Verified vs golden model.

  8          Full UVM environment                   Directed suite. Then random until coverage closes.

  9          FPGA synthesis                         Timing and resource report.

  10         Roofline analysis                      All 8 workloads measured and plotted.
  -------------------------------------------------------------------------------------------------------------

