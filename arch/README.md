# Arch side (`arch-pc`)

Hyprland / Wayland. Drives the shared Acer XF243Y over **DisplayPort-1**, and runs
both the monitor-switch hotkey and the lan-mouse daemon.

## Install
```bash
./install.sh
```
This:
1. Builds the patched lan-mouse (`../lan-mouse`) → installs to `~/.local/bin/lan-mouse`.
2. Installs the monitor-switch + helper scripts to `~/.config/hypr/scripts/`.
3. Installs `lan-mouse/config.toml` → `~/.config/lan-mouse/config.toml` (backs up any existing).
4. Appends the keybind + autostart snippets to `~/.config/hypr/{bindings,autostart}.conf` (only if missing).

Reload Hyprland (or re-login) afterwards, then `lan-mouse cli list` to confirm the peer link.

## Files
- `hypr/scripts/switch-to-windows.sh` — `ddcutil --sn <serial> setvcp 60 0x11` (Acer → Windows/HDMI).
- `hypr/scripts/find-hdmi.sh` — diagnostic: sweeps VCP-60 values to discover your monitor's HDMI input code.
- `hypr/scripts/monitors-off.sh` — bonus DDC helper: DPMS-off all detected monitors.
- `hypr/bindings.snippet.conf` — `Super+Alt+H` → switch-to-windows.
- `hypr/autostart.snippet.conf` — `exec-once` lan-mouse daemon (layer-shell capture backend).
- `lan-mouse/config.toml` — port, release-bind, the Windows client (position `left`), authorized fingerprint.

## Prerequisites
- `rustup` (to build lan-mouse), `ddcutil` (load the `i2c-dev` module, add your user to the `i2c` group), `libnotify`.
- A wlroots-based compositor (Hyprland here) — needed for the layer-shell capture and the virtual-pointer return-warp.

## Discover your monitor's serial / input codes
```bash
ddcutil detect                  # find the serial number (used to target the right monitor)
./hypr/scripts/find-hdmi.sh     # sweep to discover the HDMI VCP-60 value for your panel
```
Update `ACER_SN` and `HDMI_1` in `switch-to-windows.sh` for your monitor.
