#!/usr/bin/env bash
# Switch the Acer XF243Y to HDMI-1 (the Windows machine).
# Targets by serial number so it survives ddcutil display-number reshuffles.

LOG=/tmp/monitor-switch.log
ACER_SN=YOUR_MONITOR_SERIAL   # run `ddcutil detect` to find yours
HDMI_1=0x11

echo "[$(date '+%F %T')] arch->windows: switching Acer to HDMI-1" >> "$LOG"

if ddcutil --sn "$ACER_SN" setvcp 60 "$HDMI_1" 2>>"$LOG"; then
    notify-send "Monitor → Windows" "Acer switched to HDMI-1"
else
    notify-send -u critical "Monitor switch failed" "see $LOG"
fi
