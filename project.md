# Hybrid Systolic Array v2 — Project Report

---

## 1. Overview

This project implements an 8×8 **activation-stationary systolic array** in RTL (Verilog)
that computes C = A × W in six mixed-precision modes. It extends v1 (three BF16-dominant
modes, dual 8×4 multipliers per PE) with the following key changes:

- **Three new pure-integer modes:** INT4×INT4, INT8×INT4, INT8×INT8
- **Single 4×4 shift-and-add multiplier per PE** (replaces two parallel 8×4 multipliers)
- **Multi-cycle operation:** L=1, 2, or 4 cycles per multiply depending on mode
- **No internal column skew registers:** top-level pre-skews weight delivery using a
  weight buffer (`wt_buf`) and per-column timing logic
- **Reduced accumulator width:** ACC_WIDTH=24 (down from 44), analytically proven safe

| Mode      | Encoding | Activation | Weight | L |
|-----------|----------|------------|--------|---|
| BF16×BF16 | `3'b001` | BF16       | BF16   | 4 |
| BF16×INT8 | `3'b010` | BF16       | INT8   | 4 |
| BF16×INT4 | `3'b011` | BF16       | INT4   | 2 |
| INT4×INT4 | `3'b100` | INT4       | INT4   | 1 |
| INT8×INT4 | `3'b101` | INT8       | INT4   | 2 |
| INT8×INT8 | `3'b110` | INT8       | INT8   | 4 |

---

## 2. Numerical Representation

### 2.1 BF16 Format

```
[15]   [14:7]      [6:0]
sign   exponent    fraction
        (8 bits)   (7 bits)
```

- Bias: 127 (same as IEEE 754 float32)
- Normal value: (−1)^sign × 2^(exp−127) × 1.fraction
- Mantissa integer: `{1, frac[6:0]}` = 8-bit unsigned, range 128–255

### 2.2 Integer Formats

| Format | Bits | Range    | Packing in 16-bit word |
|--------|------|----------|------------------------|
| INT4   | 4    | −8..7    | `[3:0]` (signed 2's complement) |
| INT8   | 8    | −128..127| `[7:0]` (signed 2's complement) |

### 2.3 Block Floating Point (BFP) Accumulation

Each PE row maintains a shared exponent `exp_acc` across all N partial products.
At each accumulation step the EHU (Exponent Handling Unit, inlined per PE):

1. Compares `exp_product` vs `exp_acc_in`
2. Right-shifts the smaller operand to align with the larger exponent
3. Adds aligned mantissas
4. Propagates the larger exponent as `exp_acc_out`

For INT×INT modes, both exponents are forced to 0, so `ehu_shift = 0` always —
the EHU performs pure integer addition with no alignment.

### 2.4 Accumulator Width Analysis

Maximum accumulator value per mode (N=8 products):

| Mode      | Max single product | Max sum (N=8) | Bits needed |
|-----------|--------------------|---------------|-------------|
| INT4×INT4 | 64                 | 512           | 10          |
| INT8×INT4 | 1,024              | 8,192         | 14          |
| INT8×INT8 | 16,384             | 131,072       | 18          |
| BF16×INT4 | 1,785              | 14,280        | 15          |
| BF16×INT8/BF16 | 65,025        | 520,200       | 21          |

Hard lower bound from partial product shift: `pp_contrib` = 9-bit `m_out` shifted
left by up to 8 bits → 17 bits minimum. ACC_WIDTH=24 gives comfortable headroom
over all modes.

---

## 3. Architecture

### 3.1 Module Hierarchy

```
systolic_array_v2_top          Top-level: FSM, weight buffer, j-skew delivery
├── systolic_array_v2          N×N PE mesh, horizontal/vertical wiring
│   └── processing_element_v2  [N×N instances]
│       └── mult_4x4           4×4 shift-and-add multiplier
└── output_post_processor_v2   [N instances, one per row]
```

### 3.2 `systolic_array_v2_top`

**Ports:**

| Port             | Dir | Width        | Description |
|------------------|-----|--------------|-------------|
| `clk`, `rst`     | in  | 1            | Clock, synchronous reset |
| `mode`           | in  | 3            | Operating mode |
| `act_row_data`   | in  | N×16         | One row of activations |
| `act_row_idx`    | in  | log2(N)      | Which row to load |
| `act_load_en`    | in  | 1            | Latch activation row |
| `weight_col_data`| in  | N×16         | N weights (one per column) |
| `weight_feed_en` | in  | 1            | Weight data valid |
| `start`          | in  | 1            | Begin computation |
| `busy`, `done`   | out | 1            | FSM status |
| `cycle_count`    | out | 16           | Hardware cycle counter |
| `bf16_result`    | out | N×16         | BF16 result, one per row |
| `result_valid`   | out | N            | Per-row result valid pulse |

**FSM States:** IDLE → LOAD → COMPUTE → DRAIN → DONE

**Weight buffer:** `wt_buf[N][N]` — all N×N weights are stored in S_LOAD before
compute begins. During S_COMPUTE, the top-level reads from `wt_buf` and drives
`weight_col_timed[j]` at the correct compute_cycle for each column j.

**L decode:**
```
mode = INT4×INT4           → mult_lat_log = 0  → L = 1
mode = BF16×INT4, INT8×INT4 → mult_lat_log = 1 → L = 2
mode = BF16×BF16, BF16×INT8, INT8×INT8 → mult_lat_log = 2 → L = 4
```

### 3.3 `systolic_array_v2`

An N×N mesh of `processing_element_v2` instances with two sets of inter-PE wires:

**Vertical (weight, top-to-bottom):**
- `weight_v[0][j]` = `weight_col_timed[j]` (from top-level, wire)
- `weight_v[i+1][j]` = `weight_out` of PE[i][j] (registered)
- `weight_valid_v[0][j]` = `weight_valid_timed[j]`
- `weight_valid_v[i+1][j]` = `weight_valid_out` of PE[i][j]

**Horizontal (accumulator, left-to-right):**
- `acc_h[i][0]` = 0, `exp_acc_h[i][0]` = 0, `acc_valid_h[i][0]` = 0
- `acc_h[i][j+1]` = `acc_out` of PE[i][j]

**Result valid:** `result_valid[i] = weight_valid_v[i+1][N-1]` — uses the
`weight_valid_out` pulse of the rightmost PE (a 1-cycle pulse), not `acc_valid`
which stays high during idle pass-through.

### 3.4 `processing_element_v2`

Each PE holds one activation element and processes N weight steps sequentially.

**Key registers:**

| Register     | Width      | Description |
|--------------|------------|-------------|
| `act_reg`    | 16         | Stationary activation, loaded once |
| `wt_hold`    | 16         | Latched weight for current step |
| `pp_acc`     | ACC_WIDTH  | Partial product accumulator (within one step) |
| `acc_out`    | ACC_WIDTH  | Running dot-product accumulator (across steps) |
| `mult_cnt`   | 3          | Cycle counter within L-cycle multiply (0..L-1) |
| `mult_busy`  | 1          | High during cycles 1..L-1 of a multiply |

**Multi-cycle multiply schedule:**

For each step k, the PE performs L partial products using the single 4×4 multiplier.
The operands presented to `mult_4x4` at each cycle (cnt=0..L-1) depend on mode:

| Mode      | L | cnt=0           | cnt=1           | cnt=2           | cnt=3           |
|-----------|---|-----------------|-----------------|-----------------|-----------------|
| BF16×BF16 | 4 | act_lo × wt_lo  | act_lo × wt_hi  | act_hi × wt_lo  | act_hi × wt_hi  |
| BF16×INT8 | 4 | act_lo × wt_lo  | act_lo × wt_hi* | act_hi × wt_lo  | act_hi × wt_hi* |
| BF16×INT4 | 2 | act_lo × wt_lo  | act_hi × wt_lo  | —               | —               |
| INT4×INT4 | 1 | act × wt        | —               | —               | —               |
| INT8×INT4 | 2 | act_lo × wt     | act_hi × wt*    | —               | —               |
| INT8×INT8 | 4 | act_lo × wt_lo  | act_lo × wt_hi* | act_hi × wt_lo  | act_hi × wt_hi* |

*signed weight nibble (b_signed=1 for MSN of 2's complement integers)

`pp_acc` accumulates partial products across cnt=0..L-2; at cnt=L-1 (`last_cycle`),
the final partial product is added, producing `full_product`.

**EHU (inlined in PE):**

```
exp_product = act_exp + wt_exp − 127   (BF16×BF16)
            = act_exp                   (BF16×INT, wt_exp=0)
            = 0                         (INT×INT, both exponents=0)

ehu_swap    = exp_product > exp_acc_in  (product is larger)
ehu_shift   = |exp_product − exp_acc_in|
ehu_result  = larger + (smaller >>> ehu_shift)
```

**Zero-product bypass:** If `full_product == 0` (e.g., from a ±0.0 BF16 weight),
the EHU is bypassed entirely: `acc_out = acc_in`, `exp_acc_out = exp_acc_in`.
This prevents a zero mantissa from corrupting the accumulated exponent.

**Weight propagation (systolic, vertical):**

- At `last_cycle`: `weight_out <= wt_hold`, `weight_valid_out <= 1`
- For L=1: `weight_out <= weight_in` (same cycle as arrival)
- The registered `weight_out` drives the row below via `weight_v[i+1][j]`
- `weight_valid_out` pulses for exactly 1 cycle, triggering the downstream PE

**Accumulator pass-through (cycles 0..L-2):**
During intermediate partial-product cycles, `acc_out <= acc_in` (pass-through).
This ensures the left neighbour's final result is available exactly at the PE's
own `last_cycle` (see timing proof below).

### 3.5 `mult_4x4`

4×4 signed/unsigned multiplier, shift-and-add (no `*` operator):

```verilog
a_ext = a_signed ? {a[3], a} : {1'b0, a}   // 5-bit sign extension
pp0   = b[0] ? sign_extend(a_ext)       : 0
pp1   = b[1] ? sign_extend(a_ext) << 1  : 0
pp2   = b[2] ? sign_extend(a_ext) << 2  : 0
pp3   = b[3] ? sign_extend(a_ext) << 3  : 0

product = b_signed ? (pp0+pp1+pp2 - pp3) : (pp0+pp1+pp2 + pp3)
```

Output: 9-bit signed. The MSB partial product is subtracted for signed `b`
(2's complement weight nibble), added for unsigned.

### 3.6 `output_post_processor_v2`

Converts the 24-bit signed BFP accumulator to BF16.

**Exponent correction (K):**

| Mode          | corrected_exp       | Reason |
|---------------|---------------------|--------|
| BF16×BF16     | `acc_exp − 14`      | Both mantissas are 8-bit integers (×128 each): 7+7=14 |
| BF16×INT8     | `acc_exp − 7`       | One BF16 mantissa contributes ×128 |
| BF16×INT4     | `acc_exp − 7`       | Same as BF16×INT8 |
| INT4×INT4     | `127`               | Pure integer; exponent field unused |
| INT8×INT4     | `127`               | Pure integer |
| INT8×INT8     | `127`               | Pure integer |

**Normalization:**
1. Find MSB position of `|acc_mantissa|`
2. `final_exp = corrected_exp + msb_pos`
3. Shift accumulator so leading 1 is at bit 7 → extract `frac[6:0]`
4. Pack `{sign, final_exp[7:0], frac}` as BF16

Edge cases: zero → `{sign, 15'b0}`; overflow → infinity; underflow → subnormal.

---

## 4. Dataflow and Timing

### 4.1 Operating Sequence

```
Phase 0 — Activation Load (N cycles, before start)
  For row i = 0..N-1:
    Assert act_load_en, drive act_row_data and act_row_idx = i
    All PEs in row i latch activation_in into act_reg

Phase 1 — Weight Load (S_LOAD, N cycles, counted in cycle_count)
  Pulse start=1 (FSM: IDLE→LOAD, cycle_running=1)
  For step k = 0..N-1:
    Drive weight_col_data = column k of W, assert weight_feed_en=1
    FSM stores wt_buf[k][j] = weight_col_data[j] for all j
    (1 cycle per step)

Phase 2 — Compute (S_COMPUTE, (2N-1)·L+(N-1) cycles)
  FSM counts compute_cycle = 0..(2N-1)·L+(N-2)
  Each cycle, top-level drives weight_col_timed[j] = wt_buf[step_idx][j]
  where step_idx = (compute_cycle - j) / L  (valid only when aligned and in-range)
  Weights propagate top-to-bottom through PE rows via weight_out
  Accumulators flow left-to-right through PE columns

Phase 3 — Drain (S_DRAIN, 1 cycle)
  cycle_count_r latched

Phase 4 — Done (S_DONE, 1 cycle)
  done=1 asserted, FSM returns to IDLE
```

### 4.2 J-Skew Weight Delivery

Column j receives step k when:
```
compute_cycle = k·L + j
```

Top-level validity check for column j:
```
diff          = compute_cycle − j
no_underflow  = compute_cycle ≥ j
aligned       = (diff & (L−1)) == 0      // diff divisible by L
step_idx      = diff >> log2(L)
step_in_range = step_idx < N
valid         = in_compute AND no_underflow AND aligned AND step_in_range
```

This produces a triangular injection pattern (wider columns get their first weight later):

```
Example N=4, L=2:
cc:   0    1    2    3    4    5    6    7    8    9
col0: k0   —    k1   —    k2   —    k3   —    —    —
col1: —    k0   —    k1   —    k2   —    k3   —    —
col2: —    —    k0   —    k1   —    k2   —    k3   —
col3: —    —    —    k0   —    k1   —    k2   —    k3
```

### 4.3 PE Timing and Handshake

PE[i][j] receives `weight_valid_in` for step k at:
```
compute_cycle = (k + i) · L + j
                 ─────────────   ──
                 vertical delay   j-skew
```

For L>1, `last_cycle` fires L-1 cycles later at:
```
compute_cycle = (k + i) · L + j + (L − 1)
```

At `last_cycle`:
- `acc_out` is updated with the EHU result
- `weight_valid_out` pulses for 1 cycle → triggers PE[i+1][j]
- `weight_out` is driven with `wt_hold` → available to PE[i+1][j].weight_in

**Accumulator timing proof (for any L):**

PE[i][j-1] `last_cycle` at cc = (k+i)·L + (j-1) + (L-1) = (k+i)·L + j + L - 2

PE[i][j] `last_cycle` at cc = (k+i)·L + j + (L-1)

PE[i][j-1] updates `acc_out` one cycle before PE[i][j]'s `last_cycle`. PE[i][j]
reads `acc_in` at its `last_cycle` — exactly when PE[i][j-1]'s result is available. ✓

### 4.4 Cycle Count Derivation

**Compute phase duration:**

Last PE to finish: PE[N-1][N-1], last step k=N-1.

```
Receives weight_valid_in at: (N-1 + N-1) · L + (N-1) = (2N-2)·L + (N-1)
Finishes L-1 cycles later:  (2N-2)·L + (N-1) + (L-1) = (2N-1)·L + (N-2)
```

That value is `compute_max`. Number of compute cycles = `compute_max + 1`:
```
compute cycles = (2N-1)·L + (N-1)
```

Contribution of each term:

| Term    | N=8,L=4 | Meaning |
|---------|---------|---------|
| (N-1)·L | 28      | Last step k=N-1 enters row 0 at cc=(N-1)·L |
| (N-1)·L | 28      | Propagates down N-1 rows, L cycles per hop |
| (N-1)   | 7       | Column j-skew: last column starts N-1 cycles late |
| L       | 4       | Last PE needs L cycles to complete its multiply |
| **Total** | **67** | **(2N-1)·L + (N-1)** |

**Full cycle_count breakdown (N=8):**

```
cycle_count = 1 (start) + N (weight load) + (2N-1)·L + (N-1) (compute) + 1 (drain)
            = 15·L + 17
```

| Mode      | L | Start | Wt Load | Compute | Drain | cycle_count |
|-----------|---|-------|---------|---------|-------|-------------|
| INT4×INT4 | 1 | 1     | 8       | 22      | 1     | 32          |
| BF16×INT4 | 2 | 1     | 8       | 37      | 1     | 47          |
| INT8×INT4 | 2 | 1     | 8       | 37      | 1     | 47          |
| BF16×BF16 | 4 | 1     | 8       | 67      | 1     | 77          |
| BF16×INT8 | 4 | 1     | 8       | 67      | 1     | 77          |
| INT8×INT8 | 4 | 1     | 8       | 67      | 1     | 77          |

**End-to-end total (including activation loading):**

```
total = N + cycle_count = 15·L + 25
```

| Mode      | L | cycle_count | + Act Load | Total |
|-----------|---|-------------|------------|-------|
| INT4×INT4 | 1 | 32          | 8          | 40    |
| BF16×INT4 | 2 | 47          | 8          | 55    |
| INT8×INT4 | 2 | 47          | 8          | 55    |
| BF16×BF16 | 4 | 77          | 8          | 85    |
| BF16×INT8 | 4 | 77          | 8          | 85    |
| INT8×INT8 | 4 | 77          | 8          | 85    |

### 4.5 Concrete Dataflow Example (N=4, L=2)

Weight injection at top of array (weight_col_timed):
```
cc:   0    1    2    3    4    5    6    7    8    9
col0: k0   —    k1   —    k2   —    k3   —    —    —
col1: —    k0   —    k1   —    k2   —    k3   —    —
col2: —    —    k0   —    k1   —    k2   —    k3   —
col3: —    —    —    k0   —    k1   —    k2   —    k3
```

PE computation grid (start cc → finish cc per step k):
```
         col0        col1        col2        col3
row0:  k0: 0→1    k0: 1→2    k0: 2→3    k0: 3→4
       k1: 2→3    k1: 3→4    k1: 4→5    k1: 5→6
       k2: 4→5    k2: 5→6    k2: 6→7    k2: 7→8
       k3: 6→7    k3: 7→8    k3: 8→9    k3: 9→10

row1:  k0: 2→3    k0: 3→4    k0: 4→5    k0: 5→6
       k1: 4→5    k1: 5→6    k1: 6→7    k1: 7→8
       k2: 6→7    k2: 7→8    k2: 8→9    k2: 9→10
       k3: 8→9    k3: 9→10   k3:10→11   k3:11→12

row2:  k0: 4→5    k0: 5→6    k0: 6→7    k0: 7→8
       k1: 6→7    k1: 7→8    k1: 8→9    k1: 9→10
       k2: 8→9    k2: 9→10   k2:10→11   k2:11→12
       k3:10→11   k3:11→12   k3:12→13   k3:13→14

row3:  k0: 6→7    k0: 7→8    k0: 8→9    k0: 9→10
       k1: 8→9    k1: 9→10   k1:10→11   k1:11→12
       k2:10→11   k2:11→12   k2:12→13   k2:13→14
       k3:12→13   k3:13→14   k3:14→15   k3:15→16 ← last
```

compute_max = 16 = (2×4-1)×2 + (4-2) ✓

---

## 5. Testing

### 5.1 Vector Generation (`vectors/gen_vectors.py`)

Python/NumPy script that generates random matrices for all 6 modes and computes
golden references using Python arithmetic. For each mode, three `.hex` files:

| File                  | Content |
|-----------------------|---------|
| `act_<mode>.hex`      | N×N activation matrix (BF16 or INT packed in 16-bit words) |
| `wt_<mode>.hex`       | N×N weight matrix |
| `gold_<mode>.hex`     | N×N expected result in BF16 |

After simulation, the testbench writes two additional output files:

| File                  | Content |
|-----------------------|---------|
| `hw_<mode>.hex`       | Hardware output, one 4-digit hex per line — same format as `gold_<mode>.hex` |
| `hw_output_log.txt`   | Combined log for all 6 modes: row, col, hw_hex, gold_hex, hw_float, gold_float, rel_err_% |

For INT×INT modes the hex files can be compared directly:
```bash
diff vectors/hw_int4_int4.hex vectors/gold_int4_int4.hex   # expects no output
```
For BF16 modes, the log file shows per-element floating-point values and relative
errors, useful for diagnosing which elements and which magnitude ranges are most
affected by EHU alignment truncation.

### 5.2 Functional Testbench (`tests/tb_systolic_array_v2.v`)

Runs all 6 modes sequentially. Per mode:
1. `$readmemh` loads act/wt/gold from hex files
2. Resets DUT, sets `mode`
3. Loads N activation rows (one per clock via `act_load_en`)
4. Pulses `start`, feeds N weight columns (one per clock via `weight_feed_en`)
5. Captures 64 results by monitoring `result_valid` pulses (1-cycle pulse per row per step)
6. Decodes BF16 results and golden reference to `real`, computes relative error
7. Reports PASS/FAIL

**Tolerance per mode:**

| Mode      | Tolerance | Reason |
|-----------|-----------|--------|
| BF16×BF16 | 2%        | EHU alignment truncation |
| BF16×INT8 | 5%        | EHU uses act_exp only; up to 5-bit exponent spread |
| BF16×INT4 | 15%       | EHU alignment + coarse 4-bit weight |
| INT4×INT4 | 0.1%      | Exact integer arithmetic |
| INT8×INT4 | 0.1%      | Exact integer arithmetic |
| INT8×INT8 | 0.1%      | Exact integer arithmetic |

### 5.3 Simulation Results

All 6 modes pass on an 8×8 random matrix:

| Mode      | cycle_count | Status |
|-----------|-------------|--------|
| BF16×BF16 | 77          | PASS   |
| BF16×INT8 | 77          | PASS   |
| BF16×INT4 | 47          | PASS   |
| INT4×INT4 | 32          | PASS   |
| INT8×INT4 | 47          | PASS   |
| INT8×INT8 | 77          | PASS   |

---

## 6. Known Limitations

### 6.1 BFP Precision Loss in Mixed Modes

BFP uses a single shared exponent per row. When activations span a wide exponent
range (e.g., 5 bits), the EHU alignment shifts discard low-order bits of smaller-
exponent products before accumulation. This is the root cause of the 5% tolerance
for BF16×INT8 and 15% for BF16×INT4.

### 6.2 EHU Uses Activation Exponent Only for Mixed Modes

`exp_product = act_exp` for BF16×INT modes (integer weights have no exponent).
The true magnitude of `act × int_weight` also depends on the weight value, which
is not captured in the exponent. This is an architectural approximation.

### 6.3 Zero-Product Bypass Required for ±0.0 BF16

A BF16 weight of ±0.0 has exponent field = 0, but the EHU applies a synthetic
`eff_wt_exp = 1`, giving `exp_product = 254` for large activations. Without the
zero bypass, the EHU would shift the accumulator right by 128+ bits, zeroing it.
The bypass detects `full_product == 0` and passes `acc_in` through unchanged.

### 6.4 Truncation (No Rounding)

The output post-processor truncates when extracting the 7-bit BF16 fraction.
This is consistent with the golden model but introduces up to 1 ULP of error.

### 6.5 No Double-Buffering

Activation loading and computation are non-overlapping phases. A double-buffered
design would allow loading the next tile while the current tile computes.

### 6.6 Accumulator Overflow

ACC_WIDTH=24 is safe for N=8. For larger N, the BF16×BF16 maximum sum grows as
N × 65025; overflow occurs when N × 65025 ≥ 2^23 ≈ 8.4M, i.e., N > 129.
