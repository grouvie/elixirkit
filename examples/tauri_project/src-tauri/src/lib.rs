use elixirkit::{
    ActionAvailability, CapabilityAction, CapabilityBacking, CapabilityHandler,
    CapabilityNamespace, CapabilityPermission,
};
use serde::{Deserialize, Serialize};
use tauri::Manager;
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_opener::OpenerExt;

#[derive(Debug, Deserialize)]
struct EmptyRequest {}

#[derive(Debug, Serialize)]
struct EmptyResponse {}

#[derive(Debug, Deserialize)]
struct OpenRequest {
    target: String,
}

#[derive(Debug, Deserialize)]
struct WriteTextRequest {
    text: String,
}

#[derive(Debug, Serialize)]
struct ReadTextResponse {
    text: String,
}

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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0").expect("failed to listen");

    tauri::Builder::default()
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_opener::init())
        .setup(move |app| {
            register_host_capabilities(&pubsub, app.handle());

            let app_handle = app.handle().clone();

            pubsub.subscribe("messages", move |msg| {
                if msg == b"ready" {
                    create_window(&app_handle);
                } else {
                    println!("[rust] {}", String::from_utf8_lossy(msg));
                }
            });

            let app_handle = app.handle().clone();

            tauri::async_runtime::spawn_blocking(move || {
                let rel_dir = app_handle.path().resource_dir().unwrap().join("rel");
                let mut command = elixir_command(&rel_dir);
                command.env("ELIXIRKIT_PUBSUB", pubsub.url());
                let status = command.status().expect("failed to start Elixir");

                app_handle.exit(status.code().unwrap_or(1));
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn register_host_capabilities(pubsub: &elixirkit::PubSub, app_handle: &tauri::AppHandle) {
    register_opener(pubsub, app_handle);
    register_clipboard(pubsub, app_handle);
    register_window(pubsub, app_handle);
}

fn register_opener(pubsub: &elixirkit::PubSub, app_handle: &tauri::AppHandle) {
    let app_handle = app_handle.clone();
    pubsub
        .register_capability_handlers(
            CapabilityNamespace::new(
                "opener",
                CapabilityBacking::TauriPlugin,
                CapabilityPermission::NotApplicable,
                vec![CapabilityAction::new("open", ActionAvailability::Available)],
            ),
            vec![CapabilityHandler::json("open", move |request: OpenRequest| {
                app_handle
                    .opener()
                    .open_url(request.target, None::<String>)
                    .map_err(|error| error.to_string())?;

                Ok(EmptyResponse {})
            })],
        )
        .expect("failed to register opener capability");
}

fn register_clipboard(pubsub: &elixirkit::PubSub, app_handle: &tauri::AppHandle) {
    let app_handle_for_read = app_handle.clone();
    let app_handle_for_write = app_handle.clone();

    pubsub
        .register_capability_handlers(
            CapabilityNamespace::new(
                "clipboard",
                CapabilityBacking::TauriPlugin,
                CapabilityPermission::NotApplicable,
                vec![
                    CapabilityAction::new("read_text", ActionAvailability::Available),
                    CapabilityAction::new("write_text", ActionAvailability::Available),
                ],
            ),
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

                    Ok(EmptyResponse {})
                }),
            ],
        )
        .expect("failed to register clipboard capability");
}

fn register_window(pubsub: &elixirkit::PubSub, app_handle: &tauri::AppHandle) {
    let app_handle_for_list = app_handle.clone();
    let app_handle_for_set_title = app_handle.clone();

    pubsub
        .register_capability_handlers(
            CapabilityNamespace::new(
                "window",
                CapabilityBacking::TauriCore,
                CapabilityPermission::NotApplicable,
                vec![
                    CapabilityAction::new("list", ActionAvailability::Available),
                    CapabilityAction::new("set_title", ActionAvailability::Available),
                ],
            ),
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

                    Ok(EmptyResponse {})
                }),
            ],
        )
        .expect("failed to register window capability");
}

fn create_window(app_handle: &tauri::AppHandle) {
    let n = app_handle.webview_windows().len() + 1;
    let url = tauri::WebviewUrl::External("http://127.0.0.1:4000".parse().unwrap());
    tauri::WebviewWindowBuilder::new(app_handle, format!("window-{}", n), url)
        .title("Example")
        .inner_size(800.0, 600.0)
        .build()
        .unwrap();
}

fn elixir_command(rel_dir: &std::path::Path) -> std::process::Command {
    if cfg!(debug_assertions) {
        let mut command = elixirkit::mix("phx.server", &[]);
        command.current_dir("..");
        command
    } else {
        let mut command = elixirkit::release(rel_dir, "example");
        command.env("PHX_SERVER", "true");
        command.env("PHX_HOST", "127.0.0.1");
        command.env("PORT", "4000");
        command.env("SECRET_KEY_BASE", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        command
    }
}
