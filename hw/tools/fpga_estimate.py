#!/usr/bin/env python3
"""
Quick FPGA-usage ESTIMATE for the kHeavyHash IPs.

These are ANALYTICAL estimates from each module's RTL register formulas
(accurate for flip-flops) plus rough logic ballparks. They are NOT from
synthesis - real LUT/FF/DSP numbers depend on the target device and tools.

Usage:
    python3 fpga_estimate.py <module> [PARAM=value ...]
"""

import sys


def _p(args, key, default):
    for a in args:
        if a.startswith(key + "="):
            return int(a.split("=", 1)[1])
    return default


def matmul(args):
    ns = _p(args, "NUM_STAGES", 8)
    internal = _p(args, "INTERNAL_MATRIX", 1)
    extra_lat = _p(args, "EXTRA_LAT", 0)
    # Stage 0 has no incoming accumulator (ain=0) and stays a plain fabric
    # register; every later stage's add lives in a DSP48 P register instead
    # (see matmul_pipelined_unit.sv). Only stage 0's 64 accumulators, plus
    # any EXTRA_LAT output tail, remain fabric FF.
    acc = (1 + extra_lat) * 64 * 14
    dsp_acc = (ns - 1) * 32  # 32 row-pairs/stage x (NUM_STAGES-1) real stages
    vec = 128 * (ns - 1)
    val = ns
    mat = 16384 if internal else 0
    ff = [
        ("accumulators (fabric)", acc, "(1 + EXTRA_LAT) x 64 x 14; rest live in DSP48 P regs"),
        ("vector forward", vec, "128 x (NUM_STAGES-1)"),
        ("valid pipe", val, ""),
        ("matrix" + (" (internal)" if internal else " (wired-in)"), mat,
         "64 x 64 x 4" if internal else "read from cache, 0 FF"),
        ("kcm load run regs", 64 * 8, "64 rows x 8-bit accumulator"),
        ("kcm load fsm", 12, "ld_col + ld_k + state"),
    ]
    # KCM: each 4x4 mult is a 16x8 constant-coefficient table in SLICEM
    # distributed RAM (8 LUT/mult), rebuilt in ~1024 cycles by 64 load adders.
    # The intra-stage column-sum tree (part[i]) still lives in LUT fabric;
    # only the inter-stage accumulate add moved to DSP48.
    logic = ("~30-45k LUT (rough, minus the migrated accumulate adds)",
             "4096 x 16x8 KCM product tables (distributed RAM, ~32k SLICEM) "
             "+ 64-row load adders + 64 intra-stage column-sum trees")
    dsp = "%d (dual-row packed DSP48 ALU accumulate, stage 0 stays fabric)" % dsp_acc
    if dsp_acc > 240:
        print("  WARNING: estimated matmul DSP48 usage (%d) exceeds the "
              "240 available on xc7k70t for NUM_STAGES=%d" % (dsp_acc, ns))
    return ff, logic, dsp


def cshake(args):
    ns = _p(args, "NUM_STAGES", 24)
    ff = [
        ("encoded block pr0", 1088, "one 136-byte rate block"),
        ("sponge state pr1", 1600, "25 x 64-bit lanes"),
        ("keccak pipe kstate", ns * 1600, "NUM_STAGES x 1600"),
        ("valid shift reg", ns + 2, "NUM_STAGES + 2"),
    ]
    logic = ("~20-40k LUT (rough)", "24 Keccak rounds (theta/rho/pi/chi/iota)")
    dsp = "0 (Keccak is XOR/AND/rotate only)"
    return ff, logic, dsp


def cache(args):
    ff = [
        ("matrix store", 16384, "64 x 64 x 4"),
        ("PrePowHash tag", 256, ""),
        ("registered reads", 512, "rd_row_data + rd_PrePowHash"),
    ]
    logic = ("~small", "matrix_flat is a combinational tap (wires, heavy fan-out)")
    dsp = "0"
    return ff, logic, dsp


def rankcheck(args):
    ff = [
        ("working matrix M", 16384, "64 x 256-bit GF(2) rows"),
        ("counters/state", 32, "rank/col/load_idx/pivot/state"),
    ]
    logic = ("~moderate", "GF(2) Gaussian elimination (XOR-heavy)")
    dsp = "0"
    return ff, logic, dsp


def generator(args):
    ff = [
        ("PRNG state s0..s3", 256, "4 x 64-bit xoshiro256++ state"),
        ("counter/FSM", 11, "n16th_value + state"),
        ("matrix_rankcheck", 16416, "working matrix + counters"),
        ("matrix_cache", 17152, "matrix + tag + read regs"),
    ]
    logic = ("~moderate", "xoshiro256++ (combinational) + rank-check elimination")
    dsp = "0"
    return ff, logic, dsp


def keccak(args):
    ff = [
        ("state register", 1600, "25 x 64-bit lanes"),
        ("round counter", 6, ""),
    ]
    logic = ("~1-3k LUT (rough)", "one Keccak round, iterated 24x")
    dsp = "0"
    return ff, logic, dsp


def xoshiro(args):
    ff = [("(combinational)", 0, "next-state function; state lives in the parent")]
    logic = ("~small", "64-bit adds, rotates, XORs")
    dsp = "0"
    return ff, logic, dsp


def core(args):
    cs = _p(args, "CSHAKE_STAGES", 24)
    ms = _p(args, "MATMUL_STAGES", 8)
    mel = _p(args, "MATMUL_EXTRA_LAT", 0)
    c_lat = cs + 2
    m_lat = ms + mel
    total_lat = c_lat + m_lat + c_lat
    cshake_ff = 1088 + 1600 + cs * 1600 + (cs + 2)
    # Only stage 0's 64 accumulators + any EXTRA_LAT tail stay fabric FF;
    # the rest of the inter-stage accumulate lives in DSP48 P registers.
    matmul_ff = (1 + mel) * 64 * 14 + 128 * (ms - 1) + ms + 64 * 8 + 12  # + KCM load regs
    matmul_dsp = (ms - 1) * 32
    ff = [
        ("cSHAKE1 (POW)", cshake_ff, "CSHAKE_STAGES=%d" % cs),
        ("cSHAKE2 (HeavyHash)", cshake_ff, "CSHAKE_STAGES=%d" % cs),
        ("matmul (wired)", matmul_ff, "MATMUL_STAGES=%d, KCM tables in LUTRAM, accumulate on DSP48" % ms),
        ("matrix_cache", 17152, "matrix + tag + read regs"),
        ("matrix_generator", 267, "PRNG state + FSM"),
        ("matrix_rankcheck", 16416, "working matrix + counters"),
        ("pow_hash delay", m_lat * 256, "M_LAT(%d) x 256" % m_lat),
        ("nonce delay line", total_lat * 64, "TOTAL_LAT(%d) x 64" % total_lat),
        ("block/ctrl regs", 643, "pph/blk_pph/ts/nonce_ctr/state"),
        ("target/found", total_lat * 8 + 337, "work-id delay + tgt/found regs"),
    ]
    logic = ("dominated by matmul + 2x Keccak",
             "see matmul/cSHAKE estimates; matmul now ~32k SLICEM LUTRAM (KCM) + intra-stage sum trees")
    dsp = "%d (matmul dual-row packed DSP48 accumulate; Keccak/cSHAKE use none)" % matmul_dsp
    if matmul_dsp > 240:
        print("  WARNING: estimated matmul DSP48 usage (%d) exceeds the "
              "240 available on xc7k70t for MATMUL_STAGES=%d" % (matmul_dsp, ms))
    return ff, logic, dsp


MODULES = {
    "matmul_pipelined_unit": matmul,
    "cshake256_pipelined_core": cshake,
    "matrix_cache": cache,
    "matrix_rankcheck": rankcheck,
    "matrix_generator": generator,
    "keccak_f1600": keccak,
    "xoshiro256pp": xoshiro,
    "core": core,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in MODULES:
        print("modules:", ", ".join(sorted(MODULES)))
        return
    mod = sys.argv[1]
    args = sys.argv[2:]
    ff, logic, dsp = MODULES[mod](args)
    total = sum(n for _, n, _ in ff)
    params = " ".join(args) if args else "defaults"

    line = "-" * 66
    print(line)
    print(" FPGA usage ESTIMATE - %s (%s)" % (mod, params))
    print(" analytical (RTL register formulas) - NOT synthesis")
    print(line)
    print("  Flip-flops (FF) : ~%s" % format(total, ","))
    for label, n, note in ff:
        note = "  (%s)" % note if note else ""
        print("      %-22s%8s%s" % (label, format(n, ","), note))
    print("  Logic           : %s" % logic[0])
    print("                    %s" % logic[1])
    print("  DSP blocks      : %s" % dsp)
    print(line)


if __name__ == "__main__":
    main()
