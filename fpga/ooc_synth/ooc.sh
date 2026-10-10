# Source this from inside fpga/ooc_synth to get the `ooc` helper:
#   source ooc.sh
# It refuses to run unless the current shell is still in this directory.
#
# Vivado is launched through ../vivado.sh - set VIVADO_BIN or VIVADO_BAT in
# ~/.bashrc as described there.
#
# OOC_THREADS - optional: parallel jobs for synth_design (default 4, set in
#               common_synth.tcl). Export it, or set it per-run:
#                 OOC_THREADS=8 ooc matmul 5.0 8 0

source "$(dirname "${BASH_SOURCE[0]}")/../vivado.sh"

ooc() {
    case "$PWD" in
        */fpga/ooc_synth) ;;
        *) echo "ooc: only run this from fpga/ooc_synth" >&2; return 1 ;;
    esac

    declare -A ip=(
        [keccak]=keccak_f1600
        [xoshiro]=xoshiro256pp
        [matgen]=matrix_generator
        [rankcheck]=matrix_rankcheck
        [cshake]=cshake256_core
        [matmul]=matmul_pipelined_unit
        [core]=core
        [miner]=kaspa_miner
    )

    local name="$1"; shift

    if [[ -z "$name" || "$name" == "help" || "$name" == "-h" || "$name" == "--help" ]]; then
        cat <<'EOF'
Usage: ooc <ip> [params...]

  keccak                          (no params)
  xoshiro                         (no params, combinational)
  matgen                          (no params)
  rankcheck                       (no params)
  cshake  [CLK_NS STAGES S_VALUE DATA_80BYTE FOLDED]   default: 5.0 24 0 1 0 (unfolded, 24 stages)
  matmul  [CLK_NS NUM_STAGES INTERNAL_MATRIX]        default: 5.0 8 1
  core    [CLK_NS CSHAKE_STAGES MATMUL_STAGES CSHAKE_FOLDED]  default: 5.0 24 8 0 (unfolded)
  miner   [CLK_NS CSHAKE_STAGES MATMUL_STAGES CSHAKE_FOLDED CLK_FREQ_HZ BAUD_RATE]  default: 5.0 24 8 0 200000000 3000000

Env:
  VIVADO_BIN / VIVADO_BAT   required - see fpga/vivado.sh
  OOC_THREADS               optional - parallel synth_design jobs (default 4)

Examples:
  ooc keccak
  ooc cshake 5.0 8 1 0
  ooc matmul 5.0 8 0
  OOC_THREADS=8 ooc core 4.0 24 16
  ooc core 5.0 4 8 1
  ooc miner 5.0 4 8 1
EOF
        return 0
    fi

    local script="${ip[$name]:-$name}"

    if [[ ! -f "${script}.tcl" ]]; then
        echo "ooc: no such script '${script}.tcl' (known: ${!ip[@]})" >&2
        return 1
    fi

    OOC_THREADS="${OOC_THREADS:-4}" vivado_run "${script}.tcl" "$@"
}
