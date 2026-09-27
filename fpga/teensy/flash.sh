#!/usr/bin/env bash
# Flash uart_bridge to a Teensy 4.1.  ./flash.sh [compile]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKETCH="$HERE/uart_bridge"
FQBN="teensy:avr:teensy41:usb=serial2"   # Dual Serial

# For Apple Silicon needs to use Homebrew ctags
CTAGS_ARGS=()
if command -v ctags >/dev/null && [[ "$(uname -m)" == "arm64" ]]; then
    CTAGS_DIR="$(dirname "$(command -v ctags)")"
    CTAGS_ARGS=(--build-property "tools.ctags.path=$CTAGS_DIR"
                --build-property "tools.ctags.cmd.path=$CTAGS_DIR/ctags")
fi

arduino-cli compile --fqbn "$FQBN" "${CTAGS_ARGS[@]}" "$SKETCH"
[[ "${1:-}" == "compile" ]] && exit 0

PORT="$(arduino-cli board list | awk '/teensy/ {print $1; exit}')"
if [[ -z "$PORT" ]]; then
    echo "No Teensy found. Plug it in (a data USB cable, not charge-only) and retry." >&2
    echo "If it still doesn't show up, press the white button on the Teensy once, then retry." >&2
    exit 1
fi
echo "Uploading to Teensy on $PORT ..."
arduino-cli upload --fqbn "$FQBN" -p "$PORT" "$SKETCH"
echo "Done. The Teensy now shows up as a USB serial port - see: python ../boards/k325t_ffg900/uart ports"
