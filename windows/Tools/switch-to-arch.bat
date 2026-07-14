@echo off
REM Switch the shared Acer XF243Y back to DisplayPort-1 (the Arch PC).
REM VCP 0x60 Input Select:  15 = DisplayPort-1 (Arch),  17 = HDMI-1 (Windows).
REM This runs while Windows is the active HDMI input, so DDC is reliable.
REM Replace the serial below with your monitor's (see it in ControlMyMonitor's list,
REM or via `ddcutil detect` on the Linux box).
start "" /wait "C:\Tools\ControlMyMonitor.exe" /SetValue YOUR_MONITOR_SERIAL 60 15
REM (Phase 2 - input handoff) uncomment once the lan-mouse 'arch' client id is known:
REM "C:\Tools\lan-mouse\lan-mouse.exe" cli activate 0
