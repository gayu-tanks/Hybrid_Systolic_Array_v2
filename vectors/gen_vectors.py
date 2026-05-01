#!/usr/bin/env python3
"""
Generate golden test vectors for hybrid_systolic_array_v2.
Outputs one .hex file per mode in this directory.

Modes:
  001  BF16 × BF16
  010  BF16 × INT8
  011  BF16 × INT4
  100  INT4 × INT4
  101  INT8 × INT4
  110  INT8 × INT8

File format (for testbench $readmemh):
  act_flat.hex   — N*N BF16 activations, row-major (row0col0 first), 4 hex digits each
  wt_flat.hex    — N*N weight values, col-major (col0row0 first), 4 hex digits each
  gold_flat.hex  — N BF16 results (C[i][N-1] for each row i)
"""

import struct, random, os, sys

N = 8
random.seed(42)

def to_bf16_bits(f):
    """Convert Python float to BF16 bit pattern (uint16)."""
    b = struct.pack('>f', float(f))
    return (b[0] << 8) | b[1]

def from_bf16_bits(u):
    """Convert BF16 bit pattern to float."""
    b = bytes([(u >> 8) & 0xFF, u & 0xFF, 0, 0])
    return struct.unpack('>f', b)[0]

def to_int4_signed(val):
    """Clamp and encode signed 4-bit integer, returned as Python int (sign-extended)."""
    val = max(-8, min(7, int(val)))
    return val

def to_int8_signed(val):
    val = max(-128, min(127, int(val)))
    return val

def int4_to_bits(val):
    """4-bit signed int to 4-bit unsigned representation (stored in 16-bit field, zero-extended)."""
    return val & 0xF

def int8_to_bits(val):
    return val & 0xFF

def float_to_bf16_approx(f):
    """Return BF16-representable float closest to f."""
    return from_bf16_bits(to_bf16_bits(f))

def ref_matmul(act, wt, mode):
    """
    Compute reference C = A * W for given mode.
    act: N×N list of floats (act[i][j] is row i, col j)
    wt:  N×N list of floats  (wt[k][j] is step k, column j)
    Returns N×N result matrix where C[i][j] = sum_k act[i][k] * wt[k][j]
    but for our systolic array, activations are A[i][k] and weights are W[k] (one column j).

    Actually C[i] = sum_k act[i][k] * wt_col_k[i] where wt is organized per-column.

    In our systolic array:
      - act_buf[i][j] holds activation for row i, column j
      - wt_buf[step][col] holds weight for step `step` fed to column `col`
      - PE[i][j] computes act[i][j] * wt[step][j] when step arrives
      - Each row accumulates: acc[i] = sum_j act[i][j] * wt[j][j]  -- wait

    Actually the systolic array computes:
      result[i] = sum_{j=0}^{N-1} act[i][j] * wt_step_j
    where wt_step_j = wt_buf[j][j]... no.

    Let me re-think. The weight_col_data fed at step k contains N values, one per column.
    wt_buf[k][j] = weight_col_data[j] at load step k.

    PE[i][j] holds act[i][j] and gets weight wt_buf[step][j] for step = 0..N-1.
    But each step k: PE[i][j] multiplies act[i][j] * wt_buf[k][j] and accumulates.

    Wait no — only ONE step k reaches PE[i][j] per invocation. The weight for step k
    at column j is fed once. So PE[i][j] computes:
      acc[i][j] = acc[i][j-1] + act[i][j] * wt_buf[k_j][j]
    where k_j... hmm.

    Actually in activation-stationary:
      Each step k feeds one weight COLUMN. wt_buf[k][j] is the weight from row k, column j
      of the weight matrix W. PE[i][j] accumulates sum_k act[i][k] * W[k][j].

    So result[i][j] = sum_k act[i][k] * W[k][j] = (A * W)[i][j]

    The output comes from the RIGHTMOST column (j = N-1), giving result[i][N-1] for each row i.
    But we compute all N steps, so actually each step k feeds column k (k = 0..N-1, j = 0..N-1).

    The actual mapping: wt_buf[k][j] is fed to column j at step k. So W[k][j] = wt_buf[k][j].
    And A[i][j] = act[i][j]. Result[i] at the right boundary = sum_j act[i][j] * wt_buf[j][j]...

    No wait. Each PE[i][j] receives the weight for step k = j (only once, since each column
    gets exactly one weight per pass through). So PE[i][j] computes act[i][j] * wt_buf[?][j].

    Hmm I need to re-read the design. In a standard systolic array (activation-stationary):
    - Each PE[i][j] holds act[i][j] (stationary)
    - In each step k, the weight for "row k" of W flows through the array
    - The weight W[k][j] arrives at PE[i][j] after k steps
    - PE[i][j] computes act[i][j] * W[k][j] and adds to running accumulator
    - After N steps: acc[i][j] = sum_k act[i][k-j+j]...

    This is getting confusing. Let me think about what result actually comes out.

    Standard activation-stationary:
    - After step k, PE[i][j] has accumulated: act[i][j] * W[k][j] (for the specific step)
    - The acc flows left to right: result at right = sum over j of act[i][j] * W[step_j][j]
    - With j-skew (step k arrives at column j at cycle k+j), all steps arrive at:
      column 0: step 0,1,2,...,N-1
      column 1: also steps 0,1,2,...,N-1 (but shifted by 1 cycle)

    OK I think the correct interpretation is:
    - One "pass" computes one column of C, specifically C[i][*] where the weight column is W[:,j_out]
    - Actually for this array: the weight_col_data at step k has N values W[k][0..N-1]
    - PE[i][j] gets weight W[j][j] at some step... no.

    Let me just directly simulate what happens:
    - PE[i][j] gets weight_valid_in at compute_cycle k*L+j+i*L = (k+i)*L+j
    - At that point, PE[i][j] multiplies act[i][j] * wt_buf[k][j] and adds to acc
    - For k = 0..N-1, all these accumulate at PE[i][j]:
      but the acc flows left-to-right, so by the time step k at column j-1 is done and
      passes to column j, only ONE step k is active at column j.

    Actually: for a given row i and step k, the acc_valid signal travels from left to right.
    The acc_valid from column j-1 arrives at column j exactly when column j starts step k.
    So each "active wave" corresponds to one step k and it sweeps left-to-right through all N columns.

    So for step k=0:
    - PE[i][0] computes act[i][0] * W[0][0], outputs acc = result
    - PE[i][1] adds act[i][1] * W[0][1] to that acc
    - ...
    - PE[i][N-1] outputs sum_j act[i][j] * W[0][j] = A[i,:] dot W[0,:]^T

    But wait, that's only one step. What does step k=1 do? It would create another wave.
    The second wave at step k=1 adds act[i][j] * W[1][j] to a DIFFERENT acc stream.

    Hmm but there's only one acc stream per row. So the second wave ADDS to the result of the first wave?

    Actually yes! After the first wave passes through column j, the acc_valid stays 1 and the acc
    register holds the running sum. Then when the second wave (step k=1) arrives at column j, it
    adds act[i][j]*W[1][j] to the existing acc. So after all N steps:

    result[i] = sum_{k=0}^{N-1} sum_{j=0}^{N-1}?? No, that's N² terms...

    Wait, I need to re-examine. The acc_valid signal: the left boundary is always 0. So each
    wave starts fresh from the left. The first wave (k=0) sweeps through and produces:
    - At j=0: acc = 0 + act[i][0]*W[0][0]; acc_valid=1; passes to j=1
    - At j=1: acc = prev + act[i][1]*W[0][1]; passes to j=2
    - ...
    - At j=N-1: acc = sum_j act[i][j]*W[0][j]

    But the second wave (k=1) starts fresh from the left boundary (acc=0, acc_valid=0).
    So it produces sum_j act[i][j]*W[1][j] at the right boundary independently?

    But there's only one acc_h[i][j+1] wire — it's overwritten by each wave. So at the right
    boundary, we see the result of whichever wave is currently passing through column N-1.

    The acc_valid signal at the right boundary pulses N times (once per step k), and each time
    it represents sum_j act[i][j]*W[k][j] = A[i,:] · W[k,:].

    But that doesn't make sense as matrix multiplication. The full C = A*W would require
    accumulating over k.

    OH WAIT. I think I'm confusing the layout. Let me re-read the summary:
    "wt_buf[k][j] = weight_col_data[j] at load step k"

    So if we load N "columns" (steps k=0..N-1), wt_buf[k][j] is the j-th element of the k-th
    weight column fed.

    In standard matrix multiplication C = A * W:
    - A is N×N (activations)
    - W is N×N (weights)
    - C[i][j] = sum_k A[i][k] * W[k][j]

    In the systolic array:
    - act[i][j] = A[i][j] (row i, column j of activation matrix)
    - wt_buf[step][col] = ? what does "step" mean in terms of W?

    From the summary: "weight_col_data at step k" is fed to wt_buf[k][*]. The weight fed
    at step k has N values, one per column. Looking at the code:
    `wt_buf[load_col][k] <= weight_col_data[k*16 +: 16]`

    Wait, in the FSM code I wrote:
    `wt_buf[load_col][k] <= weight_col_data[k*16 +: 16]`

    Here load_col is the step index (0..N-1), and k iterates over columns. So:
    wt_buf[step][col] = weight_col_data[col] at load step `step`.

    In the weight delivery: `wt_buf[step_idx_ext][gj]` is sent to column gj at step step_idx.
    So column j (=gj) gets weight value wt_buf[step_idx][j] = W[step_idx][j].

    PE[i][j] processes: act[i][j] * wt_buf[step][j] for step = 0..N-1.
    But with j-skew, each step k hits each column j at a different time. The acc accumulates
    left-to-right with acc_valid carrying the "tag".

    Each wave corresponds to step k:
    - The wave starts at j=0 with acc=0, acc_valid=0
    - At j=0, PE[i][0] gets weight wt_buf[k][0] = W[k][0], computes act[i][0]*W[k][0]
    - acc_valid becomes 1, passes to j=1
    - At j=1, PE[i][1] gets weight wt_buf[k][1], adds act[i][1]*W[k][1]
    - Final result at j=N-1: sum_j act[i][j]*W[k][j]

    So the output at the right boundary for step k is:
    result[i][k] = sum_j A[i][j] * W[k][j] = (A * W^T)[i][k]

    Hmm, that's A times W-transpose, not A times W. And we get N results per row (one per step k).

    So if we interpret the weight as W^T (i.e., the k-th weight_col_data contains row k of W,
    which is column k of W^T), then we compute C = A * W^T.

    For simplicity in our test, let's just define:
    - act[i][j] = activation for row i, column j
    - For each step k (k=0..N-1), wt_col[k] = N values fed as weight_col_data
    - result[i][k] = sum_j act[i][j] * wt_col[k][j]  (one result per row per step)

    The testbench captures N results per row (one per step k). But looking at the RTL
    and v1 testbench, the result emerges from the right boundary and acc_valid pulses.

    For simplicity in golden vector generation, let's define:
    - We feed N steps of weight data
    - For step k, wt_col_data[j] = W[k][j]
    - Expected result for (row i, step k) = dot(act[i,:], W[k,:])

    But actually looking at how the testbench works in the original systolic_ext_ehu,
    the capture_results waits for acc_valid to fire and captures results for ALL rows
    simultaneously. The result_valid fires once per step (k=0..N-1), giving N outputs
    per row per pass. But that would be N*N total outputs.

    For simplicity, let's generate golden vectors for just C = A * W^T where:
    - A is the activation matrix (N×N)
    - B is the weight matrix (N×N), fed column by column as wt_col_data
    - result[i][k] = sum_j A[i][j] * B[k][j] = (A * B^T)[i][k]

    And in the testbench, we capture the LAST result (step N-1) for checking, or we
    check all N steps. For the golden file, let me output all N*N results.
    """
    pass  # Explanation only


def gen_bf16_activations(n):
    """Generate N×N BF16 activation values (small positive floats)."""
    act = []
    for i in range(n):
        row = []
        for j in range(n):
            f = round(random.uniform(0.1, 2.0), 2)
            f = float_to_bf16_approx(f)
            row.append(f)
        act.append(row)
    return act

def gen_bf16_weights(n):
    """Generate N×N BF16 weight values (feed as N columns, each with N values)."""
    wt = []
    for k in range(n):  # step k
        col = []
        for j in range(n):  # column j
            f = round(random.uniform(-1.0, 1.0), 2)
            f = float_to_bf16_approx(f)
            col.append(f)
        wt.append(col)
    return wt

def gen_int4_activations(n):
    """N×N INT4 activations (signed, -8..7)."""
    act = []
    for i in range(n):
        row = [to_int4_signed(random.randint(-4, 4)) for j in range(n)]
        act.append(row)
    return act

def gen_int4_weights(n):
    wt = []
    for k in range(n):
        col = [to_int4_signed(random.randint(-4, 4)) for j in range(n)]
        wt.append(col)
    return wt

def gen_int8_activations(n):
    act = []
    for i in range(n):
        row = [to_int8_signed(random.randint(-32, 32)) for j in range(n)]
        act.append(row)
    return act

def gen_int8_weights(n):
    wt = []
    for k in range(n):
        col = [to_int8_signed(random.randint(-32, 32)) for j in range(n)]
        wt.append(col)
    return wt

def compute_expected(act, wt, n):
    """
    result[i][k] = sum_j act[i][j] * wt[k][j]
    Returns N×N float matrix.
    """
    res = []
    for i in range(n):
        row = []
        for k in range(n):
            s = sum(act[i][j] * wt[k][j] for j in range(n))
            row.append(s)
        res.append(row)
    return res

def float_to_bf16_repr(f):
    """BF16 representation of float."""
    return from_bf16_bits(to_bf16_bits(f))

def write_hex_file(path, values_16bit):
    """Write list of 16-bit integers as hex file."""
    with open(path, 'w') as f:
        for v in values_16bit:
            f.write(f'{v & 0xFFFF:04x}\n')

def mode_name(mode):
    names = {
        0b001: 'bf16_bf16',
        0b010: 'bf16_int8',
        0b011: 'bf16_int4',
        0b100: 'int4_int4',
        0b101: 'int8_int4',
        0b110: 'int8_int8',
    }
    return names[mode]

def generate_mode(mode, n, outdir):
    """Generate act, wt, and golden files for given mode."""
    os.makedirs(outdir, exist_ok=True)
    random.seed(42 + mode)

    if mode == 0b001:  # BF16×BF16
        act = gen_bf16_activations(n)
        wt  = gen_bf16_weights(n)
        act_bits = [[to_bf16_bits(v) for v in row] for row in act]
        wt_bits  = [[to_bf16_bits(v) for v in col] for col in wt]
    elif mode == 0b010:  # BF16×INT8
        act = gen_bf16_activations(n)
        wt  = gen_int8_weights(n)
        act_bits = [[to_bf16_bits(v) for v in row] for row in act]
        wt_bits  = [[int8_to_bits(v) for v in col] for col in wt]
    elif mode == 0b011:  # BF16×INT4
        act = gen_bf16_activations(n)
        wt  = gen_int4_weights(n)
        act_bits = [[to_bf16_bits(v) for v in row] for row in act]
        wt_bits  = [[int4_to_bits(v) for v in col] for col in wt]
    elif mode == 0b100:  # INT4×INT4
        act = gen_int4_activations(n)
        wt  = gen_int4_weights(n)
        act_bits = [[int4_to_bits(v) for v in row] for row in act]
        wt_bits  = [[int4_to_bits(v) for v in col] for col in wt]
    elif mode == 0b101:  # INT8×INT4
        act = gen_int8_activations(n)
        wt  = gen_int4_weights(n)
        act_bits = [[int8_to_bits(v) for v in row] for row in act]
        wt_bits  = [[int4_to_bits(v) for v in col] for col in wt]
    elif mode == 0b110:  # INT8×INT8
        act = gen_int8_activations(n)
        wt  = gen_int8_weights(n)
        act_bits = [[int8_to_bits(v) for v in row] for row in act]
        wt_bits  = [[int8_to_bits(v) for v in col] for col in wt]
    else:
        raise ValueError(f"Unknown mode {mode}")

    # Compute expected result (float)
    res = compute_expected(act, wt, n)

    # Convert expected to BF16
    res_bf16_float = [[float_to_bf16_repr(res[i][k]) for k in range(n)] for i in range(n)]

    # Flatten: act row-major, wt step-major
    act_flat  = [act_bits[i][j] for i in range(n) for j in range(n)]
    wt_flat   = [wt_bits[k][j] for k in range(n) for j in range(n)]
    gold_flat = [to_bf16_bits(res_bf16_float[i][k]) for i in range(n) for k in range(n)]

    mn = mode_name(mode)
    write_hex_file(os.path.join(outdir, f'act_{mn}.hex'), act_flat)
    write_hex_file(os.path.join(outdir, f'wt_{mn}.hex'),  wt_flat)
    write_hex_file(os.path.join(outdir, f'gold_{mn}.hex'), gold_flat)

    # Also write a human-readable summary
    with open(os.path.join(outdir, f'summary_{mn}.txt'), 'w') as f:
        f.write(f"Mode: {mn} (3'b{mode:03b})\n\n")
        f.write("Activations (float):\n")
        for i in range(n):
            f.write("  row %d: %s\n" % (i, [round(v,4) for v in act[i]]))
        f.write("\nWeights (float) per step:\n")
        for k in range(n):
            f.write("  step %d: %s\n" % (k, [round(v,4) for v in wt[k]]))
        f.write("\nExpected results [i][k] = sum_j act[i][j]*wt[k][j]:\n")
        for i in range(n):
            f.write("  row %d: %s\n" % (i, [round(res[i][k],4) for k in range(n)]))
        f.write("\nExpected BF16 (float repr):\n")
        for i in range(n):
            f.write("  row %d: %s\n" % (i, [round(res_bf16_float[i][k],4) for k in range(n)]))

    print(f"Generated {mn}: act={len(act_flat)}, wt={len(wt_flat)}, gold={len(gold_flat)}")

if __name__ == '__main__':
    outdir = os.path.dirname(os.path.abspath(__file__))
    for mode in [0b001, 0b010, 0b011, 0b100, 0b101, 0b110]:
        generate_mode(mode, N, outdir)
    print("Done.")
