# Source this from inside fpga/boards/k325t_ffg900 to get the `board` helper:
#   source board.sh
# It refuses to run unless the current shell is still in this directory.
#
# Vivado is launched through ../../vivado.sh - set VIVADO_BIN or VIVADO_BAT
# in ~/.bashrc as described there.

source "$(dirname "${BASH_SOURCE[0]}")/../../vivado.sh"

# Keep in sync with the switch in build.tcl
_BOARD_TARGETS=(blinky uart miner)

board() {
    case "$PWD" in
        */fpga/boards/k325t_ffg900) ;;
        *) echo "board: only run this from fpga/boards/k325t_ffg900" >&2; return 1 ;;
    esac

    local cmd="$1"; shift

    case "$cmd" in
        build)
            local target="$1"
            if [[ ! " ${_BOARD_TARGETS[*]} " == *" $target "* ]]; then
                echo "board build: unknown target '$target' (expected: ${_BOARD_TARGETS[*]})" >&2
                return 1
            fi
            vivado_run build.tcl "$@"
            ;;
        program)
            # <target> or a build folder, e.g. build/miner_CLK_DIV12
            local target="$1"; shift
            if [[ -z "$target" ]]; then
                echo "board program: give a target or build folder (see board help)" >&2
                return 1
            fi
            if [[ -n "$1" && "$1" != "flash" ]]; then
                echo "board program: unknown mode '$1' (expected nothing for JTAG, or flash)" >&2
                return 1
            fi
            [[ -d "$target" ]] && target="$(vivado_path "$target")"
            vivado_run program.tcl "$target" "$@"
            ;;
        backup)
            if [[ $# -gt 0 ]]; then
                vivado_run backup_flash.tcl "$(vivado_path "$1")"
            else
                vivado_run backup_flash.tcl
            fi
            ;;
        ""|help|-h|--help)
            cat <<'EOF'
Usage: board <command> [args...]

  build   <target> [KEY=VALUE ...]   build/<target>/ (targets: blinky uart miner)
  program <target|build_dir> [flash] JTAG by default; flash writes the SPI flash
  backup  [OUT_FILE]                 read the whole SPI flash (default flash_backup.bin)

Env:
  VIVADO_BIN / VIVADO_BAT   required - see fpga/vivado.sh
  VIVADO_TMP                optional - folder for .Xil instead of this one (build)
  JOBS, SYNTH_ARGS          optional - see build.tcl
  PLACE_DIRECTIVE, ROUTE_DIRECTIVE  optional - e.g. AltSpreadLogic_high, AlternateCLBRouting (build)
  REUSE_SYNTH=1             optional - skip synthesis, reuse this config's saved _synth.dcp (build)
  HW_SERVER                 optional - <host>:3121 for a remote hw_server (program, backup)

Examples:
  board build uart
  board program uart
  board build miner CLK_DIV=12 CSHAKE_STAGES=6 MATMUL_STAGES=16
  board program build/miner_CLK_DIV12 flash
  board backup ~/k325t_flash_backup.bin
EOF
            ;;
        *)
            echo "board: unknown command '$cmd' (build, program, backup or help)" >&2
            return 1
            ;;
    esac
}
