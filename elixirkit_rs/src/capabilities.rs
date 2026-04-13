//! Capability descriptors and the small internal capability registry.
//!
//! Capability truth is still reported at the action level and keeps permission
//! state separate from support truth. The registry now aggregates the
//! built-in bridge-core namespace with explicitly registered host namespaces.
//! Registration is still intentionally narrow and explicit at the app layer;
//! this is not the final productized plugin model or omnibus plugin rollout.
#![expect(
    clippy::redundant_pub_crate,
    reason = "Capability registry items stay crate-visible while the module remains internal to the crate"
)]

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::sync::{Arc, Mutex, MutexGuard};

use serde::Serialize;
use serde::de::DeserializeOwned;

type HandlerFn = dyn Fn(&[u8]) -> Result<Vec<u8>, String> + Send + Sync + 'static;

/// How a capability namespace is currently backed on the host side.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BackingKind {
    /// Built into the bridge core itself.
    Core,
    /// Backed by an official or external Tauri plugin.
    TauriPlugin,
    /// Backed directly by Tauri core APIs.
    TauriCore,
}

/// Whether a specific action is supported on this host.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Availability {
    /// The action is available now.
    Available,
    /// The action exists conceptually but is unavailable at runtime.
    Unavailable,
    /// The action is not supported by this backing.
    Unsupported,
    /// The action is unsupported on the current platform.
    UnsupportedPlatform,
}

/// Permission or authorization state for a namespace.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PermissionState {
    /// The namespace does not use a permission model.
    NotApplicable,
    /// Permission is granted.
    Granted,
    /// Permission is denied.
    Denied,
    /// Permission may still require prompting.
    Prompt,
}

/// Action-level capability descriptor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActionDescriptor {
    /// Action name inside the namespace.
    pub(crate) name: String,
    /// Current support truth for the action.
    pub(crate) availability: Availability,
}

impl ActionDescriptor {
    /// Creates an action-level capability descriptor.
    #[must_use]
    pub fn new(name: impl Into<String>, availability: Availability) -> Self {
        Self {
            name: name.into(),
            availability,
        }
    }
}

/// Host operation handler for one declared capability action.
#[derive(Clone)]
pub struct CapabilityHandler {
    pub(crate) action: String,
    pub(crate) handler: Arc<HandlerFn>,
}

impl CapabilityHandler {
    /// Creates a handler for an action that deals in raw bytes.
    #[must_use]
    pub fn bytes<F>(action: impl Into<String>, handler: F) -> Self
    where
        F: Fn(&[u8]) -> Result<Vec<u8>, String> + Send + Sync + 'static,
    {
        Self {
            action: action.into(),
            handler: Arc::new(handler),
        }
    }

    /// Creates a handler for an action that decodes JSON requests and encodes
    /// JSON success responses.
    #[must_use]
    pub fn json<Request, Response, F>(action: impl Into<String>, handler: F) -> Self
    where
        Request: DeserializeOwned + 'static,
        Response: Serialize + 'static,
        F: Fn(Request) -> Result<Response, String> + Send + Sync + 'static,
    {
        Self::bytes(action, move |payload| {
            let request = crate::decode_json_body(payload)
                .map_err(|error| format!("invalid JSON body: {error}"))?;
            let response = handler(request)?;
            crate::encode_json_body(&response)
                .map_err(|error| format!("failed to encode JSON body: {error}"))
        })
    }
}

/// Namespace-level capability descriptor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NamespaceDescriptor {
    /// Namespace name such as `bridge` or `clipboard`.
    pub(crate) namespace: String,
    /// Host backing for the namespace.
    pub(crate) backing: BackingKind,
    /// Separate permission or authorization state.
    pub(crate) permission: PermissionState,
    /// Action-level capability truth for the namespace.
    pub(crate) actions: Vec<ActionDescriptor>,
}

impl NamespaceDescriptor {
    /// Creates a namespace-level capability descriptor.
    #[must_use]
    pub fn new(
        namespace: impl Into<String>,
        backing: BackingKind,
        permission: PermissionState,
        actions: Vec<ActionDescriptor>,
    ) -> Self {
        Self {
            namespace: namespace.into(),
            backing,
            permission,
            actions,
        }
    }

    fn normalized(mut self) -> Self {
        self.actions
            .sort_by(|left, right| left.name.cmp(&right.name));
        self
    }
}

/// Small internal registry that combines bridge-core descriptors with explicit
/// host registrations.
#[derive(Clone, Default)]
pub(crate) struct Registry {
    inner: Arc<Mutex<BTreeMap<String, NamespaceDescriptor>>>,
}

impl Registry {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn register(&self, descriptor: NamespaceDescriptor) -> io::Result<()> {
        validate_namespace_descriptor(&descriptor)?;

        let descriptor = descriptor.normalized();
        let namespace = descriptor.namespace.clone();

        if is_built_in_namespace(&namespace) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("namespace {namespace:?} is already built in"),
            ));
        }

        let mut registered = lock_recover(&self.inner);
        if registered.contains_key(&namespace) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("namespace {namespace:?} is already registered"),
            ));
        }

        registered.insert(namespace, descriptor);
        drop(registered);
        Ok(())
    }

    pub(crate) fn declared_availability(
        &self,
        namespace: &str,
        action: &str,
    ) -> Option<Availability> {
        if let Some(availability) = built_in()
            .into_iter()
            .find(|descriptor| descriptor.namespace == namespace)
            .and_then(|descriptor| {
                descriptor
                    .actions
                    .into_iter()
                    .find(|descriptor| descriptor.name == action)
            })
            .map(|descriptor| descriptor.availability)
        {
            return Some(availability);
        }

        let registered = lock_recover(&self.inner);
        registered.get(namespace).and_then(|descriptor| {
            descriptor
                .actions
                .iter()
                .find(|descriptor| descriptor.name == action)
                .map(|descriptor| descriptor.availability)
        })
    }

    #[must_use]
    pub(crate) fn snapshot(&self) -> Vec<NamespaceDescriptor> {
        let mut namespaces = built_in();
        let registered = lock_recover(&self.inner);
        namespaces.extend(registered.values().cloned());
        namespaces
    }
}

/// Returns the current built-in bridge-core capability registry.
#[must_use]
pub(crate) fn built_in() -> Vec<NamespaceDescriptor> {
    vec![NamespaceDescriptor::new(
        "bridge",
        BackingKind::Core,
        PermissionState::NotApplicable,
        vec![
            ActionDescriptor::new("echo", Availability::Available),
            ActionDescriptor::new("capabilities", Availability::Available),
        ],
    )]
}

fn validate_namespace_descriptor(descriptor: &NamespaceDescriptor) -> io::Result<()> {
    validate_name("namespace", &descriptor.namespace)?;

    if descriptor.actions.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "namespace must expose at least one action",
        ));
    }

    let mut names = BTreeSet::new();
    for action in &descriptor.actions {
        validate_name("action", &action.name)?;

        if !names.insert(action.name.as_str()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "namespace {:?} contains duplicate action {:?}",
                    descriptor.namespace, action.name
                ),
            ));
        }
    }

    Ok(())
}

fn validate_name(kind: &str, name: &str) -> io::Result<()> {
    if name.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{kind} name must not be empty"),
        ));
    }

    if name.len() > usize::from(u8::MAX) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{kind} name must be at most 255 bytes"),
        ));
    }

    Ok(())
}

fn is_built_in_namespace(namespace: &str) -> bool {
    built_in()
        .into_iter()
        .any(|descriptor| descriptor.namespace == namespace)
}

pub(crate) fn is_built_in_namespace_name(namespace: &str) -> bool {
    is_built_in_namespace(namespace)
}

fn lock_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[cfg(test)]
mod tests {
    use std::io::ErrorKind;

    use super::{
        ActionDescriptor, Availability, BackingKind, NamespaceDescriptor, PermissionState,
    };
    use super::{Registry, built_in};

    #[test]
    fn built_in_registry_exposes_bridge_namespace() {
        let registry = built_in();

        assert_eq!(
            registry.len(),
            1,
            "only the built-in bridge namespace should exist"
        );
        let bridge = registry
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
    fn registry_snapshot_aggregates_registered_namespaces() {
        let registry = Registry::default();
        registry
            .register(NamespaceDescriptor::new(
                "opener",
                BackingKind::TauriPlugin,
                PermissionState::NotApplicable,
                vec![ActionDescriptor::new("open", Availability::Available)],
            ))
            .expect("host namespace should register");

        let snapshot = registry.snapshot();

        assert_eq!(
            snapshot
                .iter()
                .map(|descriptor| descriptor.namespace.as_str())
                .collect::<Vec<_>>(),
            vec!["bridge", "opener"],
        );
        let opener = snapshot
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
    fn registry_rejects_duplicate_action_names() {
        let registry = Registry::default();

        let error = registry
            .register(NamespaceDescriptor::new(
                "opener",
                BackingKind::TauriPlugin,
                PermissionState::NotApplicable,
                vec![
                    ActionDescriptor::new("open", Availability::Available),
                    ActionDescriptor::new("open", Availability::Unavailable),
                ],
            ))
            .expect_err("duplicate action names should be rejected");

        assert_eq!(error.kind(), ErrorKind::InvalidInput);
        assert!(
            error
                .to_string()
                .contains("contains duplicate action \"open\""),
            "unexpected error: {error}",
        );
    }
}
