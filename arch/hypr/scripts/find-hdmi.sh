 #!/usr/bin/env bash
  # Discover the HDMI input value for VCP 60 on the XF243Y.
  # Watch the screen — when it flips to HDMI, note the timestamp
  # in the log and find the matching value.
  # damn we back 1
  DP_VALUE=0x0f                    # adjust if your DP value differs
  LOG=/tmp/vcp60-scan.log
  : > "$LOG"

  # Reasonable candidate set — standard MCCS values plus Acer-custom ranges.
  CANDIDATES=(
    0x01 0x02 0x03 0x04 0x05 0x06 0x07 0x08
    0x09 0x0a 0x0b 0x0c 0x0d 0x0e 0x10
    0x11 0x12 0x13
    0x90 0x91 0x92 0x93
    0xa0 0xa1
    0xd0 0xd1 0xd2
  )

  for v in "${CANDIDATES[@]}"; do
    ts=$(date +%H:%M:%S)
    echo "[$ts] trying $v" | tee -a "$LOG"
    ddcutil setvcp 60 "$v" 2>>"$LOG"
    sleep 4                                # window to observe
    ddcutil setvcp 60 "$DP_VALUE" 2>>"$LOG"
    sleep 2                                # let DP re-sync
  done

  echo "done — scan log at $LOG"
