# HDMI Software Switcher + lan-mouse KVM

A do-it-yourself **software KVM** for two desktops — an **Arch Linux** box and a
**Windows 11** box — that share a **single physical monitor**. One keystroke flips the
monitor's input between the two machines over **DDC/CI**, and a patched build of
[lan-mouse](https://github.com/feschber/lan-mouse) shares one **mouse + keyboard +
clipboard** across both, over an encrypted DTLS link on the LAN (or Tailscale).

The result feels like a single computer with two brains: move the pointer off the edge
of the screen and it lands on the other machine at the exact height it left; press the
hotkey and the monitor follows. No hardware KVM, no second keyboard, no cables to swap.

> This repo is the real, working setup — generalized into a reusable template.
> Hostnames, IPs, and monitor serials have been replaced with placeholders you fill in.

---

## Contents

- [How it works](#how-it-works)
- [The lan-mouse fork — engineering deep-dive](#the-lan-mouse-fork--engineering-deep-dive)
- [Hard problems solved along the way](#hard-problems-solved-along-the-way)
- [Repository layout](#repository-layout)
- [Setup](#setup)
- [Certificates & fingerprints are per-machine](#certificates--fingerprints-are-per-machine)
- [Credits & license](#credits--license)

---

## How it works

Two machines, one monitor, two independent links to it:

```
                     ┌─────────────────────────────┐
                     │      shared monitor          │
                     │  DisplayPort-1 ── HDMI-1     │
                     └────▲───────────────▲─────────┘
             DisplayPort  │               │  HDMI
                          │               │
        ┌─────────────────┴───┐     ┌─────┴───────────────┐
        │  Arch Linux         │     │  Windows 11         │
        │  (arch-pc)          │     │  (win-pc)           │
        │  Hyprland/Wayland   │     │                     │
        │                     │     │                     │
        │  physical kbd+mouse │◄───►│  emulated input     │
        └─────────────────────┘     └─────────────────────┘
              lan-mouse daemon  ══ DTLS/UDP 4242 ══  lan-mouse daemon
                        (LAN or Tailscale, encrypted)
```

**Two independent subsystems, one seamless experience:**

**1. Monitor switching — DDC/CI.** The monitor's input source is a writable register
(VCP `0x60`, *Input Select*) exposed over the display cable via DDC/CI. A hotkey on each
machine writes that register:

| Press | On | Effect | Tool |
|-------|----|--------|------|
| `Super+Alt+H` | Arch | monitor → Windows (HDMI) | `ddcutil` |
| `Win+Alt+H`   | Windows | monitor → Arch (DisplayPort) | NirSoft `ControlMyMonitor.exe` |

**Design principle — *each machine switches the monitor away from itself*.** The DDC
write always travels over the machine's **own, currently-active** video link (which is
guaranteed up, because that machine is the one you're looking at), so it's reliable
every time. As a bonus, the same physical key (`Super`/`Win` is the same scancode) works
symmetrically in both directions.

**2. Input sharing — lan-mouse.** A `lan-mouse` daemon runs on both machines. The active
machine arms a **1-pixel capture barrier** at the shared screen edge; when the pointer
hits it, motion + keystrokes are serialized and sent to the peer over DTLS, which
re-emulates them locally. Cross back over the opposite edge (or hit the release chord)
to return. Clipboard contents ride the same encrypted channel.

Put together: cross the pointer *and* tap the hotkey and you've handed the whole desk —
screen, mouse, keyboard, clipboard — to the other machine in under a second.

---

## The lan-mouse fork — engineering deep-dive

Stock lan-mouse is excellent, but a single-monitor, asymmetric (Wayland ↔ Windows)
setup exposed a few rough edges. Rather than work around them, this repo vendors a
**patched fork** (base: upstream `feschber/lan-mouse` **v0.11.0**, commit `133e1ae`;
Rust; GPL-3.0). The patches touch the wire protocol, the Wayland capture/emulation
backends, and the Windows emulation backend. Highlights:

### 1. Accurate cross-over height — a new `EnterAt` protocol event

**Problem.** Upstream signals a crossing with a bare `Enter` event — it says *"the
pointer entered from this edge"* but not *where along the edge*. On entry the peer drops
the cursor at a default position, so crossing from the top of the Linux screen could
land you in the middle of the Windows screen. Jarring.

**Fix.** A new fixed-size wire event, `ProtoEvent::EnterAt { pos, edge_pos }`
(EventType 13, 6 bytes), sent immediately after `Enter`. Both sides compute the
**normalized crossing fraction** along the shared edge — `layer_shell.rs` on Wayland,
`display_util.rs::edge_fraction` on Windows — and the receiver **warps its local cursor**
to the matching offset via a new `Emulation::warp(pos, edge_pos)` trait method (default
no-op, implemented per-backend). On Windows that's `GetSystemMetrics` + `SetCursorPos`.

*Result: Linux→Windows entry now lands at the exact height you crossed at.*

### 2. Pixel-accurate return warp on Wayland — absolute virtual-pointer motion

**Problem (the subtle one).** The Windows→Linux *return* isn't driven by an `Enter` at
the Linux **emulation** side — it's driven by a `Leave` arriving at the Linux **capture**
side (Windows' emulation emits `Leave` when its cursor leaves the screen). So the
emulation-side warp above never fires on return, and the cursor reappeared drifting
across the middle of the screen, the offset *scaling with how far you'd travelled in
Windows*. A position *hint* (`set_cursor_position_hint`) fixed the Y but not the X,
because the capture surface is only 1px wide.

**Fix.** In `layer_shell.rs::ungrab()`, warp the cursor **explicitly and absolutely**
with `zwlr_virtual_pointer_v1::motion_absolute` (via a newly-bound
`virtual_pointer_manager` + a persistent `warp_pointer`), mapping the crossing fraction
back onto the layout edge and insetting ~0.25 % so it doesn't land *on* the barrier and
immediately re-cross. The same `warp` is also implemented on the wlroots **emulation**
backend for the symmetric/`EnterAt` path.

*Result, confirmed at the desk: the cursor returns to the exact edge and height it left
from, independent of travel distance in Windows.* (Linux-only patch — the Windows binary
is unaffected.)

### 3. Clipboard over DTLS — "sync at crossing", no polling

**Problem.** Upstream shares pointer/keyboard but not the clipboard, so copy-paste
between the machines meant a detour through some third channel.

**Fix.** A new top-level `ProtoEvent::Clipboard(String)` (EventType 12) with a
**variable-length frame** (`encode_clipboard` / `decode_clipboard` / `decode_event` in
`lan-mouse-proto`) and a long-lived [`arboard`](https://crates.io/crates/arboard) worker
(`src/clipboard.rs`). The clipboard is read once **on cross-out** (`src/capture.rs`) and
set **on receive** (`src/emulation.rs`) — event-driven, no polling. Verified on Wayland
(`wlr-data-control`, read + write) and on Windows (native Win32 backend, auto-selected).

Gated behind `enable_clipboard` and **off by default**, because a >21-byte clipboard
datagram would break a *stock* peer's fixed-size receive loop — so it's only safe when
both ends run the fork (as they do here). Enabled on both, or neither. Never one-sided.

### 4. Forward- and backward-compatible wire protocol

All new events are designed so a **stock** peer degrades gracefully: the small
fixed-size `EnterAt` is simply skipped by an older receiver, and the variable-length
`Clipboard` frame stays behind its feature flag. Five protocol round-trip / forward-compat
tests cover the encode/decode paths (`cargo test -p lan-mouse-proto`).

### 5. Windows cross-compilation from Arch — daemon-only, no GTK

The Windows binary is **cross-compiled on the Linux box** (`x86_64-pc-windows-gnu` via
the mingw-w64 linker) rather than maintaining a Windows toolchain — see
[`windows/cross-build-exe.sh`](windows/cross-build-exe.sh). Built with
`--no-default-features` to drop the GTK GUI and all Linux capture/emulation backends;
the Windows backends select themselves via `#[cfg(windows)]`. This required splitting
`arboard` target-specifically in `Cargo.toml` (`wayland-data-control` only on
`cfg(target_os = "linux")`, plain `arboard` elsewhere) so the cross build links cleanly.

---

## Hard problems solved along the way

The interesting engineering here was as much *operations* as code — getting reliable
input injection into a **headless** Windows box (no physical keyboard or mouse attached;
reachable only over the network) took a chain of non-obvious fixes, each root-caused by
elimination:

- **Windows silently dropped injected input** until the daemon ran at **High integrity**.
  A medium-integrity daemon sits on the correct `WinSta0\Default` desktop and *looks*
  connected — the peer authenticates and ACKs — yet `SetCursorPos` returns `FALSE` and
  `SendInput` returns `1` with **no visible effect**. Not a lock, desktop, or
  window-station problem (all ruled out live). Fix: run the daemon from a scheduled task
  at `RunLevel Highest`. See the write-up in [`windows/install.ps1`](windows/install.ps1).

- **The Windows cursor was invisible.** With no physical mouse installed, Windows keeps
  the pointer's internal display-count at `-1` and never draws it. Fix: enable **Mouse
  Keys** (`SystemParametersInfo(SPI_SETMOUSEKEYS)`), which forces the cursor visible. The
  effect is per-session and doesn't survive a reboot, so it's re-applied by an at-logon
  scheduled task — plus a `Win+Alt+M` hotkey to force it back on demand.

- **Idle auto-lock killed input sharing.** A normal process can't inject into the Windows
  lock screen (an isolated, SYSTEM-owned secure desktop), so an idle lock silently broke
  the KVM until manual unlock. Fix: disable the idle lock + AC sleep (conservative —
  password-on-wake left intact).

- **No console window, but full logging.** Because the box is headless, the daemon is
  launched hidden (a `.vbs` runs it with window-style 0) yet still inside the interactive
  logon session (which injection requires), redirecting stdout/stderr to a log file — the
  only practical way to debug a machine you can't sit in front of. An interactive
  scheduled task lets the whole thing be **restarted over SSH** after pushing a new build.

If you're a reviewer skimming for depth: `windows/install.ps1` and the fork's
`input-capture` / `input-emulation` / `lan-mouse-proto` crates are where the substance is.

---

## Repository layout

```
.
├── arch/                    # Arch Linux (Hyprland / Wayland) side
│   ├── install.sh           #   build lan-mouse + install config, scripts, keybind, autostart
│   ├── hypr/
│   │   ├── scripts/         #   switch-to-windows.sh, find-hdmi.sh, monitors-off.sh
│   │   ├── bindings.snippet.conf
│   │   └── autostart.snippet.conf
│   └── lan-mouse/config.toml #   DTLS peer, screen position, authorized fingerprint (template)
├── windows/                 # Windows 11 side
│   ├── install.ps1          #   Tools, Mouse Keys, firewall, hidden daemon, scheduled tasks
│   ├── cross-build-exe.sh   #   cross-compile lan-mouse.exe (run on the Arch box)
│   ├── Tools/               #   switch-to-arch.bat, switch-hotkey.ahk, enable-mousekeys.*
│   └── lan-mouse/config.toml #   template
├── lan-mouse/               # VENDORED patched lan-mouse source (builds on Arch + Windows)
└── README.md
```

Each side also has its own README: [`arch/README.md`](arch/README.md),
[`windows/README.md`](windows/README.md).

---

## Setup

**Prerequisites.** Arch: `rustup`, `ddcutil` (with the `i2c-dev` module loaded and your
user in the `i2c` group), `libnotify`, and a wlroots-based compositor (built for
Hyprland). Windows: `ControlMyMonitor.exe` (NirSoft), AutoHotkey v2, the VC++ x64
Redistributable. Monitor must have **DDC/CI enabled** in its OSD.

**Arch side:**
```bash
git clone <this-repo> hdmi-software-switcher && cd hdmi-software-switcher
./arch/install.sh          # builds the patched lan-mouse, installs config + hypr keybind/autostart
# then edit ~/.config/lan-mouse/config.toml (peer IP + fingerprint), and set your
# monitor's serial in ~/.config/hypr/scripts/switch-to-windows.sh (`ddcutil detect`)
```

**Build the Windows `lan-mouse.exe` (on the Arch box):**
```bash
./windows/cross-build-exe.sh win-pc   # cross-compiles, then scp's it to the Windows box
```

**Windows side** — from an **elevated** PowerShell in `windows\`:
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install.ps1
```

Then set your monitor serial in `C:\Tools\switch-to-arch.bat`, log out/in, and verify:
`Get-Process lan-mouse`, then press `Win+Alt+H`.

---

## Certificates & fingerprints are per-machine

lan-mouse authenticates peers by **TLS certificate fingerprint** (no CA). Each machine
generates its own key + cert (`lan-mouse.pem`) on first daemon run — so the fingerprints
and peer IPs are unique to *your* setup. The committed `config.toml` files are
**templates with placeholders**. On a fresh install:

1. Start the daemon once on each machine so it generates its cert.
2. Copy each machine's fingerprint (logged on startup) into the **peer's**
   `[authorized_fingerprints]`.
3. Set each peer's reachable IP (a Tailscale IP is ideal — stable and encrypted) under
   `[[clients]]`.

**Private keys (`*.pem`) are gitignored and never committed.** Nothing in this repo
contains real keys, fingerprints, addresses, or hostnames.

---

## Credits & license

The `lan-mouse/` subtree is a patched copy of
[feschber/lan-mouse](https://github.com/feschber/lan-mouse), licensed **GPL-3.0-or-later**;
its `LICENSE` is preserved in-tree, and all modifications are described above. Huge thanks
to the upstream project — it does the hard part.

The integration glue in this repo — the DDC switch scripts, install automation, hypr
snippets, and the fork patches themselves — is provided as-is for anyone building a
similar single-monitor, two-machine desk.
