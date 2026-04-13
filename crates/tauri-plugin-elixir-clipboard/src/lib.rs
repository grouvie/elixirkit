//! Explicit `clipboard` capability registration for `ElixirKit` + Tauri apps.
//!
//! This crate owns the capability-specific request and response shapes while
//! leaving plugin initialization explicit in the host application.

use std::io;

use elixirkit::{
    ActionAvailability, CapabilityAction, CapabilityBacking, CapabilityHandler,
    CapabilityNamespace, CapabilityPermission, PubSub,
};
use serde::{Deserialize, Serialize};
use tauri_plugin_clipboard_manager::ClipboardExt;

#[derive(Debug, Deserialize)]
struct EmptyRequest;

#[derive(Debug, Serialize)]
struct EmptyResponse;

#[derive(Debug, Deserialize)]
struct WriteTextRequest {
    text: String,
}

#[derive(Debug, Serialize)]
struct ReadTextResponse {
    text: String,
}

/// Registers the `clipboard` capability plus its `read_text` and `write_text`
/// handlers.
///
/// The application remains responsible for installing
/// `tauri_plugin_clipboard_manager::init()` separately.
///
/// # Errors
///
/// Returns an error if the capability metadata or handler registration fails.
pub fn register(pubsub: &PubSub, app_handle: &tauri::AppHandle) -> io::Result<()> {
    let app_handle_for_read = app_handle.clone();
    let app_handle_for_write = app_handle.clone();

    pubsub.register_capability_handlers(
        namespace_descriptor(),
        vec![
            CapabilityHandler::json("read_text", move |_request: EmptyRequest| {
                let text = app_handle_for_read
                    .clipboard()
                    .read_text()
                    .map_err(|error| error.to_string())?;

                Ok(ReadTextResponse { text })
            }),
            CapabilityHandler::json("write_text", move |request: WriteTextRequest| {
                app_handle_for_write
                    .clipboard()
                    .write_text(&request.text)
                    .map_err(|error| error.to_string())?;

                Ok(EmptyResponse)
            }),
        ],
    )
}

fn namespace_descriptor() -> CapabilityNamespace {
    CapabilityNamespace::new(
        "clipboard",
        CapabilityBacking::TauriPlugin,
        CapabilityPermission::NotApplicable,
        vec![
            CapabilityAction::new("read_text", ActionAvailability::Available),
            CapabilityAction::new("write_text", ActionAvailability::Available),
        ],
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
    fn clipboard_descriptor_matches_the_bridge_contract() {
        assert_eq!(
            namespace_descriptor(),
            CapabilityNamespace::new(
                "clipboard",
                CapabilityBacking::TauriPlugin,
                CapabilityPermission::NotApplicable,
                vec![
                    CapabilityAction::new("read_text", ActionAvailability::Available),
                    CapabilityAction::new("write_text", ActionAvailability::Available),
                ],
            ),
        );
    }
}
