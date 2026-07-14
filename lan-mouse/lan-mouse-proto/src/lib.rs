use input_event::{Event as InputEvent, KeyboardEvent, PointerEvent};
use num_enum::{IntoPrimitive, TryFromPrimitive, TryFromPrimitiveError};
use paste::paste;
use std::{
    fmt::{Debug, Display, Formatter},
    mem::size_of,
};
use thiserror::Error;

/// defines the maximum size an encoded event can take up
/// this is currently the pointer motion event
/// type: u8, time: u32, dx: f64, dy: f64
pub const MAX_EVENT_SIZE: usize = size_of::<u8>() + size_of::<u32>() + 2 * size_of::<f64>();

/// maximum size (in bytes) of a clipboard payload that can be sent over the wire.
/// kept conservative (4 KiB) so a single encoded clipboard datagram stays well
/// within typical network MTU limits.
pub const MAX_CLIPBOARD_SIZE: usize = 4 * 1024;

/// error type for protocol violations
#[derive(Debug, Error)]
pub enum ProtocolError {
    /// event type does not exist
    #[error("invalid event id: `{0}`")]
    InvalidEventId(#[from] TryFromPrimitiveError<EventType>),
    /// position type does not exist
    #[error("invalid event id: `{0}`")]
    InvalidPosition(#[from] TryFromPrimitiveError<Position>),
    /// a (variable-length) buffer was empty
    #[error("empty buffer")]
    EmptyBuffer,
    /// clipboard payload exceeds [`MAX_CLIPBOARD_SIZE`]
    #[error("clipboard data exceeds maximum size")]
    ClipboardTooLarge,
    /// clipboard payload was not valid utf-8
    #[error("invalid utf-8 in clipboard text")]
    InvalidUtf8,
    /// buffer ended before the full (declared) payload was read
    #[error("truncated buffer")]
    Truncated,
    /// a clipboard event was encountered on the fixed-size decode path
    #[error("clipboard event must be decoded with decode_clipboard")]
    ClipboardInFixedPath,
}

/// Position of a client
#[derive(Clone, Copy, Debug, TryFromPrimitive, IntoPrimitive)]
#[repr(u8)]
pub enum Position {
    Left,
    Right,
    Top,
    Bottom,
}

impl Display for Position {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let pos = match self {
            Position::Left => "left",
            Position::Right => "right",
            Position::Top => "top",
            Position::Bottom => "bottom",
        };
        write!(f, "{pos}")
    }
}

/// main lan-mouse protocol event type
#[derive(Clone, Debug)]
pub enum ProtoEvent {
    /// notify a client that the cursor entered its region at the given position
    /// [`ProtoEvent::Ack`] with the same serial is used for synchronization between devices
    Enter(Position),
    /// notify a client that the cursor left its region
    /// [`ProtoEvent::Ack`] with the same serial is used for synchronization between devices
    Leave(u32),
    /// acknowledge of an [`ProtoEvent::Enter`] or [`ProtoEvent::Leave`] event
    Ack(u32),
    /// Input event
    Input(InputEvent),
    /// Ping event for tracking unresponsive clients.
    /// A client has to respond with [`ProtoEvent::Pong`].
    Ping,
    /// Response to [`ProtoEvent::Ping`], true if emulation is enabled / available
    Pong(bool),
    /// Build identification for the sending peer. Sent by the
    /// connect side once after the connection authenticates, and
    /// echoed back by the listen side in reply, so each end can
    /// display the peer's build hash and warn (soft) on mismatch.
    /// `commit` is the 8-byte ASCII short commit hash from
    /// `shadow_rs`'s `SHORT_COMMIT`. Old peers that don't
    /// recognize the event type silently skip it per the
    /// forward-compat handling in the receive loop.
    Hello { commit: [u8; 8] },
    /// clipboard contents pushed to a peer at pointer-crossing time.
    /// Encoded/decoded with [`encode_clipboard`]/[`decode_clipboard`]
    /// (variable length), not the fixed-size path.
    Clipboard(String),
    /// notify a client of the normalized position (`0.0..=1.0`) along the
    /// entered edge where the cursor crossed in, so it can warp its cursor to
    /// the matching height/offset instead of recentering. Sent right after
    /// [`ProtoEvent::Enter`]; peers that don't know this event type silently
    /// skip it and fall back to their default entry position.
    EnterAt { pos: Position, edge_pos: f32 },
}

impl Display for ProtoEvent {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ProtoEvent::Enter(s) => write!(f, "Enter({s})"),
            ProtoEvent::Leave(s) => write!(f, "Leave({s})"),
            ProtoEvent::Ack(s) => write!(f, "Ack({s})"),
            ProtoEvent::Input(e) => write!(f, "{e}"),
            ProtoEvent::Ping => write!(f, "ping"),
            ProtoEvent::Pong(alive) => {
                write!(
                    f,
                    "pong: {}",
                    if *alive { "alive" } else { "not available" }
                )
            }
            ProtoEvent::Hello { commit } => {
                let s = std::str::from_utf8(commit).unwrap_or("????????");
                write!(f, "Hello({s})")
            }
            ProtoEvent::Clipboard(s) => write!(f, "Clipboard({} bytes)", s.len()),
            ProtoEvent::EnterAt { pos, edge_pos } => write!(f, "EnterAt({pos}, {edge_pos:.3})"),
        }
    }
}

#[derive(TryFromPrimitive, IntoPrimitive)]
#[repr(u8)]
pub enum EventType {
    PointerMotion,
    PointerButton,
    PointerAxis,
    PointerAxisValue120,
    KeyboardKey,
    KeyboardModifiers,
    Ping,
    Pong,
    Enter,
    Leave,
    Ack,
    Hello,
    Clipboard,
    EnterAt,
}

impl ProtoEvent {
    fn event_type(&self) -> EventType {
        match self {
            ProtoEvent::Input(e) => match e {
                InputEvent::Pointer(p) => match p {
                    PointerEvent::Motion { .. } => EventType::PointerMotion,
                    PointerEvent::Button { .. } => EventType::PointerButton,
                    PointerEvent::Axis { .. } => EventType::PointerAxis,
                    PointerEvent::AxisDiscrete120 { .. } => EventType::PointerAxisValue120,
                },
                InputEvent::Keyboard(k) => match k {
                    KeyboardEvent::Key { .. } => EventType::KeyboardKey,
                    KeyboardEvent::Modifiers { .. } => EventType::KeyboardModifiers,
                },
            },
            ProtoEvent::Ping => EventType::Ping,
            ProtoEvent::Pong(_) => EventType::Pong,
            ProtoEvent::Enter(_) => EventType::Enter,
            ProtoEvent::Leave(_) => EventType::Leave,
            ProtoEvent::Ack(_) => EventType::Ack,
            ProtoEvent::Hello { .. } => EventType::Hello,
            ProtoEvent::Clipboard(_) => EventType::Clipboard,
            ProtoEvent::EnterAt { .. } => EventType::EnterAt,
        }
    }
}

impl TryFrom<[u8; MAX_EVENT_SIZE]> for ProtoEvent {
    type Error = ProtocolError;

    fn try_from(buf: [u8; MAX_EVENT_SIZE]) -> Result<Self, Self::Error> {
        let mut buf = &buf[..];
        let event_type = decode_u8(&mut buf)?;
        match EventType::try_from(event_type)? {
            EventType::PointerMotion => {
                Ok(Self::Input(InputEvent::Pointer(PointerEvent::Motion {
                    time: decode_u32(&mut buf)?,
                    dx: decode_f64(&mut buf)?,
                    dy: decode_f64(&mut buf)?,
                })))
            }
            EventType::PointerButton => {
                Ok(Self::Input(InputEvent::Pointer(PointerEvent::Button {
                    time: decode_u32(&mut buf)?,
                    button: decode_u32(&mut buf)?,
                    state: decode_u32(&mut buf)?,
                })))
            }
            EventType::PointerAxis => Ok(Self::Input(InputEvent::Pointer(PointerEvent::Axis {
                time: decode_u32(&mut buf)?,
                axis: decode_u8(&mut buf)?,
                value: decode_f64(&mut buf)?,
            }))),
            EventType::PointerAxisValue120 => Ok(Self::Input(InputEvent::Pointer(
                PointerEvent::AxisDiscrete120 {
                    axis: decode_u8(&mut buf)?,
                    value: decode_i32(&mut buf)?,
                },
            ))),
            EventType::KeyboardKey => Ok(Self::Input(InputEvent::Keyboard(KeyboardEvent::Key {
                time: decode_u32(&mut buf)?,
                key: decode_u32(&mut buf)?,
                state: decode_u8(&mut buf)?,
            }))),
            EventType::KeyboardModifiers => Ok(Self::Input(InputEvent::Keyboard(
                KeyboardEvent::Modifiers {
                    depressed: decode_u32(&mut buf)?,
                    latched: decode_u32(&mut buf)?,
                    locked: decode_u32(&mut buf)?,
                    group: decode_u32(&mut buf)?,
                },
            ))),
            EventType::Ping => Ok(Self::Ping),
            EventType::Pong => Ok(Self::Pong(decode_u8(&mut buf)? != 0)),
            EventType::Enter => Ok(Self::Enter(decode_u8(&mut buf)?.try_into()?)),
            EventType::Leave => Ok(Self::Leave(decode_u32(&mut buf)?)),
            EventType::Ack => Ok(Self::Ack(decode_u32(&mut buf)?)),
            EventType::Hello => {
                let mut commit = [0u8; 8];
                for b in commit.iter_mut() {
                    *b = decode_u8(&mut buf)?;
                }
                Ok(Self::Hello { commit })
            }
            EventType::Clipboard => Err(ProtocolError::ClipboardInFixedPath),
            EventType::EnterAt => Ok(Self::EnterAt {
                pos: decode_u8(&mut buf)?.try_into()?,
                edge_pos: decode_f32(&mut buf)?,
            }),
        }
    }
}

impl From<ProtoEvent> for ([u8; MAX_EVENT_SIZE], usize) {
    fn from(event: ProtoEvent) -> Self {
        let mut buf = [0u8; MAX_EVENT_SIZE];
        let mut len = 0usize;
        {
            let mut buf = &mut buf[..];
            let buf = &mut buf;
            let len = &mut len;
            encode_u8(buf, len, event.event_type() as u8);
            match event {
                ProtoEvent::Input(event) => match event {
                    InputEvent::Pointer(p) => match p {
                        PointerEvent::Motion { time, dx, dy } => {
                            encode_u32(buf, len, time);
                            encode_f64(buf, len, dx);
                            encode_f64(buf, len, dy);
                        }
                        PointerEvent::Button {
                            time,
                            button,
                            state,
                        } => {
                            encode_u32(buf, len, time);
                            encode_u32(buf, len, button);
                            encode_u32(buf, len, state);
                        }
                        PointerEvent::Axis { time, axis, value } => {
                            encode_u32(buf, len, time);
                            encode_u8(buf, len, axis);
                            encode_f64(buf, len, value);
                        }
                        PointerEvent::AxisDiscrete120 { axis, value } => {
                            encode_u8(buf, len, axis);
                            encode_i32(buf, len, value);
                        }
                    },
                    InputEvent::Keyboard(k) => match k {
                        KeyboardEvent::Key { time, key, state } => {
                            encode_u32(buf, len, time);
                            encode_u32(buf, len, key);
                            encode_u8(buf, len, state);
                        }
                        KeyboardEvent::Modifiers {
                            depressed,
                            latched,
                            locked,
                            group,
                        } => {
                            encode_u32(buf, len, depressed);
                            encode_u32(buf, len, latched);
                            encode_u32(buf, len, locked);
                            encode_u32(buf, len, group);
                        }
                    },
                },
                ProtoEvent::Ping => {}
                ProtoEvent::Pong(alive) => encode_u8(buf, len, alive as u8),
                ProtoEvent::Enter(pos) => encode_u8(buf, len, pos as u8),
                ProtoEvent::Leave(serial) => encode_u32(buf, len, serial),
                ProtoEvent::Ack(serial) => encode_u32(buf, len, serial),
                ProtoEvent::Hello { commit } => {
                    for b in commit.iter() {
                        encode_u8(buf, len, *b);
                    }
                }
                ProtoEvent::Clipboard(_) => {
                    unreachable!("clipboard must be encoded with encode_clipboard")
                }
                ProtoEvent::EnterAt { pos, edge_pos } => {
                    encode_u8(buf, len, pos as u8);
                    encode_f32(buf, len, edge_pos);
                }
            }
        }
        (buf, len)
    }
}

/// length (in bytes) of the fixed clipboard header: `type` (u8) + `len` (u32 BE).
const CLIPBOARD_HEADER_LEN: usize = size_of::<u8>() + size_of::<u32>();

/// Encode a clipboard payload into a variable-length datagram of the form
/// `[EventType::Clipboard as u8][len: u32 big-endian][utf8 bytes]`.
///
/// Returns [`ProtocolError::ClipboardTooLarge`] if `text` exceeds
/// [`MAX_CLIPBOARD_SIZE`].
pub fn encode_clipboard(text: &str) -> Result<Vec<u8>, ProtocolError> {
    let bytes = text.as_bytes();
    if bytes.len() > MAX_CLIPBOARD_SIZE {
        return Err(ProtocolError::ClipboardTooLarge);
    }
    let mut buf = Vec::with_capacity(CLIPBOARD_HEADER_LEN + bytes.len());
    buf.push(EventType::Clipboard as u8);
    buf.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    buf.extend_from_slice(bytes);
    Ok(buf)
}

/// Decode a clipboard datagram produced by [`encode_clipboard`].
///
/// `buf[0]` is asserted to be [`EventType::Clipboard`] (callers reach this only
/// after dispatching on the type byte). Returns [`ProtocolError::Truncated`] if
/// the buffer is shorter than the declared payload, [`ProtocolError::ClipboardTooLarge`]
/// if the declared length exceeds [`MAX_CLIPBOARD_SIZE`], and
/// [`ProtocolError::InvalidUtf8`] if the payload is not valid utf-8.
pub fn decode_clipboard(buf: &[u8]) -> Result<ProtoEvent, ProtocolError> {
    if buf.len() < CLIPBOARD_HEADER_LEN {
        return Err(ProtocolError::Truncated);
    }
    let event_type = EventType::try_from(buf[0])?;
    assert!(
        matches!(event_type, EventType::Clipboard),
        "decode_clipboard called on non-clipboard buffer"
    );
    let len = u32::from_be_bytes([buf[1], buf[2], buf[3], buf[4]]) as usize;
    if len > MAX_CLIPBOARD_SIZE {
        return Err(ProtocolError::ClipboardTooLarge);
    }
    let end = CLIPBOARD_HEADER_LEN + len;
    if buf.len() < end {
        return Err(ProtocolError::Truncated);
    }
    let text = std::str::from_utf8(&buf[CLIPBOARD_HEADER_LEN..end])
        .map_err(|_| ProtocolError::InvalidUtf8)?
        .to_owned();
    Ok(ProtoEvent::Clipboard(text))
}

/// Unified variable-length decoder for incoming datagrams.
///
/// Clipboard events are decoded via [`decode_clipboard`]; every other event type
/// is decoded through the fixed-size [`ProtoEvent::try_from`] path (the buffer is
/// copied into a zero-initialized `[u8; MAX_EVENT_SIZE]`). An unknown event-type
/// byte makes [`EventType::try_from`] error, letting callers log and skip the
/// datagram while staying forward-compatible.
pub fn decode_event(buf: &[u8]) -> Result<ProtoEvent, ProtocolError> {
    if buf.is_empty() {
        return Err(ProtocolError::EmptyBuffer);
    }
    match EventType::try_from(buf[0])? {
        EventType::Clipboard => decode_clipboard(buf),
        _ => {
            let mut fixed = [0u8; MAX_EVENT_SIZE];
            let n = buf.len().min(MAX_EVENT_SIZE);
            fixed[..n].copy_from_slice(&buf[..n]);
            ProtoEvent::try_from(fixed)
        }
    }
}

macro_rules! decode_impl {
    ($t:ty) => {
        paste! {
            fn [<decode_ $t>](data: &mut &[u8]) -> Result<$t, ProtocolError> {
                let (int_bytes, rest) = data.split_at(size_of::<$t>());
                *data = rest;
                Ok($t::from_be_bytes(int_bytes.try_into().unwrap()))
            }
        }
    };
}

decode_impl!(u8);
decode_impl!(u32);
decode_impl!(i32);
decode_impl!(f32);
decode_impl!(f64);

macro_rules! encode_impl {
    ($t:ty) => {
        paste! {
            fn [<encode_ $t>](buf: &mut &mut [u8], amt: &mut usize, n: $t) {
                let src = n.to_be_bytes();
                let data = std::mem::take(buf);
                let (int_bytes, rest) = data.split_at_mut(size_of::<$t>());
                int_bytes.copy_from_slice(&src);
                *amt += size_of::<$t>();
                *buf = rest
            }
        }
    };
}

encode_impl!(u8);
encode_impl!(u32);
encode_impl!(i32);
encode_impl!(f32);
encode_impl!(f64);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enterat_roundtrip() {
        let ev = ProtoEvent::EnterAt {
            pos: Position::Right,
            edge_pos: 0.375,
        };
        let (buf, len): ([u8; MAX_EVENT_SIZE], usize) = ev.into();
        // type(1) + pos(1) + f32(4)
        assert_eq!(len, 6);
        match decode_event(&buf[..len]).unwrap() {
            ProtoEvent::EnterAt { pos, edge_pos } => {
                assert!(matches!(pos, Position::Right));
                assert!((edge_pos - 0.375).abs() < f32::EPSILON);
            }
            other => panic!("wrong variant: {other}"),
        }
    }

    #[test]
    fn clipboard_roundtrip() {
        let buf = encode_clipboard("hello clipboard").unwrap();
        match decode_event(&buf).unwrap() {
            ProtoEvent::Clipboard(s) => assert_eq!(s, "hello clipboard"),
            other => panic!("wrong variant: {other}"),
        }
    }

    #[test]
    fn clipboard_too_large_is_rejected() {
        let big = "x".repeat(MAX_CLIPBOARD_SIZE + 1);
        assert!(matches!(
            encode_clipboard(&big),
            Err(ProtocolError::ClipboardTooLarge)
        ));
    }

    #[test]
    fn legacy_enter_still_decodes() {
        // a stock peer sends Enter as a short [type, pos] datagram; ensure the
        // unified decoder handles buffers shorter than MAX_EVENT_SIZE.
        let (buf, len): ([u8; MAX_EVENT_SIZE], usize) = ProtoEvent::Enter(Position::Left).into();
        match decode_event(&buf[..len]).unwrap() {
            ProtoEvent::Enter(Position::Left) => {}
            other => panic!("wrong variant: {other}"),
        }
    }

    #[test]
    fn unknown_event_type_is_an_error_not_a_panic() {
        // a byte beyond the known EventType range (forward-compat: a peer on a
        // newer build) must decode to an error so callers can skip it.
        let buf = [200u8; MAX_EVENT_SIZE];
        assert!(decode_event(&buf).is_err());
    }
}
