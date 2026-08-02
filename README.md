# Hybrid Systolic Array v2

An 8×8 activation-stationary systolic array in Verilog supporting **six mixed-precision
matrix multiplication modes**. Computes **C = A × W** and produces BF16 outputs for all
modes. Extends v1 (BF16-only) with three pure-integer modes and replaces the dual
parallel 8×4 multipliers with a **single 4×4 shift-and-add multiplier per PE** that
operates over L cycles.

---

## Supported Modes

| Mode | Encoding | Activation | Weight | L (cycles/multiply) |
|------|----------|------------|--------|---------------------|
| BF16×BF16 | `3'b001` | BF16 | BF16  | 4 |
| BF16×INT8 | `3'b010` | BF16 | INT8  | 4 |
| BF16×INT4 | `3'b011` | BF16 | INT4  | 2 |
| INT4×INT4 | `3'b100` | INT4 | INT4  | 1 |
| INT8×INT4 | `3'b101` | INT8 | INT4  | 2 |
| INT8×INT8 | `3'b110` | INT8 | INT8  | 4 |

---

## Module Hierarchy

```
systolic_array_v2_top
├── systolic_array_v2
│   └── processing_element_v2 [N×N]
│       └── mult_4x4 (shift-and-add, 4×4 signed/unsigned)
└── output_post_processor_v2 [N]
```

---

## Key Parameters

| Parameter  | Default | Description |
|------------|---------|-------------|
| `N`        | 8       | Array dimension |
| `ACC_WIDTH`| 24      | Accumulator mantissa width in bits |

---

## Cycle Count (N=8)

Each mode has a fixed cycle count measured by the hardware `cycle_count` register
(from `start` pulse to `done`, inclusive).

| Mode      | L | Start | Wt Load | Compute     | Drain | `cycle_count` | + Act Load | Total |
|-----------|---|-------|---------|-------------|-------|---------------|------------|-------|
| BF16×BF16 | 4 | 1     | 8       | 67          | 1     | **77**        | 8          | 85    |
| BF16×INT8 | 4 | 1     | 8       | 67          | 1     | **77**        | 8          | 85    |
| BF16×INT4 | 2 | 1     | 8       | 37          | 1     | **47**        | 8          | 55    |
| INT4×INT4 | 1 | 1     | 8       | 22          | 1     | **32**        | 8          | 40    |
| INT8×INT4 | 2 | 1     | 8       | 37          | 1     | **47**        | 8          | 55    |
| INT8×INT8 | 4 | 1     | 8       | 67          | 1     | **77**        | 8          | 85    |

- **Compute** = `(2N−1)·L + (N−1)` = `15·L + 7` for N=8
- **`cycle_count`** = `15·L + 17` (does not include activation loading)
- **Total** = `cycle_count + N` = `15·L + 25`

---

## Prerequisites

- [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog`, `vvp`)
- Python 3 with NumPy (`pip install numpy`)

---

## How to Run

> **All commands below are run from the repository root.** Each step is
> self-contained — the `( … )` subshells return you to the root when they finish,
> so the four blocks can be pasted in order.
>
> The simulation itself **must** run with `tests/` as the working directory: the
> testbench opens `../vectors/*.hex` by relative path. Running `vvp tests/sim_v2`
> from the root instead will abort with a vector-load error.

**Step 1 — Generate test vectors**
```bash
(cd vectors && python3 gen_vectors.py)
```
Creates `act_<mode>.hex`, `wt_<mode>.hex`, and `gold_<mode>.hex` for all 6 modes.

**Step 2 — Compile functional testbench**
```bash
iverilog -g2005 -o tests/sim_v2 \
    rtl/mult_4x4.v \
    rtl/processing_element_v2.v \
    rtl/systolic_array_v2.v \
    rtl/output_post_processor_v2.v \
    rtl/systolic_array_v2_top.v \
    tests/tb_systolic_array_v2.v
```

**Step 3 — Run functional simulation**
```bash
(cd tests && vvp sim_v2)
```
Exits **0** only if all 6 modes pass; exits **1** on any tolerance failure or if
the test vectors fail to load.

**Step 4 — Compile and run power testbench**
```bash
iverilog -g2005 -o tests/sim_v2_power \
    rtl/mult_4x4.v \
    rtl/processing_element_v2.v \
    rtl/systolic_array_v2.v \
    rtl/output_post_processor_v2.v \
    rtl/systolic_array_v2_top.v \
    tests/tb_systolic_array_v2_power.v

(cd tests && vvp sim_v2_power)
```

**Step 5 — View waveforms (optional)**
```bash
gtkwave tests/tb_systolic_array_v2.vcd &     # functional run
gtkwave tests/power_sim_v2.vcd &             # power run
```
Both VCDs are written by the testbenches during Steps 3 and 4 via
`$dumpfile`/`$dumpvars`, so re-run those after any RTL change to refresh them.

The window opens empty. Expand `tb_systolic_array_v2` → `dut` in the hierarchy
panel, select signals, press **Insert** to add them, then `Ctrl+Alt+F` to fit the
full run. A useful starting set under `tb_systolic_array_v2.dut`:

```
clk, rst, start, busy, done
mode[2:0]            (right-click → Data Format → Binary)
cycle_count[15:0]
bf16_result[15:0], result_valid
```

All six modes share one file, so track `mode[2:0]` to locate a given mode's window:
`001` → `010` → `011` → `100` → `101` → `110`.

For deeper debug, the scope paths are:

| Block | Path |
|---|---|
| PE (row `i`, col `j`) | `tb_systolic_array_v2.dut.u_sa.gen_row[i].gen_col[j].u_pe` |
| Its 4×4 multiplier | `…gen_col[j].u_pe.u_mult` |
| Output post-processor (row `i`) | `tb_systolic_array_v2.dut.gen_pp[i].u_pp` |

Watching `mult_cnt` inside `u_mult` shows the multiplier stepping through its L
passes (L = 4, 2, or 1 depending on mode — see the mode table above).

---

## Expected Output (Functional Testbench)

```
=== Mode 3'b001 (BF16 x BF16) ===
  Cycle count: 77
  PASS (all 64 results within 2%)

=== Mode 3'b010 (BF16 x INT8) ===
  Cycle count: 77
  PASS (all 64 results within 5%)

=== Mode 3'b011 (BF16 x INT4) ===
  Cycle count: 47
  PASS (all 64 results within 15%)

=== Mode 3'b100 (INT4 x INT4) ===
  Cycle count: 32
  PASS (all 64 results within 0%)

=== Mode 3'b101 (INT8 x INT4) ===
  Cycle count: 47
  PASS (all 64 results within 0%)

=== Mode 3'b110 (INT8 x INT8) ===
  Cycle count: 77
  PASS (all 64 results within 0%)

All modes done.
Output files written to vectors/:
  hw_output_log.txt        — combined log (hex + float + error)
  hw_<mode>.hex            — per-mode hex (diff against gold_<mode>.hex)

RESULT: all 6 modes PASSED
```

Pass/fail tolerances reflect inherent EHU precision loss in BF16 modes;
INT×INT modes are numerically exact.

### Vector-load guard

`$readmemh` leaves a memory untouched when the file cannot be opened, so running
the simulation from the wrong directory would otherwise compare uninitialised data
against uninitialised data and report **PASS** on all six modes. The testbench
poisons `act_mem`/`wt_mem`/`gold_mem` with `X` before each load and verifies every
entry was overwritten, aborting with exit code 1 if not:

```
  *** VECTOR LOAD FAILED for bf16_bf16 ***
  192 of 192 entries were never initialised.

  The testbench reads ../vectors/*.hex relative to the
  current directory, so it must be run from tests/:
      cd tests && vvp sim_v2
```

This catches both a missing file and a truncated/partial one.

## Manual Output Comparison

After simulation, the following files are written to `vectors/`:

| File | Description |
|------|-------------|
| `hw_<mode>.hex` | Hardware output, one 4-digit hex per line — same format as `gold_<mode>.hex` |
| `hw_output_log.txt` | All 6 modes: row, col, hw_hex, gold_hex, hw_float, gold_float, rel_err_% |

```bash
# Exact binary comparison for integer modes (expect no diff)
diff vectors/hw_int4_int4.hex vectors/gold_int4_int4.hex
diff vectors/hw_int8_int4.hex vectors/gold_int8_int4.hex
diff vectors/hw_int8_int8.hex vectors/gold_int8_int8.hex

# Show only elements with non-zero error across all modes
grep -v "0\.0000$" vectors/hw_output_log.txt
```

---

## File Structure

```
hybrid_systolic_array_v2/
├── rtl/
│   ├── systolic_array_v2_top.v       Top-level FSM + weight buffer + j-skew delivery
│   ├── systolic_array_v2.v           N×N PE mesh, horizontal/vertical wiring
│   ├── processing_element_v2.v       PE: multi-cycle multiply, inline EHU, accumulator
│   ├── mult_4x4.v                    4×4 shift-and-add multiplier primitive
│   └── output_post_processor_v2.v    BFP/integer → BF16 conversion with K correction
├── tests/
│   ├── tb_systolic_array_v2.v        Self-checking functional testbench (all 6 modes)
│   └── tb_systolic_array_v2_power.v  Power estimation testbench (14 scenarios)
├── vectors/
│   ├── gen_vectors.py                Test vector generator (Python/NumPy)
│   ├── act_<mode>.hex                Activation matrices (one per mode)
│   ├── wt_<mode>.hex                 Weight matrices (one per mode)
│   ├── gold_<mode>.hex               Golden reference outputs (one per mode)
│   ├── hw_<mode>.hex                 Hardware outputs — written after each sim run
│   └── hw_output_log.txt             Combined log: hex + float + error for all modes
├── constraints.sdc                   Synopsys SDC timing constraints (500 MHz)
├── project.md                        Full technical architecture description
└── power.md                          Power estimation methodology and results
```

---

## Further Reading

- [project.md](project.md) — detailed architecture, dataflow, timing derivation, and
  known limitations
- [power.md](power.md) — power estimation methodology, SAF results, and downstream
  tool flow
