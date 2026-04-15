use std::io;
use std::process::Command;

use elixirkit::{Bridge, BridgeContext, BridgeLaunchContext};
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            Bridge::builder()
                .listen_url("tcp://127.0.0.1:0")
                .capability(tauri_plugin_elixir_opener::register)
                .capability(tauri_plugin_elixir_clipboard::register)
                .capability(tauri_plugin_elixir_window::register)
                .on_topic("messages", handle_messages)
                .launch(example_elixir_command)
                .attach(app)
                .expect("failed to attach ElixirKit bridge");
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn handle_messages(context: BridgeContext, message: &[u8]) {
    if message == b"ready" {
        if let Err(error) = context.broadcast("messages", b"host:ready acknowledged") {
            eprintln!(
                "[rust] failed to broadcast {:?}: {error}",
                "host:ready acknowledged"
            );
        }
        create_window(context.app_handle());
        if let Err(error) = context.broadcast("messages", b"host:window created") {
            eprintln!(
                "[rust] failed to broadcast {:?}: {error}",
                "host:window created"
            );
        }
        return;
    }

    let message = String::from_utf8_lossy(message);
    println!("[rust] {message}");

    if message.starts_with("count:") {
        let observed = format!("host:observed {message}");
        if let Err(error) = context.broadcast("messages", observed.as_bytes()) {
            eprintln!("[rust] failed to broadcast {observed:?}: {error}");
        }
    }
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

fn example_elixir_command(context: &BridgeLaunchContext) -> io::Result<Command> {
    if cfg!(debug_assertions) {
        let mut command = elixirkit::mix("phx.server", &[]);
        command.current_dir("..");
        Ok(command)
    } else {
        let rel_dir = context.resource_dir()?.join("rel");
        let mut command = elixirkit::release(&rel_dir, "example");
        command.env("PHX_SERVER", "true");
        command.env("PHX_HOST", "127.0.0.1");
        command.env("PORT", "4000");
        command.env(
            "SECRET_KEY_BASE",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        );
        Ok(command)
    }
}
