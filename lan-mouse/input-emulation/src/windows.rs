use super::error::{EmulationError, WindowsEmulationCreationError};
use input_event::{
    BTN_BACK, BTN_FORWARD, BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, Event, KeyboardEvent, PointerEvent,
    scancode,
};

use async_trait::async_trait;
use std::ops::BitOrAssign;
use std::time::Duration;
use tokio::task::AbortHandle;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE,
    MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN,
    MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
    MOUSEEVENTF_WHEEL, MOUSEINPUT,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    INPUT_0, KEYEVENTF_EXTENDEDKEY, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, SendInput,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN, SetCursorPos, XBUTTON1, XBUTTON2,
};
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, DESKTOP_ACCESS_FLAGS, DESKTOP_CONTROL_FLAGS, DESKTOP_CREATEMENU,
    DESKTOP_CREATEWINDOW, DESKTOP_ENUMERATE, DESKTOP_HOOKCONTROL, DESKTOP_JOURNALPLAYBACK,
    DESKTOP_JOURNALRECORD, DESKTOP_READOBJECTS, DESKTOP_SWITCHDESKTOP, DESKTOP_WRITEOBJECTS,
    GetProcessWindowStation, GetThreadDesktop, GetUserObjectInformationW, HDESK, OpenInputDesktop,
    SetThreadDesktop, UOI_NAME,
};
use windows::Win32::Foundation::{GetLastError, HANDLE};
use windows::Win32::System::Threading::GetCurrentThreadId;
use std::cell::Cell;
use std::time::Instant;

use super::{Emulation, EmulationHandle, Position};

const DEFAULT_REPEAT_DELAY: Duration = Duration::from_millis(500);
const DEFAULT_REPEAT_INTERVAL: Duration = Duration::from_millis(32);

pub(crate) struct WindowsEmulation {
    repeat_task: Option<AbortHandle>,
}

impl WindowsEmulation {
    pub(crate) fn new() -> Result<Self, WindowsEmulationCreationError> {
        // Log which window-station/desktop we were launched onto. If this is not
        // `WinSta0` / `Default`, SendInput will "succeed" into a desktop nobody
        // can see — the core failure we're chasing.
        log_desktop_context("emulation-start");
        Ok(Self { repeat_task: None })
    }
}

#[async_trait]
impl Emulation for WindowsEmulation {
    async fn consume(&mut self, event: Event, _: EmulationHandle) -> Result<(), EmulationError> {
        // Make sure we inject onto the desktop that is actually on screen before
        // emitting any events (see `ensure_input_desktop`). Cheap + throttled.
        ensure_input_desktop(false);
        match event {
            Event::Pointer(pointer_event) => match pointer_event {
                PointerEvent::Motion { time: _, dx, dy } => {
                    rel_mouse(dx as i32, dy as i32);
                }
                PointerEvent::Button {
                    time: _,
                    button,
                    state,
                } => mouse_button(button, state),
                PointerEvent::Axis {
                    time: _,
                    axis,
                    value,
                } => scroll(axis, value as i32),
                PointerEvent::AxisDiscrete120 { axis, value } => scroll(axis, value),
            },
            Event::Keyboard(keyboard_event) => match keyboard_event {
                KeyboardEvent::Key {
                    time: _,
                    key,
                    state,
                } => {
                    match state {
                        // pressed
                        0 => self.kill_repeat_task(),
                        1 => self.spawn_repeat_task(key).await,
                        _ => {}
                    }
                    key_event(key, state)
                }
                KeyboardEvent::Modifiers { .. } => {}
            },
        }
        // FIXME
        Ok(())
    }

    async fn create(&mut self, _handle: EmulationHandle) {}

    async fn destroy(&mut self, _handle: EmulationHandle) {}

    async fn terminate(&mut self) {}

    async fn warp(&mut self, pos: Position, edge_pos: f32) -> Result<(), EmulationError> {
        ensure_input_desktop(false);
        warp_cursor(pos, edge_pos);
        Ok(())
    }
}

/// Place the cursor on the primary monitor's `pos` edge, `edge_pos` of the way
/// along it (0.0 = top/left, 1.0 = bottom/right). Called on `EnterAt` so a
/// pointer crossing in from a peer lands at the matching height/offset instead
/// of wherever it last sat. Subsequent relative motion continues from here.
fn warp_cursor(pos: Position, edge_pos: f32) {
    let f = edge_pos.clamp(0.0, 1.0);
    unsafe {
        let (w, h) = (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        if w <= 0 || h <= 0 {
            return;
        }
        let along_x = (f * (w - 1) as f32).round() as i32;
        let along_y = (f * (h - 1) as f32).round() as i32;
        let (x, y) = match pos {
            Position::Left => (0, along_y),
            Position::Right => (w - 1, along_y),
            Position::Top => (along_x, 0),
            Position::Bottom => (along_x, h - 1),
        };
        let _ = SetCursorPos(x, y);
    }
}

impl WindowsEmulation {
    async fn spawn_repeat_task(&mut self, key: u32) {
        // there can only be one repeating key and it's
        // always the last to be pressed
        self.kill_repeat_task();
        let repeat_task = tokio::task::spawn_local(async move {
            tokio::time::sleep(DEFAULT_REPEAT_DELAY).await;
            loop {
                key_event(key, 1);
                tokio::time::sleep(DEFAULT_REPEAT_INTERVAL).await;
            }
        });
        self.repeat_task = Some(repeat_task.abort_handle());
    }
    fn kill_repeat_task(&mut self) {
        if let Some(task) = self.repeat_task.take() {
            task.abort();
        }
    }
}

/// Desktop access rights needed to attach to and inject into a desktop
/// (`DESKTOP_RIGHTS` — every desktop-specific right).
const DESK_ACCESS: DESKTOP_ACCESS_FLAGS = DESKTOP_ACCESS_FLAGS(
    DESKTOP_READOBJECTS.0
        | DESKTOP_WRITEOBJECTS.0
        | DESKTOP_CREATEWINDOW.0
        | DESKTOP_CREATEMENU.0
        | DESKTOP_HOOKCONTROL.0
        | DESKTOP_JOURNALRECORD.0
        | DESKTOP_JOURNALPLAYBACK.0
        | DESKTOP_ENUMERATE.0
        | DESKTOP_SWITCHDESKTOP.0,
);

/// Don't re-query the input desktop more often than this on the hot path.
const REBIND_THROTTLE: Duration = Duration::from_millis(250);

/// Bounded retries for a refused `SendInput`, so a genuinely inaccessible
/// desktop (the SYSTEM-owned secure/lock desktop) can never spin us forever —
/// the previous code looped here without a limit, which wedged the entire
/// emulation pipeline the instant injection was blocked.
const MAX_SEND_INPUT_ATTEMPTS: u32 = 8;

thread_local! {
    /// Handle to the desktop our thread is currently attached to, kept so we can
    /// release the previous one when the input desktop changes.
    static BOUND_DESKTOP: Cell<Option<HDESK>> = const { Cell::new(None) };
    static LAST_BIND: Cell<Option<Instant>> = const { Cell::new(None) };
}

/// Read the name (UOI_NAME) of a window-station / desktop user object.
unsafe fn user_object_name(h: HANDLE) -> String {
    let mut buf = [0u16; 256];
    let mut needed = 0u32;
    if GetUserObjectInformationW(
        h,
        UOI_NAME,
        Some(buf.as_mut_ptr().cast()),
        (buf.len() * 2) as u32,
        Some(&mut needed),
    )
    .is_err()
    {
        return "<unknown>".to_string();
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..len])
}

/// Log the process window station + this thread's desktop + the current input
/// desktop, all by name. Diagnostic for the "input goes to an invisible desktop"
/// failure: if `process_winsta` isn't `WinSta0`, our injection can never reach
/// the screen no matter what desktop we bind to.
fn log_desktop_context(when: &str) {
    unsafe {
        let station = GetProcessWindowStation()
            .map(|ws| user_object_name(HANDLE(ws.0)))
            .unwrap_or_else(|e| format!("<err {e:?}>"));
        let thread_desktop = GetThreadDesktop(GetCurrentThreadId())
            .map(|d| user_object_name(HANDLE(d.0)))
            .unwrap_or_else(|e| format!("<err {e:?}>"));
        let input_desktop = match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESK_ACCESS) {
            Ok(d) => {
                let n = user_object_name(HANDLE(d.0));
                let _ = CloseDesktop(d);
                n
            }
            Err(e) => format!("<OpenInputDesktop err {e:?}>"),
        };
        log::info!(
            "[desktop-diag {when}] process_winsta={station:?} thread_desktop={thread_desktop:?} input_desktop={input_desktop:?}"
        );
    }
}

/// Attach the calling (emulation) thread to the desktop currently receiving user
/// input, so `SendInput` / `SetCursorPos` land on the desktop shown on screen.
///
/// Why this is necessary: lan-mouse can be launched onto a window-station/desktop
/// that is NOT the visible `Winsta0\Default` — e.g. when started by an AtLogOn
/// scheduled task. A thread's desktop is fixed for its lifetime, and `SendInput`
/// queues into *that* desktop's input, returning success even when it is not the
/// one being displayed. The symptom is brutal: the peer connects and the daemon
/// acknowledges, yet not one keystroke or mouse move ever reaches the screen.
/// Re-binding to `OpenInputDesktop()` right before injecting fixes it regardless
/// of how we were launched, and — by following the input desktop — also recovers
/// across lock/unlock and UAC secure-desktop switches when they're accessible.
///
/// Throttled to once per [`REBIND_THROTTLE`] on the hot path; pass `force` to
/// rebind immediately (used right after a `SendInput` was refused).
fn ensure_input_desktop(force: bool) {
    let due = LAST_BIND.with(|l| match l.get() {
        Some(t) if !force && t.elapsed() < REBIND_THROTTLE => false,
        _ => {
            l.set(Some(Instant::now()));
            true
        }
    });
    if !due {
        return;
    }
    unsafe {
        // `OpenInputDesktop` fails for the secure desktop at our integrity level;
        // in that case keep the current binding and let `SendInput` drop.
        let hdesk = match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESK_ACCESS) {
            Ok(h) => h,
            Err(_) => return,
        };
        match SetThreadDesktop(hdesk) {
            Ok(()) => {
                // we're now attached to `hdesk`; release the previous one
                if let Some(prev) = BOUND_DESKTOP.with(|c| c.replace(Some(hdesk))) {
                    if prev.0 != hdesk.0 {
                        let _ = CloseDesktop(prev);
                    }
                }
            }
            Err(_) => {
                let _ = CloseDesktop(hdesk);
            }
        }
    }
}

fn send_input_safe(input: INPUT) -> u32 {
    unsafe {
        let mut ret = 0u32;
        for _ in 0..MAX_SEND_INPUT_ATTEMPTS {
            /* retval = number of successfully submitted events */
            ret = SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
            if ret > 0 {
                return ret;
            }
            // Refused (returns 0): usually our thread is no longer on the input
            // desktop (a lock / secure-desktop / UAC switch). Re-bind and retry.
            ensure_input_desktop(true);
        }
        log::debug!(
            "SendInput refused after {MAX_SEND_INPUT_ATTEMPTS} attempts, GetLastError={:?}",
            GetLastError()
        );
        ret
    }
}

fn send_mouse_input(mi: MOUSEINPUT) {
    let _ = send_input_safe(INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi },
    });
}

fn send_keyboard_input(ki: KEYBDINPUT) {
    let ret = send_input_safe(INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki },
    });
    // Low-frequency (real key presses), so safe to log: shows whether keystrokes
    // are actually accepted by SendInput (vs. silently filtered).
    log::debug!(
        "SendInput KEY scan={:#06x} flags={:#x} -> {ret}",
        ki.wScan,
        ki.dwFlags.0
    );
}
fn rel_mouse(dx: i32, dy: i32) {
    let mi = MOUSEINPUT {
        dx,
        dy,
        mouseData: 0,
        dwFlags: MOUSEEVENTF_MOVE,
        time: 0,
        dwExtraInfo: 0,
    };
    send_mouse_input(mi);
}

fn mouse_button(button: u32, state: u32) {
    let dw_flags = match state {
        0 => match button {
            BTN_LEFT => MOUSEEVENTF_LEFTUP,
            BTN_RIGHT => MOUSEEVENTF_RIGHTUP,
            BTN_MIDDLE => MOUSEEVENTF_MIDDLEUP,
            BTN_BACK => MOUSEEVENTF_XUP,
            BTN_FORWARD => MOUSEEVENTF_XUP,
            _ => return,
        },
        1 => match button {
            BTN_LEFT => MOUSEEVENTF_LEFTDOWN,
            BTN_RIGHT => MOUSEEVENTF_RIGHTDOWN,
            BTN_MIDDLE => MOUSEEVENTF_MIDDLEDOWN,
            BTN_BACK => MOUSEEVENTF_XDOWN,
            BTN_FORWARD => MOUSEEVENTF_XDOWN,
            _ => return,
        },
        _ => return,
    };
    let mouse_data = match button {
        BTN_BACK => XBUTTON1 as u32,
        BTN_FORWARD => XBUTTON2 as u32,
        _ => 0,
    };
    let mi = MOUSEINPUT {
        dx: 0,
        dy: 0, // no movement
        mouseData: mouse_data,
        dwFlags: dw_flags,
        time: 0,
        dwExtraInfo: 0,
    };
    send_mouse_input(mi);
}

fn scroll(axis: u8, value: i32) {
    let event_type = match axis {
        0 => MOUSEEVENTF_WHEEL,
        1 => MOUSEEVENTF_HWHEEL,
        _ => return,
    };
    let mi = MOUSEINPUT {
        dx: 0,
        dy: 0,
        mouseData: -value as u32,
        dwFlags: event_type,
        time: 0,
        dwExtraInfo: 0,
    };
    send_mouse_input(mi);
}

fn key_event(key: u32, state: u8) {
    let scancode = match linux_keycode_to_windows_scancode(key) {
        Some(code) => code,
        None => return,
    };
    let extended = scancode > 0xff;
    let scancode = scancode & 0xff;
    let mut flags = KEYEVENTF_SCANCODE;
    if extended {
        flags.bitor_assign(KEYEVENTF_EXTENDEDKEY);
    }
    if state == 0 {
        flags.bitor_assign(KEYEVENTF_KEYUP);
    }
    let ki = KEYBDINPUT {
        wVk: Default::default(),
        wScan: scancode,
        dwFlags: flags,
        time: 0,
        dwExtraInfo: 0,
    };
    send_keyboard_input(ki);
}

fn linux_keycode_to_windows_scancode(linux_keycode: u32) -> Option<u16> {
    let linux_scancode = match scancode::Linux::try_from(linux_keycode) {
        Ok(s) => s,
        Err(_) => {
            log::warn!("unknown keycode: {linux_keycode}");
            return None;
        }
    };
    log::trace!("linux code: {linux_scancode:?}");
    let windows_scancode = match scancode::Windows::try_from(linux_scancode) {
        Ok(s) => s,
        Err(_) => {
            log::warn!("failed to translate linux code into windows scancode: {linux_scancode:?}");
            return None;
        }
    };
    log::trace!("windows code: {windows_scancode:?}");
    Some(windows_scancode as u16)
}
