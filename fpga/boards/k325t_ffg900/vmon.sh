#!/usr/bin/env bash
# Log Vivado CPU/RAM + machine memory + build phase every INTERVAL seconds.
#   ./vmon.sh [vivado.log] [interval_s]      Ctrl-C to stop
# Screen: colored summary. File: ./vmon_<date>.csv (plain CSV)
LOG=${1:-vivado.log}
INT=${2:-30}
OUT=./vmon_$(date +%m%d_%H%M).csv
CORES=$(nproc)

G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'

# bar <pct>: 20-char bar
bar() { local f=$(( ($1 > 100 ? 100 : $1) / 5 )); printf '%*s' "$f" '' | tr ' ' '#'; printf '%*s' $((20 - f)) '' | tr ' ' '.'; }
# color by level: col <value> <yellow_at> <red_at>
col() { if (( $1 >= $3 )); then echo "$R"; elif (( $1 >= $2 )); then echo "$Y"; else echo "$G"; fi; }

echo "time,vivado_cpu%,cpu_of_machine%,vivado_ram_MB,vivado_ram%,avail_MB,avail%,swap_used_MB,swap%,phase" > "$OUT"
echo "${B}vmon${N}: ${LOG}, every ${INT}s, ${CORES} cores -> ${OUT}"
echo "${D}CPU: red = stalled (<50% of one core). RAM/swap: yellow/red = running out.${N}"

while true; do
    # %CPU from top's 2nd sample (the 1st is inaccurate), summed over all vivado procs
    cpu=$(top -b -n 2 -d 1 -u "$USER" | awk '/^top -/{n++} n==2 && $NF ~ /vivado/ {s+=$9} END{printf "%.0f", s}')
    ram=$(ps -u "$USER" -o rss=,comm= | awk '$2 ~ /vivado/ {s+=$1} END{printf "%.0f", s/1024}')
    read -r mtot mavail < <(free -m | awk '/^Mem/{print $2, $7}')
    read -r stot sused  < <(free -m | awk '/^Swap/{print $2, $3}')
    phase=$(grep -E '^(Start|Finished) |^Command: ' "$LOG" 2>/dev/null | tail -1 | cut -c1-60 | tr ',' ' ')

    cpum=$(( cpu / CORES ))
    ramp=$(( ram * 100 / mtot ))
    availp=$(( mavail * 100 / mtot ))
    swapp=$(( stot > 0 ? sused * 100 / stot : 0 ))
    usedp=$(( 100 - availp ))
    t=$(date +%T)

    echo "$t,$cpu,$cpum,$ram,$ramp,$mavail,$availp,$sused,$swapp,$phase" >> "$OUT"

    # CPU color is inverted: low = bad (stalled) once vivado is running
    if (( ram == 0 )); then cc=$D; elif (( cpu < 50 )); then cc=$R; elif (( cpu < 100 )); then cc=$Y; else cc=$G; fi
    mc=$(col "$usedp" 75 90); sc=$(col "$swapp" 1 10)
    printf '%s  CPU %s[%s] %3d%%%s %s(%d%% of 1 core)%s  RAM %s[%s] %3d%% used%s %s(vivado %.1fG, %.1fG free)%s  SWAP %s%3d%%%s  %s%s%s\n' \
        "$t" "$cc" "$(bar "$cpum")" "$cpum" "$N" "$D" "$cpu" "$N" \
        "$mc" "$(bar "$usedp")" "$usedp" "$N" "$D" "$(awk -v x="$ram" 'BEGIN{print x/1024}')" "$(awk -v x="$mavail" 'BEGIN{print x/1024}')" "$N" \
        "$sc" "$swapp" "$N" "$B" "${phase:-(no phase yet)}" "$N"
    sleep "$INT"
done
