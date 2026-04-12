//! Internal request broker layered over the bridge protocol envelopes.
//!
//! This is the smallest broker/correlation seam for bridge-core work. It keeps
//! using the existing reserved topic and outer envelope, and currently handles
//! built-in bridge-core operations plus explicitly registered host operation
//! handlers. Dispatch is still intentionally narrow and explicit at this
//! stage; this is not the later package split or omnibus plugin architecture.
#![expect(
    clippy::redundant_pub_crate,
    reason = "Broker items stay crate-visible for the internal seam while the module remains internal to the crate"
)]

use std::collections::BTreeMap;
use std::io;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::PubSub;
use crate::capabilities::{self, NamespaceDescriptor};
use crate::protocol::{self, CallBody, CallResult, Envelope};

const CAPABILITIES_OPERATION: &str = "bridge.capabilities";
const ECHO_OPERATION: &str = "bridge.echo";

type OperationResult = Result<Vec<u8>, String>;
type OperationHandler = Arc<dyn Fn(&[u8]) -> OperationResult + Send + Sync + 'static>;

#[derive(Clone, Default)]
pub(crate) struct State {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    capabilities: capabilities::Registry,
    handlers: Mutex<BTreeMap<String, OperationHandler>>,
}

impl State {
    pub(crate) fn new() -> Self {
        Self {
            inner: Arc::new(Inner {
                capabilities: capabilities::Registry::new(),
                handlers: Mutex::new(BTreeMap::new()),
            }),
        }
    }

    pub(crate) fn register_capability(&self, descriptor: NamespaceDescriptor) -> io::Result<()> {
        self.inner.capabilities.register(descriptor)
    }

    pub(crate) fn register_operation_handler<F>(
        &self,
        operation: &str,
        handler: F,
    ) -> io::Result<()>
    where
        F: Fn(&[u8]) -> OperationResult + Send + Sync + 'static,
    {
        validate_registered_operation(operation)?;

        if is_built_in_operation(operation) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("operation {operation:?} is already built in"),
            ));
        }

        let mut handlers = lock_recover(&self.inner.handlers);
        if handlers.contains_key(operation) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("operation {operation:?} is already registered"),
            ));
        }

        handlers.insert(operation.to_owned(), Arc::new(handler));
        drop(handlers);
        Ok(())
    }

    fn snapshot_capabilities(&self) -> Vec<NamespaceDescriptor> {
        self.inner.capabilities.snapshot()
    }

    fn operation_handler(&self, operation: &str) -> Option<OperationHandler> {
        lock_recover(&self.inner.handlers).get(operation).cloned()
    }
}

pub(crate) fn attach(pubsub: &PubSub) {
    let pubsub = pubsub.clone();
    let response_pubsub = pubsub.clone();
    let state = pubsub.broker_state();

    protocol::subscribe(&pubsub, move |envelope| {
        let Ok(Envelope::Request(request)) = envelope else {
            return;
        };

        let response_body = match protocol::decode_call_body(&request.body) {
            Ok(call) => match dispatch_call(call, &state) {
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

fn dispatch_call(call: CallBody<'_>, state: &State) -> OperationResult {
    match call.operation {
        ECHO_OPERATION => Ok(call.payload.to_vec()),
        CAPABILITIES_OPERATION => protocol::encode_capabilities(&state.snapshot_capabilities())
            .map_err(|_reason| String::from("failed to encode capabilities")),
        _ => state.operation_handler(call.operation).map_or_else(
            || Err(String::from("unsupported operation")),
            |handler| handler(call.payload),
        ),
    }
}

fn validate_registered_operation(operation: &str) -> io::Result<()> {
    protocol::encode_call_body(operation, b"")
        .map(|_body| ())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))
}

fn is_built_in_operation(operation: &str) -> bool {
    matches!(operation, ECHO_OPERATION | CAPABILITIES_OPERATION)
}

fn lock_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[cfg(test)]
mod tests {
    use crate::capabilities::{
        ActionDescriptor, Availability, BackingKind, NamespaceDescriptor, PermissionState,
    };
    use crate::protocol;

    use super::{CAPABILITIES_OPERATION, CallBody, ECHO_OPERATION, State, dispatch_call};

    #[test]
    fn echo_operation_returns_the_same_payload() {
        let state = State::default();
        let response = dispatch_call(
            CallBody {
                operation: ECHO_OPERATION,
                payload: b"pong",
            },
            &state,
        )
        .expect("echo operation should succeed");

        assert_eq!(response, b"pong", "echo should return the same payload");
    }

    #[test]
    fn unsupported_operation_returns_an_error() {
        let state = State::default();
        let error = dispatch_call(
            CallBody {
                operation: "bridge.unknown",
                payload: b"pong",
            },
            &state,
        )
        .expect_err("unknown operations should be rejected");

        assert_eq!(error, "unsupported operation");
    }

    #[test]
    fn capabilities_operation_returns_built_in_registry() {
        let state = State::default();
        let response = dispatch_call(
            CallBody {
                operation: CAPABILITIES_OPERATION,
                payload: b"",
            },
            &state,
        )
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

    #[test]
    fn capabilities_operation_aggregates_registered_host_capabilities() {
        let state = State::default();
        state
            .register_capability(NamespaceDescriptor::new(
                "opener",
                BackingKind::TauriPlugin,
                PermissionState::NotApplicable,
                vec![ActionDescriptor::new("open", Availability::Available)],
            ))
            .expect("host namespace should register");

        let response = dispatch_call(
            CallBody {
                operation: CAPABILITIES_OPERATION,
                payload: b"",
            },
            &state,
        )
        .expect("capabilities operation should succeed");

        let capabilities =
            protocol::decode_capabilities(&response).expect("capabilities response should decode");

        assert_eq!(
            capabilities
                .iter()
                .map(|descriptor| descriptor.namespace.as_str())
                .collect::<Vec<_>>(),
            vec!["bridge", "opener"],
        );
        let opener = capabilities
            .get(1)
            .expect("expected built-in bridge namespace plus registered opener");

        assert_eq!(opener.backing, BackingKind::TauriPlugin);
        assert_eq!(opener.permission, PermissionState::NotApplicable);
        assert_eq!(
            opener
                .actions
                .iter()
                .map(|action| (action.name.as_str(), action.availability))
                .collect::<Vec<_>>(),
            vec![("open", Availability::Available)],
        );
    }

    #[test]
    fn registered_handlers_dispatch_through_the_broker() {
        let state = State::default();
        state
            .register_operation_handler("opener.open", |payload| {
                if payload == b"https://example.com" {
                    Ok(Vec::new())
                } else {
                    Err(format!(
                        "unexpected opener target: {}",
                        String::from_utf8_lossy(payload)
                    ))
                }
            })
            .expect("host handler should register");

        let response = dispatch_call(
            CallBody {
                operation: "opener.open",
                payload: b"https://example.com",
            },
            &state,
        )
        .expect("registered host handler should dispatch");

        assert!(
            response.is_empty(),
            "registered opener handler should return an empty success body",
        );
    }
}
