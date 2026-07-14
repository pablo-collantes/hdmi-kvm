#!/usr/bin/env bash
# DDC/CI VCP 0xD6 = power mode. 0x04 = DPMS off (recoverable),
# 0x05 = hard off (often won't wake via DDC — needs physical button).
LOG=/tmp/monitor-power.log
POWER_OFF=0x04

echo "[$(date '+%F %T')] monitors-off invoked (val=$POWER_OFF)" >> "$LOG"

displays=$(ddcutil detect --brief 2>>"$LOG" | grep -oP '^Display \K[0-9]+')
if [[ -z "$displays" ]]; then
    notify-send -u critical "Monitors off failed" "no DDC/CI displays detected (see $LOG)"
    exit 1
fi

for d in $displays; do
    ddcutil --display "$d" --noverify setvcp d6 "$POWER_OFF" >>"$LOG" 2>&1
done

notify-send "Monitors" "All monitors → DPMS off"
