# Shared Vivado launcher, sourced by fpga/ooc_synth/ooc.sh and
# fpga/boards/*/board.sh. Not meant to be run directly.
#
# Vivado invocation is machine-specific - set ONE of these in ~/.bashrc:
#   VIVADO_BIN  - native vivado on this OS, e.g. a Linux box with Vivado
#                 on PATH after sourcing settings64.sh (VIVADO_BIN=vivado),
#                 or a full path if it's not on PATH.
#   VIVADO_BAT  - Windows vivado.bat path, for WSL with a Windows-only
#                 Vivado reached via cmd.exe interop, e.g.
#                 'G:\DevLibrary\Vivado-2026.1\2026.1\Vivado\bin\vivado.bat'
#
# Env vars the Tcl scripts read (_VIVADO_FWD_VARS below) reach a native
# vivado by plain inheritance. The VIVADO_BAT path starts a separate
# Windows environment that WSL's exports don't reach, so
# they're forwarded explicitly via WSLENV; a value starting with / is
# translated to a Windows path on the way (e.g. VIVADO_TMP=/mnt/c/tmp/viv).
#
# VIVADO_BAT limits: run from a Windows drive (/mnt/c/..., not ~), since
# cmd.exe can't start in a WSL-side folder, and tclargs can't contain spaces.

_VIVADO_FWD_VARS=(OOC_THREADS VIVADO_TMP JOBS SYNTH_ARGS HW_SERVER
                  PLACE_DIRECTIVE ROUTE_DIRECTIVE REUSE_SYNTH)

# vivado_run <script.tcl> [tclargs...]
vivado_run() {
    local script="$1"; shift

    if [[ -n "$VIVADO_BIN" ]]; then
        if [[ $# -gt 0 ]]; then
            "$VIVADO_BIN" -mode batch -source "$script" -tclargs "$@"
        else
            "$VIVADO_BIN" -mode batch -source "$script"
        fi
        return $?
    fi

    if [[ -n "$VIVADO_BAT" ]]; then
        case "$PWD" in
            /mnt/[a-z]/*|/mnt/[a-z]) ;;
            *) echo "vivado_run: VIVADO_BAT needs a Windows-drive folder (/mnt/c/...), not $PWD" >&2; return 1 ;;
        esac

        local wslenv="$WSLENV" var
        for var in "${_VIVADO_FWD_VARS[@]}"; do
            [[ -n "${!var}" ]] || continue
            [[ "${!var}" == /* ]] && var="$var/p"
            wslenv="${wslenv:+$wslenv:}$var"
        done

        # vivado.bat splits unquoted args on '=' as well as spaces, so
        # CLK_DIV=15 would arrive as CLK_DIV and 15. Quoting stops the split
        # but the quotes reach Tcl, so only KEY=VALUE args get them and the
        # script strips them (build.tcl does)
        local cmd="$VIVADO_BAT -mode batch -source $script"
        if [[ $# -gt 0 ]]; then
            cmd+=" -tclargs"
            local a
            for a in "$@"; do
                if [[ "$a" == *=* ]]; then cmd+=" \"$a\""; else cmd+=" $a"; fi
            done
        fi
        WSLENV="$wslenv" /mnt/c/Windows/System32/cmd.exe /c "$cmd"
        return $?
    fi

    echo "vivado_run: set \$VIVADO_BIN (native vivado path/command) or \$VIVADO_BAT (Windows vivado.bat path, for WSL+cmd.exe)" >&2
    return 1
}

# vivado_path <path> - a path as the Vivado in use will see it: unchanged
# for VIVADO_BIN, a Windows path (wslpath -w) for an absolute path under
# VIVADO_BAT. Relative paths pass through, since vivado starts in $PWD.
vivado_path() {
    if [[ -z "$VIVADO_BIN" && -n "$VIVADO_BAT" && "$1" == /* ]]; then
        wslpath -w "$1"
    else
        printf '%s\n' "$1"
    fi
}
