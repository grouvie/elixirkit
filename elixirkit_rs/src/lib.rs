//! Helpers for launching Elixir tooling and exchanging messages with a local
//! Elixir process.
//!
//! [`PubSub`] provides a lightweight framed TCP transport for message exchange
//! through a stable public compatibility layer. Structured bridge envelopes now
//! layer over one reserved internal topic on top of that same transport, and a
//! small internal broker now handles correlated request/response for bridge-core
//! operations. A small capability registry can now answer feature-truth
//! lookups over that same broker path and aggregate explicitly registered host
//! capabilities. Host operation handlers can also be registered through
//! [`PubSub`] while the transport and outer envelope stay the same. Capability
//! request and success-response bodies may now use a small JSON convention via
//! [`encode_json_body`] and [`decode_json_body`] without changing that outer
//! framing. The command helpers still build correctly configured [`Command`]
//! values for common Elixir entry points.

use std::path::Path;
use std::process::Command;

use serde::Serialize;
use serde::de::DeserializeOwned;

mod broker;
mod capabilities;
mod json;
pub(crate) mod protocol;
mod pubsub;
mod runtime;

pub use capabilities::{
    ActionDescriptor as CapabilityAction, Availability as ActionAvailability,
    BackingKind as CapabilityBacking, CapabilityHandler,
    NamespaceDescriptor as CapabilityNamespace, PermissionState as CapabilityPermission,
};
pub use json::EmptyJsonObject;
pub use pubsub::PubSub;

/// Returns a command for running `elixir`.
#[must_use]
pub fn elixir(args: &[&str]) -> Command {
    let mut cmd = Command::new(if cfg!(target_os = "windows") {
        "elixir.bat"
    } else {
        "elixir"
    });
    cmd.args(args);
    cmd
}

/// Returns a command for running a Mix task.
#[must_use]
pub fn mix(task: &str, args: &[&str]) -> Command {
    let mut cmd = Command::new(if cfg!(target_os = "windows") {
        "mix.bat"
    } else {
        "mix"
    });
    cmd.arg(task);
    cmd.args(args);
    cmd
}

/// Returns a command for launching an Elixir release from `dir`.
#[must_use]
pub fn release(dir: impl AsRef<Path>, name: &str) -> Command {
    let dir = dir.as_ref();
    let mut script = dir.join("bin").join(name);
    if cfg!(target_os = "windows") {
        script.set_extension("bat");
    }
    let mut cmd = Command::new(&script);
    cmd.args(["start"]);
    cmd
}

/// Encodes a capability request or success-response body as JSON bytes.
///
/// This helper applies only to inner capability payloads. The outer bridge
/// envelope and broker framing remain the same binary protocol.
///
/// # Errors
///
/// Returns an error if `value` cannot be serialized to JSON.
pub fn encode_json_body<T>(value: &T) -> Result<Vec<u8>, serde_json::Error>
where
    T: Serialize,
{
    serde_json::to_vec(value)
}

/// Decodes a capability request or success-response body from JSON bytes.
///
/// This helper applies only to inner capability payloads. The outer bridge
/// envelope and broker framing remain the same binary protocol.
///
/// # Errors
///
/// Returns an error if `bytes` are not valid JSON for `T`.
pub fn decode_json_body<T>(bytes: &[u8]) -> Result<T, serde_json::Error>
where
    T: DeserializeOwned,
{
    serde_json::from_slice(bytes)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::EmptyJsonObject;

    #[test]
    fn json_body_helpers_round_trip() {
        let mut payload = BTreeMap::new();
        payload.insert("label".to_owned(), "window-1".to_owned());
        payload.insert("title".to_owned(), "Example".to_owned());

        let encoded =
            crate::encode_json_body(&payload).expect("json payload should encode successfully");
        let decoded = crate::decode_json_body::<BTreeMap<String, String>>(&encoded)
            .expect("json payload should decode successfully");

        assert_eq!(decoded, payload);
    }

    #[test]
    fn empty_json_object_round_trips_as_an_empty_map() {
        let encoded =
            crate::encode_json_body(&EmptyJsonObject).expect("empty object should encode");
        let decoded = crate::decode_json_body::<EmptyJsonObject>(&encoded)
            .expect("empty object should decode");

        assert_eq!(encoded, b"{}");
        assert_eq!(decoded, EmptyJsonObject);
    }

    #[test]
    fn empty_json_object_rejects_non_empty_or_non_object_json() {
        assert!(
            crate::decode_json_body::<EmptyJsonObject>(br#"{"value":1}"#).is_err(),
            "non-empty objects should be rejected"
        );

        assert!(
            crate::decode_json_body::<EmptyJsonObject>(b"null").is_err(),
            "null should be rejected"
        );
    }
}
