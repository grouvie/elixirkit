//! Internal request broker layered over the bridge protocol envelopes.
//!
//! This is the smallest broker/correlation seam for bridge-core work. It keeps
//! using the existing reserved topic and outer envelope, and currently handles
//! only one built-in request operation: `bridge.echo`.
#![expect(
    clippy::redundant_pub_crate,
    reason = "Broker items stay crate-visible for the internal seam while the module remains internal to the crate"
)]

use crate::PubSub;
use crate::protocol::{self, CallBody, CallResult, Envelope};

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
        _ => Err("unsupported operation"),
    }
}

#[cfg(test)]
mod tests {
    use super::{CallBody, ECHO_OPERATION, dispatch_call};

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
}
