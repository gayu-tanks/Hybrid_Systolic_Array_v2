# Throughput and FLOP Analysis

Derivation of operation counts and throughput for the six mixed-precision modes of
the 8×8 hybrid systolic array, and the answer to a specific question: **if BF16×BF16
throughput is A, what is it for BF16×INT8 and BF16×INT4?**

**Short answer:** BF16×INT8 = **A** (no gain at all). BF16×INT4 = **1.64 A**
(2.00 A asymptotically).

---

## 1. Counting the Operations

### 1.1 The algorithmic count

The array computes `C = A × W`. For A of shape M×K and W of shape K×N, each output
element is a length-K dot product:

```
C[i][j] = Σ (k = 0 .. K-1)  A[i][k] · W[k][j]
```

That inner sum is **K multiplies** and **K−1 adds** (the accumulator starts at zero,
so the first term needs no addition). There are **M·N** output elements, giving:

| Quantity | Expression | N = 8 |
|---|---|---|
| Multiplies | M·N·K | 512 |
| Adds | M·N·(K−1) | 448 |
| **Exact total** | M·N·(2K−1) | **960** |
| **Conventional total** | **2·M·N·K** | **1024** |

The conventional **2·M·N·K** figure treats a multiply-accumulate as exactly 2 FLOPs
and ignores the missing first add. It overcounts by M·N = 64 phantom adds (6.7%).

**Use 2·M·N·K = 1024.** It is what NVIDIA, MLPerf, and essentially every published
TOPS/TFLOPS number uses, so it is the only count that compares meaningfully against
external hardware. The exact 960 figure is noted here only so the discrepancy is not
mistaken for an error later.

So: **1 GEMM = 512 MACs = 1024 FLOPs.**

### 1.2 Cross-check against the hardware

The count above is algorithmic. It is worth confirming the RTL actually performs that
many MACs, rather than assuming it.

The array is **activation-stationary** (`systolic_array_v2.v:5`):

- `PE[i][j]` holds activation `A[i][j]` — loaded once, never moves. The column index
  `j` is therefore the **contraction index k**.
- Weights stream **vertically** down each column (`weight_v[i][j]`).
- Partial sums flow **horizontally** left-to-right along each row
  (`acc_h[i][j]` → `acc_h[i][j+1]`, `systolic_array_v2.v:82-86`).

So the value emerging from the right edge of row `i` is
`Σ_j A[i][j] · W[j][col]` = `C[i][col]`, which is exactly the dot product above.

Counting from the hardware side:

```
8 weight columns pass through each PE
    × 1 MAC per column per PE
    × 64 PEs
    = 512 MACs = 1024 FLOPs        ✓ matches 2·M·N·K
```

Each PE performs one MAC per weight column that streams past it. Eight columns, 64
PEs, 512 MACs. The two derivations agree.

> **Note on `power.md`:** the throughput table currently lists `MACs = 64` for every
> mode. 64 is the number of **output elements** (equivalently, the PE count), not the
> MAC count of a GEMM — each output is itself a length-8 dot product. Every
> throughput figure in that table is **8× low**. See §5.

---

## 2. Where the Cycle Count Comes From

Each PE contains a single **4×4 shift-and-add multiplier** (`mult_4x4.v`) that is
iterated over **L** cycles. L is set entirely by how many 4-bit nibbles each operand
occupies:

```
L = ceil(act_bits / 4) × ceil(wt_bits / 4)
```

| Operand | Effective width | Nibbles | Source |
|---|---|---|---|
| BF16 mantissa | 8 bits (1 implicit + 7 stored) | 2 | `processing_element_v2.v:100-105` |
| INT8 | 8 bits | 2 | same |
| INT4 | 4 bits | 1 | same |

This is the crux of the whole analysis. **BF16 and INT8 occupy the same number of
nibbles**, so they cost the same number of passes.

| Mode | Act nibbles | Wt nibbles | L | Case arm |
|---|---|---|---|---|
| BF16×BF16 | 2 | 2 | **4** | `processing_element_v2.v:121-127` |
| BF16×INT8 | 2 | 2 | **4** | `processing_element_v2.v:128-134` |
| BF16×INT4 | 2 | 1 | **2** | `processing_element_v2.v:135-139` |
| INT4×INT4 | 1 | 1 | 1 | `processing_element_v2.v:140-141` |
| INT8×INT4 | 2 | 1 | 2 | `processing_element_v2.v:142-146` |
| INT8×INT8 | 2 | 2 | 4 | `processing_element_v2.v:147-153` |

The BF16×BF16 and BF16×INT8 case arms are structurally identical — four passes each,
with the same `pp_shift` sequence `{0, 4, 4, 8}`. The only difference is `m_b_sgn=1`
on the high-nibble passes of INT8 for sign extension. **Same cycle cost.**

### Cycle model (N = 8)

| Phase | Cycles |
|---|---|
| Start pulse | 1 |
| Weight load | N = 8 |
| Compute | (2N−1)·L + (N−1) = 15L + 7 |
| Drain | 1 |
| **`cycle_count`** | **15L + 17** |
| Activation load | N = 8 |
| **Total** | **15L + 25** |

| Mode | L | `cycle_count` | Total |
|---|---|---|---|
| BF16×BF16 | 4 | 77 | 85 |
| BF16×INT8 | 4 | 77 | 85 |
| BF16×INT4 | 2 | 47 | 55 |
| INT4×INT4 | 1 | 32 | 40 |

Note the **17-cycle fixed overhead** — it does not shrink with L. This is why halving
L does not halve runtime.

---

## 3. Throughput

```
Throughput = 2·M·N·K / (cycles × T_clk) = 1024 FLOPs / (cycles × T_clk)
```

At the SDC target of **500 MHz** (T_clk = 2 ns), on `cycle_count` basis:

| Mode | L | Cycles | Time | MACs/cycle | Throughput |
|---|---|---|---|---|---|
| BF16×BF16 | 4 | 77 | 154 ns | 6.65 | **6.65 GFLOP/s** |
| BF16×INT8 | 4 | 77 | 154 ns | 6.65 | **6.65 GFLOP/s** |
| BF16×INT4 | 2 | 47 | 94 ns | 10.89 | **10.89 GFLOP/s** |
| INT4×INT4 | 1 | 32 | 64 ns | 16.00 | **16.00 GFLOP/s** |

(MACs/cycle is frequency-independent and is the better number to quote before
synthesis closes timing.)

### Utilization

Peak rate is 64 PEs each retiring a MAC every L cycles = **64/L MACs/cycle**:

| Mode | Peak MACs/cycle | Achieved | Utilization |
|---|---|---|---|
| BF16×BF16 | 16.0 | 6.65 | 41.6% |
| BF16×INT4 | 32.0 | 10.89 | 34.0% |
| INT4×INT4 | 64.0 | 16.00 | 25.0% |

Utilization **falls** as L drops, because the 17-cycle fixed overhead becomes a larger
fraction of a shorter run. The low-precision modes are the ones most starved by
per-GEMM overhead — relevant if this is ever scaled to real workloads.

---

## 4. Answers

### Q1: BF16 activations × INT8 weights → **A. Exactly A. No speedup.**

Both modes need L = 4. The BF16 mantissa is 8 bits wide and INT8 is 8 bits wide;
neither crosses a nibble boundary relative to the other, so both decompose into the
same four 4×4 partial products.

Narrowing weights from 16 bits to 8 bits is still worth doing — it halves weight SRAM
capacity and weight-delivery bandwidth, and should reduce switching power in the
weight path — but it buys **zero** throughput on this microarchitecture. Any
compute speedup would require the multiplier to exploit the narrower operand, which a
fixed 4×4 primitive iterated a mode-dependent number of times does not do unless the
nibble count actually changes.

### Q2: BF16 activations × INT4 weights → **1.64 A**

| Basis | BF16×BF16 | BF16×INT4 | Ratio |
|---|---|---|---|
| `cycle_count` (77 vs 47) | A | **1.64 A** | 77/47 = 1.638 |
| Incl. activation load (85 vs 55) | A | **1.55 A** | 85/55 = 1.545 |
| Steady state, K → ∞ | A | **2.00 A** | L: 4/2 = 2.0 |

INT4 weights are 1 nibble, halving L from 4 to 2. The single-GEMM speedup is **1.64×**
rather than the full 2× because the 17-cycle fixed overhead is unchanged. The 2×
figure is the asymptotic limit for a deep contraction where per-column cost (L cycles)
dominates and fill/drain amortizes away — quote it only as a limit, not as a measured
result.

### Summary

| | BF16×BF16 | BF16×INT8 | BF16×INT4 |
|---|---|---|---|
| L | 4 | 4 | 2 |
| `cycle_count` | 77 | 77 | 47 |
| **Throughput** | **A** | **A** | **1.64 A** |

---

## 5. Correction Needed in `power.md`

The table at `power.md:242-246` should read as follows (100 MHz reference, 512 MACs
per GEMM):

| Mode | `cycle_count` | MACs | Time @100 MHz | Throughput |
|---|---|---|---|---|
| BF16×BF16 | 77 | 512 | 770 ns | 665 MMAC/s (1.33 GFLOP/s) |
| BF16×INT4 | 47 | 512 | 470 ns | 1089 MMAC/s (2.18 GFLOP/s) |
| INT4×INT4 | 32 | 512 | 320 ns | 1600 MMAC/s (3.20 GFLOP/s) |

The existing table uses `MACs = 64`, which is the output-element count, making every
figure 8× low.

---

## 6. Caveats

- **"FLOPs" is loose for the mixed modes.** BF16×INT4 and BF16×INT8 produce BF16
  outputs through the EHU, so the term is defensible, but the multiplier operands are
  integers and a reviewer may object. **MACs/cycle** or **OPS** is the safer label for
  anything other than BF16×BF16.
- All figures are for a single 8×8 × 8×8 GEMM with no back-to-back overlap. Nothing
  here assumes weight load or drain is hidden behind an adjacent GEMM.
- The 500 MHz figures are the **SDC target** (`constraints.sdc:23`), not a
  post-synthesis result. They are valid only if timing actually closes at 2 ns.
- Cycle counts are from the hardware `cycle_count` register and match the testbench
  output in `README.md`, so they are measured rather than predicted.

---

## Further Reading

- [README.md](README.md) — mode table and cycle counts
- [project.md](project.md) — dataflow and timing derivation
- [power.md](power.md) — power methodology (see §5 above for the correction)
