//! Internal built-in capability registry for the bridge core.
//!
//! This reports feature truth at the action level and keeps permission state as
//! a separate field. It is intentionally small and built-in for now; this is
//! not the later plugin registration model yet. The registry is still
//! bridge-core-owned and populated only from built-in descriptors; external
//! capability registration comes later.
#![expect(
    clippy::redundant_pub_crate,
    reason = "Capability registry items stay crate-visible while the module remains internal to the crate"
)]

/// How a capability namespace is currently backed on the host side.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BackingKind {
    /// Built into the bridge core itself.
    Core,
    /// Backed by an official or external Tauri plugin.
    TauriPlugin,
    /// Backed directly by Tauri core APIs.
    TauriCore,
}

/// Whether a specific action is supported on this host.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Availability {
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
pub(crate) enum PermissionState {
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
pub(crate) struct ActionDescriptor {
    /// Action name inside the namespace.
    pub(crate) name: String,
    /// Current support truth for the action.
    pub(crate) availability: Availability,
}

/// Namespace-level capability descriptor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct NamespaceDescriptor {
    /// Namespace name such as `bridge` or `clipboard`.
    pub(crate) namespace: String,
    /// Host backing for the namespace.
    pub(crate) backing: BackingKind,
    /// Separate permission or authorization state.
    pub(crate) permission: PermissionState,
    /// Action-level capability truth for the namespace.
    pub(crate) actions: Vec<ActionDescriptor>,
}

/// Returns the current built-in bridge-core capability registry.
#[must_use]
pub(crate) fn built_in() -> Vec<NamespaceDescriptor> {
    vec![NamespaceDescriptor {
        namespace: "bridge".to_owned(),
        backing: BackingKind::Core,
        permission: PermissionState::NotApplicable,
        actions: vec![
            ActionDescriptor {
                name: "echo".to_owned(),
                availability: Availability::Available,
            },
            ActionDescriptor {
                name: "capabilities".to_owned(),
                availability: Availability::Available,
            },
        ],
    }]
}

#[cfg(test)]
mod tests {
    use super::{Availability, BackingKind, PermissionState, built_in};

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
}
