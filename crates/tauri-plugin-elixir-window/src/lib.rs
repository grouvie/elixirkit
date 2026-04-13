//! Explicit `window` capability registration for `ElixirKit` + Tauri apps.
//!
//! This crate keeps the window capability on direct Tauri core APIs while
//! reusing the existing `ElixirKit` bridge registration seam.

use std::io;

use elixirkit::{
    ActionAvailability, CapabilityAction, CapabilityBacking, CapabilityHandler,
    CapabilityNamespace, CapabilityPermission, PubSub,
};
use serde::{Deserialize, Serialize};
use tauri::Manager;

#[derive(Debug, Deserialize)]
struct EmptyRequest;

#[derive(Debug, Serialize)]
struct EmptyResponse;

#[derive(Debug, Serialize)]
struct WindowInfo {
    label: String,
    title: String,
}

#[derive(Debug, Serialize)]
struct WindowListResponse {
    windows: Vec<WindowInfo>,
}

#[derive(Debug, Deserialize)]
struct SetTitleRequest {
    label: String,
    title: String,
}

/// Registers the `window` capability plus its `list` and `set_title`
/// handlers.
///
/// # Errors
///
/// Returns an error if the capability metadata or handler registration fails.
pub fn register(pubsub: &PubSub, app_handle: &tauri::AppHandle) -> io::Result<()> {
    let app_handle_for_list = app_handle.clone();
    let app_handle_for_set_title = app_handle.clone();

    pubsub.register_capability_handlers(
        namespace_descriptor(),
        vec![
            CapabilityHandler::json("list", move |_request: EmptyRequest| {
                let mut windows = app_handle_for_list
                    .webview_windows()
                    .into_iter()
                    .map(|(label, window)| {
                        let title = window.title().map_err(|error| error.to_string())?;
                        Ok(WindowInfo { label, title })
                    })
                    .collect::<Result<Vec<_>, String>>()?;

                windows.sort_by(|left, right| left.label.cmp(&right.label));

                Ok(WindowListResponse { windows })
            }),
            CapabilityHandler::json("set_title", move |request: SetTitleRequest| {
                let window = app_handle_for_set_title
                    .get_webview_window(&request.label)
                    .ok_or_else(|| format!("window {:?} was not found", request.label))?;

                window
                    .set_title(&request.title)
                    .map_err(|error| error.to_string())?;

                Ok(EmptyResponse)
            }),
        ],
    )
}

fn namespace_descriptor() -> CapabilityNamespace {
    CapabilityNamespace::new(
        "window",
        CapabilityBacking::TauriCore,
        CapabilityPermission::NotApplicable,
        vec![
            CapabilityAction::new("list", ActionAvailability::Available),
            CapabilityAction::new("set_title", ActionAvailability::Available),
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
    fn window_descriptor_matches_the_bridge_contract() {
        assert_eq!(
            namespace_descriptor(),
            CapabilityNamespace::new(
                "window",
                CapabilityBacking::TauriCore,
                CapabilityPermission::NotApplicable,
                vec![
                    CapabilityAction::new("list", ActionAvailability::Available),
                    CapabilityAction::new("set_title", ActionAvailability::Available),
                ],
            ),
        );
    }
}
