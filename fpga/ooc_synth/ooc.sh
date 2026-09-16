# Source this from inside fpga/ooc_synth to get the `ooc` helper:
#   source ooc.sh
# It refuses to run unless the current shell is still in this directory.
#
# Vivado invocation is machine-specific - set ONE of these in ~/.bashrc:
#   VIVADO_BIN  - native vivado on this OS, e.g. a Linux box with Vivado
#                 on PATH after sourcing settings64.sh (VIVADO_BIN=vivado),
#                 or a full path if it's not on PATH.
#   VIVADO_BAT  - Windows vivado.bat path, for WSL with a Windows-only
#                 Vivado reached via cmd.exe interop, e.g.
#                 'G:\DevLibrary\Vivado\2025.2\Vivado\bin\vivado.bat'
#
# OOC_THREADS - optional: parallel jobs for synth_design (default 4, set in
#               common_synth.tcl). Export it, or set it per-run:
#                 OOC_THREADS=8 ooc matmul 5.0 8 0
#               Forwarded explicitly (not just inherited) because the
#               VIVADO_BAT/cmd.exe path runs in a separate Windows environment
#               that WSL's exported vars don't reach.

_ooc_run_vivado() {
    local script="$1"; shift
    local threads="${OOC_THREADS:-4}"

    if [[ -n "$VIVADO_BIN" ]]; then
        if [[ $# -gt 0 ]]; then
            OOC_THREADS="$threads" "$VIVADO_BIN" -mode batch -source "${script}.tcl" -tclargs "$@"
        else
            OOC_THREADS="$threads" "$VIVADO_BIN" -mode batch -source "${script}.tcl"
        fi
        return $?
    fi

    if [[ -n "$VIVADO_BAT" ]]; then
        if [[ $# -gt 0 ]]; then
            /mnt/c/Windows/System32/cmd.exe /c "set OOC_THREADS=$threads && $VIVADO_BAT -mode batch -source ${script}.tcl -tclargs $*"
        else
            /mnt/c/Windows/System32/cmd.exe /c "set OOC_THREADS=$threads && $VIVADO_BAT -mode batch -source ${script}.tcl"
        fi
        return $?
    fi

    echo "ooc: set \$VIVADO_BIN (native vivado path/command) or \$VIVADO_BAT (Windows vivado.bat path, for WSL+cmd.exe)" >&2
    return 1
}

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
    )

    local name="$1"; shift

    if [[ -z "$name" || "$name" == "help" || "$name" == "-h" || "$name" == "--help" ]]; then
        cat <<'EOF'
Usage: ooc <ip> [params...]

  keccak                          (no params)
  xoshiro                         (no params, combinational)
  matgen                          (no params)
  rankcheck                       (no params)
  cshake  [CLK_NS NUM_STAGES S_VALUE DATA_80BYTE]   default: 5.0 24 0 1
  matmul  [CLK_NS NUM_STAGES INTERNAL_MATRIX]        default: 5.0 8 1
  core    [CLK_NS CSHAKE_STAGES MATMUL_STAGES]       default: 5.0 24 8

Env:
  VIVADO_BIN / VIVADO_BAT   required - see the comment block above this function
  OOC_THREADS               optional - parallel synth_design jobs (default 4)

Examples:
  ooc keccak
  ooc cshake 5.0 8 1 0
  ooc matmul 5.0 8 0
  OOC_THREADS=8 ooc core 4.0 24 16
EOF
        return 0
    fi

    local script="${ip[$name]:-$name}"

    if [[ ! -f "${script}.tcl" ]]; then
        echo "ooc: no such script '${script}.tcl' (known: ${!ip[@]})" >&2
        return 1
    fi

    _ooc_run_vivado "$script" "$@"
}
