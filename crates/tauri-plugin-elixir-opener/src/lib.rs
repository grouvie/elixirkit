//! Explicit `opener` capability registration for `ElixirKit` + Tauri apps.
//!
//! This crate keeps the registration style small and explicit. The host app
//! still decides when to initialize the official Tauri opener plugin and when
//! to register the `ElixirKit` bridge handler.

use std::io;

use elixirkit::{
    ActionAvailability, CapabilityAction, CapabilityBacking, CapabilityHandler,
    CapabilityNamespace, CapabilityPermission, EmptyJsonObject, PubSub,
};
use serde::Deserialize;
use tauri_plugin_opener::OpenerExt;

#[derive(Debug, Deserialize)]
struct OpenRequest {
    target: String,
}

/// Registers the `opener` capability and its `opener.open` handler.
///
/// The application remains responsible for installing
/// `tauri_plugin_opener::init()` separately.
///
/// # Errors
///
/// Returns an error if the capability metadata or handler registration fails.
pub fn register(pubsub: &PubSub, app_handle: &tauri::AppHandle) -> io::Result<()> {
    let app_handle = app_handle.clone();

    pubsub.register_capability_handlers(
        namespace_descriptor(),
        vec![CapabilityHandler::json(
            "open",
            move |request: OpenRequest| {
                app_handle
                    .opener()
                    .open_url(request.target, None::<String>)
                    .map_err(|error| error.to_string())?;

                Ok(EmptyJsonObject)
            },
        )],
    )
}

fn namespace_descriptor() -> CapabilityNamespace {
    CapabilityNamespace::new(
        "opener",
        CapabilityBacking::TauriPlugin,
        CapabilityPermission::NotApplicable,
        vec![CapabilityAction::new("open", ActionAvailability::Available)],
    )
}

#[cfg(test)]
mod tests {
    use elixirkit::{
        ActionAvailability, CapabilityAction, CapabilityBacking, CapabilityNamespace,
        CapabilityPermission,
    };

    use super::namespace_descriptor;

    #[test]
    fn opener_descriptor_matches_the_bridge_contract() {
        assert_eq!(
            namespace_descriptor(),
            CapabilityNamespace::new(
                "opener",
                CapabilityBacking::TauriPlugin,
                CapabilityPermission::NotApplicable,
                vec![CapabilityAction::new("open", ActionAvailability::Available)],
            ),
        );
    }
}
