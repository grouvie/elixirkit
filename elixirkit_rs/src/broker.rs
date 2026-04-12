//! Internal request broker layered over the bridge protocol envelopes.
//!
//! This is the smallest broker/correlation seam for bridge-core work. It keeps
//! using the existing reserved topic and outer envelope, and currently handles
//! only built-in bridge-core operations such as `bridge.echo` and
//! `bridge.capabilities`. Dispatch is still core-owned at this stage; plugin
//! registration and non-core dispatch come later.
#![expect(
    clippy::redundant_pub_crate,
    reason = "Broker items stay crate-visible for the internal seam while the module remains internal to the crate"
)]

use crate::PubSub;
use crate::capabilities;
use crate::protocol::{self, CallBody, CallResult, Envelope};

const CAPABILITIES_OPERATION: &str = "bridge.capabilities";
const ECHO_OPERATION: &str = "bridge.echo";

pub(crate) fn attach(pubsub: &PubSub) {
    let pubsub = pubsub.clone();
    let response_pubsub = pubsub.clone();

    protocol::subscribe(&pubsub, move |envelope| {
        let Ok(Envelope::Request(request)) = envelope else {
            return;
        };

        let response_body = match protocol::decode_call_body(&request.body) {
            Ok(call) => match dispatch_call(call) {
                Ok(payload) => protocol::encode_call_result(CallResult::Ok(&payload)),
                Err(reason) => protocol::encode_call_result(CallResult::Error(reason.as_bytes())),
            },
            Err(reason) => {
                let reason = reason.to_string();
                protocol::encode_call_result(CallResult::Error(reason.as_bytes()))
            }
        };

        let Ok(response_body) = response_body else {
            return;
        };

        let response = Envelope::response(&request.request_id, &response_body);
        drop(protocol::broadcast(&response_pubsub, &response));
    });
}

fn dispatch_call(call: CallBody<'_>) -> Result<Vec<u8>, &'static str> {
    match call.operation {
        ECHO_OPERATION => Ok(call.payload.to_vec()),
        CAPABILITIES_OPERATION => protocol::encode_capabilities(&capabilities::built_in())
            .map_err(|_reason| "failed to encode capabilities"),
        _ => Err("unsupported operation"),
    }
}

#[cfg(test)]
mod tests {
    use crate::capabilities::{Availability, BackingKind, PermissionState};
    use crate::protocol;

    use super::{CAPABILITIES_OPERATION, CallBody, ECHO_OPERATION, dispatch_call};

    #[test]
    fn echo_operation_returns_the_same_payload() {
        let response = dispatch_call(CallBody {
            operation: ECHO_OPERATION,
            payload: b"pong",
        })
        .expect("echo operation should succeed");

        assert_eq!(response, b"pong", "echo should return the same payload");
    }

    #[test]
    fn unsupported_operation_returns_an_error() {
        let error = dispatch_call(CallBody {
            operation: "bridge.unknown",
            payload: b"pong",
        })
        .expect_err("unknown operations should be rejected");

        assert_eq!(error, "unsupported operation");
    }

    #[test]
    fn capabilities_operation_returns_built_in_registry() {
        let response = dispatch_call(CallBody {
            operation: CAPABILITIES_OPERATION,
            payload: b"",
        })
        .expect("capabilities operation should succeed");

        let capabilities =
            protocol::decode_capabilities(&response).expect("capabilities response should decode");

        assert_eq!(
            capabilities.len(),
            1,
            "only the built-in bridge namespace should exist"
        );
        let bridge = capabilities
            .first()
            .expect("expected exactly one built-in namespace");

        assert_eq!(bridge.namespace, "bridge");
        assert_eq!(bridge.backing, BackingKind::Core);
        assert_eq!(bridge.permission, PermissionState::NotApplicable);
        assert_eq!(
            bridge
                .actions
                .iter()
                .map(|action| (action.name.as_str(), action.availability))
                .collect::<Vec<_>>(),
            vec![
                ("echo", Availability::Available),
                ("capabilities", Availability::Available),
            ],
        );
    }
}
