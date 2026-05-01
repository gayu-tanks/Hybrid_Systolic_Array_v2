# Power Estimation — Hybrid Systolic Array v2

## Overview

RTL-level power estimation using switching-activity annotation.
The flow generates a VCD (Value Change Dump) from simulation, then
annotates a post-synthesis gate netlist for absolute power numbers.
Without a technology library, in-simulation **Switching Activity Factor (SAF)**
is used for relative comparisons across modes and input patterns.

```
RTL sim (iverilog) ──► power_sim_v2.vcd ──► vcd2saif ──► power_sim_v2.saif
                                                               │
       synthesised netlist ──────────────────────────────────► power tool
       (DC / Genus / OpenROAD)                        (PrimeTime PX / Joules)
                                                               │
                                                         ◄── mW estimate
```

---

## Design Under Test

| Parameter    | Value |
|---|---|
| Array size   | 8×8 (N=8) |
| Accumulator  | 24-bit block-floating-point |
| Clock period | 10 ns (100 MHz reference) |
| Technology   | Process-independent (RTL only) |

**Supported modes:**

| Mode | Encoding | Activation | Weight | L |
|---|---|---|---|---|
| BF16×BF16 | `3'b001` | BF16 | BF16 | 4 |
| BF16×INT8 | `3'b010` | BF16 | INT8 | 4 |
| BF16×INT4 | `3'b011` | BF16 | INT4 | 2 |
| INT4×INT4 | `3'b100` | INT4 | INT4 | 1 |
| INT8×INT4 | `3'b101` | INT8 | INT4 | 2 |
| INT8×INT8 | `3'b110` | INT8 | INT8 | 4 |

---

## Power Testbench

**File:** `tests/tb_systolic_array_v2_power.v`
**VCD output:** `tests/power_sim_v2.vcd`

### Input Patterns

| Pattern   | Description | Purpose |
|-----------|-------------|---------|
| `PAT_ZERO`   | All inputs = 0x0000 | Leakage reference — no dynamic switching |
| `PAT_RANDOM` | Uniform random, masked to valid bit-width per mode | Typical ML workload |
| `PAT_TOGGLE` | Alternating 0x5555 / 0xAAAA per row/column | Worst-case switching |

For `PAT_RANDOM`, inputs are masked to the valid field width of each mode
(e.g., INT4 weights masked to `0x000F`) so toggling density is realistic.

**TOGGLE pattern construction:**
- Act rows alternate `0x5555_…_5555` / `0xAAAA_…_AAAA` — all 128 bits of the
  activation bus flip between consecutive row loads.
- Weight columns alternate similarly — all 128 bits of the weight bus flip
  between consecutive feed steps.

### Simulation Scenarios (14 total)

| # | Mode      | Pattern | Purpose |
|---|-----------|---------|---------|
| 1  | BF16×BF16 | ZERO    | Leakage reference, L=4 path |
| 2  | BF16×BF16 | RANDOM  | Typical ML workload, L=4 |
| 3  | BF16×BF16 | TOGGLE  | Worst-case switching, L=4 |
| 4  | BF16×INT8 | RANDOM  | Mixed-precision typical, L=4 |
| 5  | BF16×INT4 | RANDOM  | Mixed-precision typical, L=2 |
| 6  | INT4×INT4 | ZERO    | Leakage reference, L=1 path |
| 7  | INT4×INT4 | RANDOM  | Integer low-precision typical, L=1 |
| 8  | INT4×INT4 | TOGGLE  | Worst-case switching, L=1 |
| 9  | INT8×INT4 | ZERO    | Leakage reference, L=2 path |
| 10 | INT8×INT4 | RANDOM  | Integer mixed-precision typical, L=2 |
| 11 | INT8×INT4 | TOGGLE  | Worst-case switching, L=2 |
| 12 | INT8×INT8 | ZERO    | Leakage reference, L=4 INT path |
| 13 | INT8×INT8 | RANDOM  | Integer full-precision typical, L=4 |
| 14 | INT8×INT8 | TOGGLE  | Worst-case switching, L=4 INT path |

---

## Compile and Run

```bash
# Compile
iverilog -g2005 -o tests/sim_v2_power \
    rtl/mult_4x4.v \
    rtl/processing_element_v2.v \
    rtl/systolic_array_v2.v \
    rtl/output_post_processor_v2.v \
    rtl/systolic_array_v2_top.v \
    tests/tb_systolic_array_v2_power.v

# Run (produces power_sim_v2.vcd)
cd tests && vvp sim_v2_power
```

---

## Cycle Count Per Mode

`cycle_count` = hardware counter from `start` pulse to `done` (inclusive).
Activation loading (N=8 cycles) happens before `start` and is not included.

| Mode      | L | Start | Wt Load | Compute        | Drain | cycle_count | sim_cycles* |
|-----------|---|-------|---------|----------------|-------|-------------|-------------|
| BF16×BF16 | 4 | 1     | 8       | 67 (15×4+7)    | 1     | **77**      | 94          |
| BF16×INT8 | 4 | 1     | 8       | 67             | 1     | **77**      | 94          |
| BF16×INT4 | 2 | 1     | 8       | 37 (15×2+7)    | 1     | **47**      | 64          |
| INT4×INT4 | 1 | 1     | 8       | 22 (15×1+7)    | 1     | **32**      | 49          |
| INT8×INT4 | 2 | 1     | 8       | 37             | 1     | **47**      | 64          |
| INT8×INT8 | 4 | 1     | 8       | 67             | 1     | **77**      | 94          |

*sim_cycles includes reset overhead (4 reset + 1 post-reset + 8 act load + cycle_count + 2 extra)

**Formula:**
- Compute cycles = `(2N−1)·L + (N−1)` = `15·L + 7` for N=8
- `cycle_count` = `15·L + 17`
- `sim_cycles` ≈ `cycle_count + 17`

**INT modes are faster** because L is smaller:
- INT4×INT4 saves 45 cycles vs BF16×BF16 (32 vs 77)
- INT8×INT4 saves 30 cycles vs BF16×BF16 (47 vs 77)

---

## Simulation Results

### In-Simulation Switching Activity (Bus-Level SAF)

```
SAF = bus_events / (sim_cycles × bus_width_bits)
```

`bus_events` increments once per cycle in which **any bit** of the 128-bit bus
changes. For bit-accurate activity, post-process `power_sim_v2.vcd` with `vcd2saif`.

| # | Mode      | Pattern | act SAF | wt SAF  | result SAF | cycle_count |
|---|-----------|---------|---------|---------|------------|-------------|
| 1  | BF16×BF16 | ZERO    | 0.0000  | 0.0000  | 0.0000     | 77          |
| 2  | BF16×BF16 | RANDOM  | 0.0007  | 0.0007  | 0.0025     | 77          |
| 3  | BF16×BF16 | TOGGLE  | 0.0007  | 0.0007  | 0.0025     | 77          |
| 4  | BF16×INT8 | RANDOM  | 0.0007  | 0.0007  | 0.0025     | 77          |
| 5  | BF16×INT4 | RANDOM  | 0.0011  | 0.0011  | 0.0037     | 47          |
| 6  | INT4×INT4 | ZERO    | 0.0000  | 0.0000  | 0.0000     | 32          |
| 7  | INT4×INT4 | RANDOM  | 0.0014  | 0.0014  | 0.0026     | 32          |
| 8  | INT4×INT4 | TOGGLE  | 0.0014  | 0.0014  | 0.0026     | 32          |
| 9  | INT8×INT4 | ZERO    | 0.0000  | 0.0000  | 0.0000     | 47          |
| 10 | INT8×INT4 | RANDOM  | 0.0011  | 0.0011  | 0.0037     | 47          |
| 11 | INT8×INT4 | TOGGLE  | 0.0011  | 0.0011  | 0.0037     | 47          |
| 12 | INT8×INT8 | ZERO    | 0.0000  | 0.0000  | 0.0000     | 77          |
| 13 | INT8×INT8 | RANDOM  | 0.0007  | 0.0007  | 0.0025     | 77          |
| 14 | INT8×INT8 | TOGGLE  | 0.0007  | 0.0007  | 0.0025     | 77          |

### Observations

1. **ZERO scenarios confirm leakage isolation** — scenarios 1, 6, 9, 12 show zero
   bus-events, bounding dynamic power contribution to exactly zero for those runs.

2. **RANDOM and TOGGLE SAF are identical at bus level** — the bus-level counter fires
   once per any-bit change, not counting how many bits change per event. Both patterns
   produce 9 act/weight bus events (8 load/feed steps + 1 bus clear). Bit-level
   differences are captured in the VCD.

3. **Shorter modes have higher SAF** — INT4×INT4 (32 cycles) shows SAF=0.0014 vs
   BF16×BF16 (77 cycles) SAF=0.0007 for the same 9 bus events, because SAF divides
   by sim_cycles. Absolute switching energy is the same; SAF is a rate.

4. **result SAF > input SAF** — the output bus changes as results drain column-by-
   column (multiple times per inference pass), yielding higher effective toggle rate
   than the pipelined input feeds.

5. **INT modes have no EHU shift activity** — since `ehu_shift = 0` always for INT×INT
   modes, the alignment shift logic inside each PE is inactive. This should reduce
   internal switching vs BF16 modes, visible in the VCD but not in the port-level SAF.

---

## VCD Analysis (Post-Processing)

### Convert to SAIF

```bash
# Strip testbench path so it matches synthesised module name
vcd2saif -strip_path tb_systolic_array_v2_power/dut \
         -input power_sim_v2.vcd \
         -output power_sim_v2.saif
```

### Synopsys PrimeTime PX

```tcl
read_verilog   systolic_array_v2_top_synth.v   ;# post-synthesis netlist
link_design    systolic_array_v2_top
read_sdc       constraints.sdc
read_vcd -strip_path tb_systolic_array_v2_power/dut power_sim_v2.vcd
update_power
report_power
```

### Cadence Joules RTL Power

```tcl
read_hdl {
    ../rtl/mult_4x4.v
    ../rtl/processing_element_v2.v
    ../rtl/systolic_array_v2.v
    ../rtl/output_post_processor_v2.v
    ../rtl/systolic_array_v2_top.v
}
elaborate systolic_array_v2_top
read_saif power_sim_v2.saif
report_power -hier
```

### OpenROAD (open-source)

```tcl
# After place-and-route
read_saif power_sim_v2.saif
report_power
```

---

## Interpreting Results Without a Technology Library

| Metric | Use |
|---|---|
| ZERO vs RANDOM SAF ratio | Dynamic / (Dynamic + Leakage) split estimate |
| RANDOM vs TOGGLE (per-bit from VCD) | Design-margin headroom |
| INT mode vs BF16 mode result SAF | EHU switching contribution across modes |
| `cycle_count` (mode-dependent) | Normalise to throughput: MACs/cycle or TOPS |

**Estimated throughput (reference, 100 MHz):**

| Mode      | cycle_count | MACs | Throughput |
|-----------|-------------|------|------------|
| BF16×BF16 | 77          | 64   | 64/770 ns ≈ 83 MMAC/s |
| BF16×INT4 | 47          | 64   | 64/470 ns ≈ 136 MMAC/s |
| INT4×INT4 | 32          | 64   | 64/320 ns ≈ 200 MMAC/s |

Scale linearly with frequency for target technology nodes.

---

## SDC Constraints Summary

**File:** `constraints.sdc`

| Constraint | Value | Notes |
|---|---|---|
| Clock period | 2.0 ns (500 MHz) | Reference for synthesis |
| Clock transition | 50 ps | 2.5% of period |
| Clock uncertainty | 50 ps | Jitter/skew margin |
| I/O delay | 0.4 ns (20% of period) | All ports |
| `mode` multicycle | 3 cycles setup, 2 hold | 3-bit, fans to all 64 PEs |
| `cycle_count` multicycle | 2 cycles setup, 1 hold | Sampled only at `done` |
| `result_valid` multicycle | 2 cycles setup, 1 hold | 1-cycle pulse output |
| Max fanout | 16 | All signals |
| Max transition | 200 ps | 4× clock transition |

---

## Limitations

| Limitation | Impact |
|---|---|
| Bus-level SAF only | RANDOM and TOGGLE appear identical; use VCD for bit-accurate activity |
| No technology library | Cannot report absolute power (mW); relative comparison only |
| Single 8×8 pass | Does not model weight-stationary reuse across activation batches |
| No clock-gating in RTL | Real power lower if CG inserted during synthesis |
| Reset cycles in sim_cycles denominator | SAF slightly pessimistic |
| INT EHU inactivity not visible in port SAF | Use internal VCD signals for PE-level breakdown |
