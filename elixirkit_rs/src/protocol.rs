//! Internal bridge envelopes layered over the current `PubSub` transport.
//!
//! This keeps the framed TCP transport exactly as it is today while reserving
//! one internal topic for structured bridge messages. The envelope body stays
//! opaque bytes for now. This module also owns the narrow internal call
//! body/result encoding used by the current broker so the bridge wire format
//! stays in one place; request tracking and capability routing still live
//! elsewhere.
#![expect(
    dead_code,
    reason = "The protocol seam is staged for later bridge-core integration before public call or dispatch APIs exist"
)]
#![expect(
    clippy::redundant_pub_crate,
    reason = "Protocol items stay crate-visible for the internal seam while the module remains internal to the crate"
)]

use std::io;
use std::str;

use crate::PubSub;

const MAGIC: [u8; 4] = *b"EKBP";
const KIND_REQUEST: u8 = 1;
const KIND_RESPONSE: u8 = 2;
const KIND_EVENT: u8 = 3;
const CALL_RESULT_OK: u8 = 0;
const CALL_RESULT_ERROR: u8 = 1;
const HEADER_LEN: usize = MAGIC.len() + 1 + 1 + 2 + 4;

/// Reserved internal topic for structured bridge envelopes.
pub(crate) const BRIDGE_TOPIC: &str = "__elixirkit_bridge__";

/// Current bridge envelope protocol version.
pub(crate) const PROTOCOL_VERSION: u8 = 1;

/// Structured bridge envelope carried over the reserved bridge topic.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Envelope {
    /// A request envelope with an opaque request identifier and body bytes.
    Request(RequestEnvelope),
    /// A response envelope with an opaque request identifier and body bytes.
    Response(ResponseEnvelope),
    /// An event envelope with opaque body bytes.
    Event(EventEnvelope),
}

/// Request envelope.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RequestEnvelope {
    /// Protocol version.
    pub(crate) version: u8,
    /// Opaque request identifier bytes.
    pub(crate) request_id: Vec<u8>,
    /// Opaque body bytes.
    pub(crate) body: Vec<u8>,
}

/// Response envelope.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ResponseEnvelope {
    /// Protocol version.
    pub(crate) version: u8,
    /// Opaque request identifier bytes.
    pub(crate) request_id: Vec<u8>,
    /// Opaque body bytes.
    pub(crate) body: Vec<u8>,
}

/// Event envelope.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct EventEnvelope {
    /// Protocol version.
    pub(crate) version: u8,
    /// Opaque body bytes.
    pub(crate) body: Vec<u8>,
}

/// Internal bridge call body with an operation name and opaque payload.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CallBody<'body> {
    /// Operation name for the broker to dispatch.
    pub(crate) operation: &'body str,
    /// Opaque payload bytes carried with the operation.
    pub(crate) payload: &'body [u8],
}

/// Internal bridge call result body.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CallResult<'body> {
    /// Successful response payload.
    Ok(&'body [u8]),
    /// Error payload returned by the broker.
    Error(&'body [u8]),
}

impl Envelope {
    #[must_use]
    pub(crate) fn request(request_id: &[u8], body: &[u8]) -> Self {
        Self::Request(RequestEnvelope::new(request_id, body))
    }

    #[must_use]
    pub(crate) fn response(request_id: &[u8], body: &[u8]) -> Self {
        Self::Response(ResponseEnvelope::new(request_id, body))
    }

    #[must_use]
    pub(crate) fn event(body: &[u8]) -> Self {
        Self::Event(EventEnvelope::new(body))
    }
}

impl RequestEnvelope {
    #[must_use]
    pub(crate) fn new(request_id: &[u8], body: &[u8]) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.to_vec(),
            body: body.to_vec(),
        }
    }
}

impl ResponseEnvelope {
    #[must_use]
    pub(crate) fn new(request_id: &[u8], body: &[u8]) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.to_vec(),
            body: body.to_vec(),
        }
    }
}

impl EventEnvelope {
    #[must_use]
    pub(crate) fn new(body: &[u8]) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            body: body.to_vec(),
        }
    }
}

pub(crate) fn encode(envelope: &Envelope) -> io::Result<Vec<u8>> {
    match envelope {
        Envelope::Request(request) => encode_with_request_id(
            request.version,
            KIND_REQUEST,
            &request.request_id,
            &request.body,
        ),
        Envelope::Response(response) => encode_with_request_id(
            response.version,
            KIND_RESPONSE,
            &response.request_id,
            &response.body,
        ),
        Envelope::Event(event) => encode_event(event.version, &event.body),
    }
}

pub(crate) fn decode(bytes: &[u8]) -> io::Result<Envelope> {
    let Some((magic, header)) = bytes.split_at_checked(MAGIC.len()) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge envelope is truncated",
        ));
    };

    if magic != MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge envelope has invalid magic",
        ));
    }

    let Some((&version, header)) = header.split_first() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge envelope is truncated",
        ));
    };

    if version != PROTOCOL_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported bridge envelope version {version}"),
        ));
    }

    let Some((&kind, header)) = header.split_first() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge envelope is truncated",
        ));
    };

    let Some((request_id_len_bytes, header)) = header.split_at_checked(2) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge envelope is truncated",
        ));
    };
    let request_id_len = usize::from(u16::from_be_bytes(
        request_id_len_bytes.try_into().map_err(|_error| {
            io::Error::new(io::ErrorKind::InvalidData, "bridge envelope is truncated")
        })?,
    ));

    let Some((body_len_bytes, payload)) = header.split_at_checked(4) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge envelope is truncated",
        ));
    };
    let body_len_u32 = u32::from_be_bytes(body_len_bytes.try_into().map_err(|_error| {
        io::Error::new(io::ErrorKind::InvalidData, "bridge envelope is truncated")
    })?);
    let body_len = usize::try_from(body_len_u32)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;

    if payload.len() != request_id_len + body_len {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge envelope length does not match header",
        ));
    }

    let Some((request_id, body)) = payload.split_at_checked(request_id_len) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge envelope length does not match header",
        ));
    };

    match kind {
        KIND_REQUEST => {
            validate_non_empty_request_id(request_id)?;
            Ok(Envelope::Request(RequestEnvelope {
                version,
                request_id: request_id.to_vec(),
                body: body.to_vec(),
            }))
        }
        KIND_RESPONSE => {
            validate_non_empty_request_id(request_id)?;
            Ok(Envelope::Response(ResponseEnvelope {
                version,
                request_id: request_id.to_vec(),
                body: body.to_vec(),
            }))
        }
        KIND_EVENT => {
            if !request_id.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "event envelopes must not include a request id",
                ));
            }

            Ok(Envelope::Event(EventEnvelope {
                version,
                body: body.to_vec(),
            }))
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unknown bridge envelope kind {kind}"),
        )),
    }
}

pub(crate) fn broadcast(pubsub: &PubSub, envelope: &Envelope) -> io::Result<()> {
    let bytes = encode(envelope)?;
    pubsub.broadcast(BRIDGE_TOPIC, &bytes)
}

pub(crate) fn subscribe<F>(pubsub: &PubSub, callback: F)
where
    F: Fn(io::Result<Envelope>) + Send + Sync + 'static,
{
    pubsub.subscribe(BRIDGE_TOPIC, move |message| {
        callback(decode(message));
    });
}

pub(crate) fn encode_call_body(operation: &str, payload: &[u8]) -> io::Result<Vec<u8>> {
    validate_non_empty_operation(operation)?;

    let operation_len = u8::try_from(operation.len())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    let capacity = 1_usize
        .checked_add(operation.len())
        .and_then(|len| len.checked_add(payload.len()))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "call body is too large"))?;

    let mut bytes = Vec::with_capacity(capacity);
    bytes.push(operation_len);
    bytes.extend_from_slice(operation.as_bytes());
    bytes.extend_from_slice(payload);
    Ok(bytes)
}

pub(crate) fn decode_call_body(bytes: &[u8]) -> io::Result<CallBody<'_>> {
    let Some((&operation_len, rest)) = bytes.split_first() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "missing operation",
        ));
    };

    if operation_len == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "missing operation",
        ));
    }

    let Some((operation, payload)) = rest.split_at_checked(usize::from(operation_len)) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "truncated operation",
        ));
    };
    let operation = str::from_utf8(operation).map_err(|_error| {
        io::Error::new(io::ErrorKind::InvalidData, "operation must be valid UTF-8")
    })?;

    Ok(CallBody { operation, payload })
}

pub(crate) fn encode_call_result(result: CallResult<'_>) -> io::Result<Vec<u8>> {
    let (status, payload) = match result {
        CallResult::Ok(payload) => (CALL_RESULT_OK, payload),
        CallResult::Error(payload) => (CALL_RESULT_ERROR, payload),
    };

    let capacity = 1_usize
        .checked_add(payload.len())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "call result is too large"))?;

    let mut bytes = Vec::with_capacity(capacity);
    bytes.push(status);
    bytes.extend_from_slice(payload);
    Ok(bytes)
}

pub(crate) fn decode_call_result(bytes: &[u8]) -> io::Result<CallResult<'_>> {
    let Some((&status, payload)) = bytes.split_first() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "missing result status",
        ));
    };

    match status {
        CALL_RESULT_OK => Ok(CallResult::Ok(payload)),
        CALL_RESULT_ERROR => Ok(CallResult::Error(payload)),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid result status",
        )),
    }
}

fn encode_with_request_id(
    version: u8,
    kind: u8,
    request_id: &[u8],
    body: &[u8],
) -> io::Result<Vec<u8>> {
    validate_version(version)?;
    validate_non_empty_request_id(request_id)?;

    let request_id_len = u16::try_from(request_id.len())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    let body_len = u32::try_from(body.len())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;

    let capacity = HEADER_LEN
        .checked_add(request_id.len())
        .and_then(|len| len.checked_add(body.len()))
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "bridge envelope is too large")
        })?;

    let mut bytes = Vec::with_capacity(capacity);
    bytes.extend_from_slice(&MAGIC);
    bytes.push(version);
    bytes.push(kind);
    bytes.extend_from_slice(&request_id_len.to_be_bytes());
    bytes.extend_from_slice(&body_len.to_be_bytes());
    bytes.extend_from_slice(request_id);
    bytes.extend_from_slice(body);
    Ok(bytes)
}

fn encode_event(version: u8, body: &[u8]) -> io::Result<Vec<u8>> {
    validate_version(version)?;

    let body_len = u32::try_from(body.len())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    let capacity = HEADER_LEN.checked_add(body.len()).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "bridge envelope is too large")
    })?;

    let mut bytes = Vec::with_capacity(capacity);
    bytes.extend_from_slice(&MAGIC);
    bytes.push(version);
    bytes.push(KIND_EVENT);
    bytes.extend_from_slice(&0_u16.to_be_bytes());
    bytes.extend_from_slice(&body_len.to_be_bytes());
    bytes.extend_from_slice(body);
    Ok(bytes)
}

fn validate_version(version: u8) -> io::Result<()> {
    if version == PROTOCOL_VERSION {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("unsupported bridge envelope version {version}"),
        ))
    }
}

fn validate_non_empty_request_id(request_id: &[u8]) -> io::Result<()> {
    if request_id.is_empty() {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "request envelopes must include a request id",
        ))
    } else {
        Ok(())
    }
}

fn validate_non_empty_operation(operation: &str) -> io::Result<()> {
    if operation.is_empty() {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "missing operation",
        ))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        CallResult, Envelope, EventEnvelope, RequestEnvelope, ResponseEnvelope, decode,
        decode_call_body, decode_call_result, encode, encode_call_body, encode_call_result,
    };

    #[test]
    fn request_round_trip() {
        let envelope = Envelope::Request(RequestEnvelope::new(b"req-1", b"ping"));

        let encoded = encode(&envelope).expect("request envelope should encode");
        let decoded = decode(&encoded).expect("request envelope should decode");

        assert_eq!(decoded, envelope);
    }

    #[test]
    fn response_round_trip() {
        let envelope = Envelope::Response(ResponseEnvelope::new(b"req-1", b"pong"));

        let encoded = encode(&envelope).expect("response envelope should encode");
        let decoded = decode(&encoded).expect("response envelope should decode");

        assert_eq!(decoded, envelope);
    }

    #[test]
    fn event_round_trip() {
        let envelope = Envelope::Event(EventEnvelope::new(b"ready"));

        let encoded = encode(&envelope).expect("event envelope should encode");
        let decoded = decode(&encoded).expect("event envelope should decode");

        assert_eq!(decoded, envelope);
    }

    #[test]
    fn call_body_round_trip() {
        let encoded = encode_call_body("bridge.echo", b"ping").expect("call body should encode");
        let decoded = decode_call_body(&encoded).expect("call body should decode");

        assert_eq!(decoded.operation, "bridge.echo");
        assert_eq!(decoded.payload, b"ping");
    }

    #[test]
    fn call_result_ok_round_trip() {
        let encoded =
            encode_call_result(CallResult::Ok(b"pong")).expect("call result should encode");
        let decoded = decode_call_result(&encoded).expect("call result should decode");

        assert_eq!(decoded, CallResult::Ok(b"pong"));
    }

    #[test]
    fn call_result_error_round_trip() {
        let encoded = encode_call_result(CallResult::Error(b"unsupported operation"))
            .expect("call result should encode");
        let decoded = decode_call_result(&encoded).expect("call result should decode");

        assert_eq!(decoded, CallResult::Error(b"unsupported operation"));
    }
}
