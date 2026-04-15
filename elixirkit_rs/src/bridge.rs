//! Ergonomic host-side bridge setup for Tauri applications.
//!
//! [`crate::PubSub`] remains the low-level transport API. This module adds a
//! thin builder on top for the common host setup chores in a Tauri app:
//! listening, topic hook registration, explicit capability registration, and
//! launching the Elixir side with the bridge URL wired in.

use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use tauri::{Manager, async_runtime};

use crate::PubSub;

type CapabilityRegistrar =
    Arc<dyn Fn(&PubSub, &tauri::AppHandle) -> io::Result<()> + Send + Sync + 'static>;
type TopicCallback = Arc<dyn Fn(BridgeContext, &[u8]) + Send + Sync + 'static>;
type LaunchPlanner =
    Arc<dyn Fn(&BridgeLaunchContext) -> io::Result<Command> + Send + Sync + 'static>;

const DEFAULT_LISTEN_URL: &str = "tcp://127.0.0.1:0";

/// High-level host bridge installed on top of [`PubSub`].
#[derive(Clone)]
pub struct Bridge {
    handle: BridgeHandle,
}

impl Bridge {
    /// Creates a new builder for Tauri host setup.
    #[must_use]
    pub fn builder() -> BridgeBuilder {
        BridgeBuilder::new()
    }

    /// Returns the managed bridge handle.
    #[must_use]
    pub const fn handle(&self) -> &BridgeHandle {
        &self.handle
    }

    /// Returns the underlying low-level [`PubSub`] transport.
    #[must_use]
    pub const fn pubsub(&self) -> &PubSub {
        self.handle.pubsub()
    }
}

/// Small host-facing bridge handle suitable for Tauri state.
#[derive(Clone)]
pub struct BridgeHandle {
    pubsub: PubSub,
}

impl BridgeHandle {
    const fn new(pubsub: PubSub) -> Self {
        Self { pubsub }
    }

    /// Returns the underlying low-level [`PubSub`] handle.
    #[must_use]
    pub const fn pubsub(&self) -> &PubSub {
        &self.pubsub
    }

    /// Returns the bridge listen URL.
    #[must_use]
    pub fn url(&self) -> String {
        self.pubsub.url()
    }

    /// Broadcasts a raw topic message through the underlying transport.
    ///
    /// # Errors
    ///
    /// Returns the same transport errors as [`PubSub::broadcast`].
    pub fn broadcast(&self, topic: &str, message: &[u8]) -> io::Result<()> {
        self.pubsub.broadcast(topic, message)
    }
}

/// Context passed to bridge topic callbacks.
#[derive(Clone)]
pub struct BridgeContext {
    bridge: BridgeHandle,
    app_handle: tauri::AppHandle,
    topic: Arc<str>,
}

impl BridgeContext {
    const fn new(bridge: BridgeHandle, app_handle: tauri::AppHandle, topic: Arc<str>) -> Self {
        Self {
            bridge,
            app_handle,
            topic,
        }
    }

    /// Returns the bridge handle for this callback.
    #[must_use]
    pub const fn bridge(&self) -> &BridgeHandle {
        &self.bridge
    }

    /// Returns the low-level transport handle for this callback.
    #[must_use]
    pub const fn pubsub(&self) -> &PubSub {
        self.bridge.pubsub()
    }

    /// Returns the callback topic.
    #[must_use]
    pub fn topic(&self) -> &str {
        &self.topic
    }

    /// Returns the current Tauri app handle.
    #[must_use]
    pub const fn app_handle(&self) -> &tauri::AppHandle {
        &self.app_handle
    }

    /// Broadcasts a raw topic message through the bridge.
    ///
    /// # Errors
    ///
    /// Returns the same transport errors as [`PubSub::broadcast`].
    pub fn broadcast(&self, topic: &str, message: &[u8]) -> io::Result<()> {
        self.bridge.broadcast(topic, message)
    }
}

/// Launch-planning context for the Elixir side.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BridgeLaunchContext {
    resource_dir: Option<PathBuf>,
}

impl BridgeLaunchContext {
    fn from_app<R, M>(app: &M) -> Self
    where
        R: tauri::Runtime,
        M: Manager<R>,
    {
        Self {
            resource_dir: app.path().resource_dir().ok(),
        }
    }

    /// Returns the app resource directory when Tauri exposes one.
    ///
    /// # Errors
    ///
    /// Returns an error if the current app context does not expose a resource
    /// directory.
    pub fn resource_dir(&self) -> io::Result<&Path> {
        self.resource_dir.as_deref().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "Tauri resource directory is not available for this bridge launch",
            )
        })
    }
}

struct TopicRegistration {
    topic: String,
    callback: TopicCallback,
}

/// Builder for the high-level Tauri host bridge.
pub struct BridgeBuilder {
    listen_url: String,
    capabilities: Vec<CapabilityRegistrar>,
    topic_callbacks: Vec<TopicRegistration>,
    launcher: Option<LaunchPlanner>,
}

impl Default for BridgeBuilder {
    fn default() -> Self {
        Self {
            listen_url: String::from(DEFAULT_LISTEN_URL),
            capabilities: Vec::new(),
            topic_callbacks: Vec::new(),
            launcher: None,
        }
    }
}

impl BridgeBuilder {
    /// Creates a new bridge builder.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the listen URL for the underlying [`PubSub`] transport.
    #[must_use]
    pub fn listen_url(mut self, url: impl Into<String>) -> Self {
        self.listen_url = url.into();
        self
    }

    /// Registers one explicit capability installer for this bridge.
    ///
    /// Registration remains app-owned and explicit. The callback usually points
    /// at a capability crate's `register` function.
    #[must_use]
    pub fn capability<F>(mut self, register: F) -> Self
    where
        F: Fn(&PubSub, &tauri::AppHandle) -> io::Result<()> + Send + Sync + 'static,
    {
        self.capabilities.push(Arc::new(register));
        self
    }

    /// Registers a raw-topic callback on top of the underlying transport.
    #[must_use]
    pub fn on_topic<F>(mut self, topic: impl Into<String>, callback: F) -> Self
    where
        F: Fn(BridgeContext, &[u8]) + Send + Sync + 'static,
    {
        self.topic_callbacks.push(TopicRegistration {
            topic: topic.into(),
            callback: Arc::new(callback),
        });
        self
    }

    /// Configures how the Elixir side should be launched for this bridge.
    ///
    /// The planner only builds the [`Command`]. The bridge layer still injects
    /// `ELIXIRKIT_PUBSUB`, spawns the child process, and exits the Tauri app
    /// with the resulting status code.
    #[must_use]
    pub fn launch<F>(mut self, planner: F) -> Self
    where
        F: Fn(&BridgeLaunchContext) -> io::Result<Command> + Send + Sync + 'static,
    {
        self.launcher = Some(Arc::new(planner));
        self
    }

    /// Finalizes the bridge during Tauri setup.
    ///
    /// This creates the underlying [`PubSub`] transport, installs explicit
    /// capability callbacks, subscribes the requested topic hooks, stores a
    /// small [`BridgeHandle`] in Tauri state, and launches Elixir if a launch
    /// planner was configured.
    ///
    /// # Errors
    ///
    /// Returns an error if the transport cannot listen, if the bridge handle is
    /// already managed for the app, if a capability registration callback
    /// fails, or if the launch planner fails to build the Elixir command.
    pub fn attach(self, app: &mut tauri::App) -> io::Result<Bridge> {
        if app.try_state::<BridgeHandle>().is_some() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "an ElixirKit bridge handle is already managed for this app",
            ));
        }

        let pubsub = PubSub::listen(&self.listen_url)?;
        let launch_context = BridgeLaunchContext::from_app(app);
        let mut launch_command = self.plan_launch_command(&launch_context)?;

        if let Some(command) = &mut launch_command {
            apply_bridge_env(command, &pubsub.url());
        }

        let bridge = Bridge {
            handle: BridgeHandle::new(pubsub.clone()),
        };
        let app_handle = app.handle().clone();

        for register in self.capabilities {
            register(&pubsub, &app_handle)?;
        }

        for topic_registration in self.topic_callbacks {
            let bridge_handle = bridge.handle.clone();
            let callback = Arc::clone(&topic_registration.callback);
            let callback_topic = Arc::<str>::from(topic_registration.topic.clone());
            let callback_app_handle = app_handle.clone();

            pubsub.subscribe(&topic_registration.topic, move |message| {
                callback(
                    BridgeContext::new(
                        bridge_handle.clone(),
                        callback_app_handle.clone(),
                        Arc::clone(&callback_topic),
                    ),
                    message,
                );
            });
        }

        if !app.manage(bridge.handle.clone()) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "an ElixirKit bridge handle is already managed for this app",
            ));
        }

        if let Some(command) = launch_command {
            spawn_elixir_process(app_handle, command);
        }

        Ok(bridge)
    }

    fn plan_launch_command(&self, context: &BridgeLaunchContext) -> io::Result<Option<Command>> {
        self.launcher
            .as_ref()
            .map(|planner| planner(context))
            .transpose()
    }
}

fn spawn_elixir_process(app_handle: tauri::AppHandle, mut command: Command) {
    async_runtime::spawn_blocking(move || {
        let exit_code = command
            .status()
            .map_or(1, |status| status.code().unwrap_or(1));
        app_handle.exit(exit_code);
    });
}

fn apply_bridge_env(command: &mut Command, pubsub_url: &str) {
    command.env("ELIXIRKIT_PUBSUB", pubsub_url);
}

#[cfg(test)]
mod tests {
    use std::ffi::{OsStr, OsString};
    use std::io;
    use std::path::{Path, PathBuf};

    use super::{Bridge, BridgeBuilder, BridgeLaunchContext, DEFAULT_LISTEN_URL, apply_bridge_env};

    #[derive(Debug, PartialEq, Eq)]
    struct BuilderSnapshot {
        listen_url: String,
        capability_count: usize,
        topic_count: usize,
        has_launcher: bool,
    }

    impl BridgeBuilder {
        fn snapshot(&self) -> BuilderSnapshot {
            BuilderSnapshot {
                listen_url: self.listen_url.clone(),
                capability_count: self.capabilities.len(),
                topic_count: self.topic_callbacks.len(),
                has_launcher: self.launcher.is_some(),
            }
        }
    }

    impl BridgeLaunchContext {
        fn with_resource_dir(path: impl Into<PathBuf>) -> Self {
            Self {
                resource_dir: Some(path.into()),
            }
        }
    }

    #[test]
    fn builder_defaults_to_the_standard_pubsub_listener() {
        let builder = Bridge::builder();

        assert_eq!(
            builder.snapshot(),
            BuilderSnapshot {
                listen_url: String::from(DEFAULT_LISTEN_URL),
                capability_count: 0,
                topic_count: 0,
                has_launcher: false,
            },
        );
    }

    #[test]
    fn builder_tracks_explicit_capabilities_topics_and_launch_plans() {
        let builder = BridgeBuilder::new()
            .listen_url("tcp://127.0.0.1:4444")
            .capability(|_pubsub, _app_handle| Ok(()))
            .capability(|_pubsub, _app_handle| Ok(()))
            .on_topic("messages", |_context, _message| {})
            .on_topic("ready", |_context, _message| {})
            .launch(|_context| Ok(crate::mix("phx.server", &[])));

        assert_eq!(
            builder.snapshot(),
            BuilderSnapshot {
                listen_url: String::from("tcp://127.0.0.1:4444"),
                capability_count: 2,
                topic_count: 2,
                has_launcher: true,
            },
        );
    }

    #[test]
    fn launch_planner_sets_elixirkit_pubsub_without_manual_env_choreography() {
        let builder = Bridge::builder().launch(|context| {
            let mut command = crate::release(context.resource_dir()?.join("rel"), "example");
            command.env("PHX_SERVER", "true");
            Ok(command)
        });
        let context = BridgeLaunchContext::with_resource_dir("/tmp/example");
        let command = builder
            .plan_launch_command(&context)
            .expect("launch command should build")
            .expect("launch command should be present");

        let mut launch_command = command;
        apply_bridge_env(&mut launch_command, "tcp://127.0.0.1:5555");

        let mut expected_program = PathBuf::from("/tmp/example/rel/bin/example");
        if cfg!(windows) {
            expected_program.set_extension("bat");
        }

        assert_eq!(launch_command.get_program(), expected_program.as_os_str(),);
        assert_eq!(
            launch_command.get_envs().find_map(|(key, value)| {
                (key == OsStr::new("PHX_SERVER")).then(|| value.expect("PHX_SERVER should be set"))
            }),
            Some(OsStr::new("true")),
        );
        assert_eq!(
            launch_command.get_envs().find_map(|(key, value)| {
                (key == OsStr::new("ELIXIRKIT_PUBSUB"))
                    .then(|| value.expect("ELIXIRKIT_PUBSUB should be set"))
            }),
            Some(OsStr::new("tcp://127.0.0.1:5555")),
        );
    }

    #[test]
    fn launch_planner_can_shape_dev_commands_without_running_them() {
        let builder = Bridge::builder().launch(|_context| {
            let mut command = crate::mix("phx.server", &[]);
            command.current_dir("..");
            Ok(command)
        });
        let command = builder
            .plan_launch_command(&BridgeLaunchContext::default())
            .expect("launch command should build")
            .expect("launch command should be present");

        assert_eq!(
            command.get_program(),
            if cfg!(windows) {
                OsStr::new("mix.bat")
            } else {
                OsStr::new("mix")
            },
        );
        assert_eq!(
            command
                .get_args()
                .map(OsStr::to_os_string)
                .collect::<Vec<_>>(),
            vec![OsString::from("phx.server")],
        );
        assert_eq!(command.get_current_dir(), Some(Path::new("..")));
    }

    #[test]
    fn launch_context_reports_when_resource_dir_is_unavailable() {
        let error = BridgeLaunchContext::default()
            .resource_dir()
            .expect_err("resource dir should be unavailable");

        assert_eq!(error.kind(), io::ErrorKind::NotFound);
    }
}
