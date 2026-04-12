//! Helpers for launching Elixir tooling and exchanging messages with a local
//! Elixir process.
//!
//! [`PubSub`] provides a lightweight framed TCP transport for message exchange
//! through a stable public compatibility layer. Structured bridge envelopes now
//! layer over one reserved internal topic on top of that same transport, while
//! the command helpers build correctly configured [`Command`] values for common
//! Elixir entry points.

use std::path::Path;
use std::process::Command;

pub(crate) mod protocol;
mod pubsub;
mod runtime;

pub use pubsub::PubSub;

/// Returns a command for running `elixir`.
#[must_use]
pub fn elixir(args: &[&str]) -> Command {
    let mut cmd = Command::new(if cfg!(target_os = "windows") {
        "elixir.bat"
    } else {
        "elixir"
    });
    cmd.args(args);
    cmd
}

/// Returns a command for running a Mix task.
#[must_use]
pub fn mix(task: &str, args: &[&str]) -> Command {
    let mut cmd = Command::new(if cfg!(target_os = "windows") {
        "mix.bat"
    } else {
        "mix"
    });
    cmd.arg(task);
    cmd.args(args);
    cmd
}

/// Returns a command for launching an Elixir release from `dir`.
#[must_use]
pub fn release(dir: impl AsRef<Path>, name: &str) -> Command {
    let dir = dir.as_ref();
    let mut script = dir.join("bin").join(name);
    if cfg!(target_os = "windows") {
        script.set_extension("bat");
    }
    let mut cmd = Command::new(&script);
    cmd.args(["start"]);
    cmd
}
