use std::io;

use crate::broker;
use crate::runtime::Runtime;

/// A handle to a `PubSub` connection.
///
/// `PubSub` remains the public compatibility-facing API. Its runtime and
/// transport internals live in a private module so future bridge-core work can
/// evolve without changing today's TCP framed `PubSub` behavior.
#[derive(Clone)]
pub struct PubSub {
    runtime: Runtime,
    broker: broker::State,
}

impl PubSub {
    /// Listens on the given URL and returns a [`PubSub`] handle.
    ///
    /// The URL must be in the format `tcp://127.0.0.1:{port}`, where port
    /// can be `0` to let the OS assign an available port.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0")
    ///     .expect("failed to listen");
    /// ```
    ///
    /// # Errors
    ///
    /// Returns an error if `url` is invalid, the listener cannot bind to the
    /// requested port, the local address cannot be queried, or the background
    /// reader thread cannot be started.
    pub fn listen(url: &str) -> Result<Self, io::Error> {
        let pubsub = Runtime::listen(url).map(Self::from_runtime)?;
        broker::attach(&pubsub);
        Ok(pubsub)
    }

    // TODO: not documented, used just for testing for now.
    #[doc(hidden)]
    pub fn connect(url: &str) -> Result<Self, io::Error> {
        let pubsub = Runtime::connect(url).map(Self::from_runtime)?;
        broker::attach(&pubsub);
        Ok(pubsub)
    }

    /// Returns the URL for this `PubSub` connection.
    #[must_use]
    pub fn url(&self) -> String {
        self.runtime.url()
    }

    /// Subscribes to messages on the given topic from the Elixir side.
    ///
    /// The callback runs on the background reader thread whenever a matching
    /// message arrives.
    pub fn subscribe<F>(&self, topic: &str, callback: F)
    where
        F: Fn(&[u8]) + Send + Sync + 'static,
    {
        self.runtime.subscribe(topic, callback);
    }

    /// Broadcasts a message on the given topic to the Elixir side.
    ///
    /// # Errors
    ///
    /// Returns an error if the topic is longer than 255 bytes, the peer has not
    /// connected yet, the connection has already closed, or writing to the
    /// socket fails.
    pub fn broadcast(&self, topic: &str, message: &[u8]) -> io::Result<()> {
        self.runtime.broadcast(topic, message)
    }

    /// Registers host capability metadata that should be reported by
    /// `bridge.capabilities`.
    ///
    /// This is the small explicit registration seam for host integrations. It
    /// augments the built-in bridge-core registry; it does not replace it.
    ///
    /// # Errors
    ///
    /// Returns an error if the namespace descriptor is invalid, duplicates a
    /// built-in namespace, or has already been registered for this connection.
    pub fn register_capability(&self, descriptor: crate::CapabilityNamespace) -> io::Result<()> {
        self.broker.register_capability(descriptor)
    }

    /// Registers capability metadata together with the handlers that serve its
    /// available actions.
    ///
    /// This is the preferred stable registration contract for host
    /// integrations. It validates that declared available actions and concrete
    /// handlers stay in sync while preserving explicit per-capability
    /// registration in the host app.
    ///
    /// # Errors
    ///
    /// Returns an error if the namespace descriptor is invalid, if any handler
    /// does not match a declared available action, if an available action is
    /// missing a handler, or if the namespace has already been registered for
    /// this connection.
    pub fn register_capability_handlers(
        &self,
        descriptor: crate::CapabilityNamespace,
        handlers: Vec<crate::CapabilityHandler>,
    ) -> io::Result<()> {
        self.broker
            .register_capability_handlers(descriptor, handlers)
    }

    /// Registers a host operation handler that the internal broker may
    /// dispatch for later bridge calls such as `opener.open`.
    ///
    /// Built-in bridge-core operations such as `bridge.echo` and
    /// `bridge.capabilities` remain owned by the core broker and cannot be
    /// replaced through this seam. Prefer `register_capability_handlers` for a
    /// tighter metadata-plus-handler contract.
    ///
    /// # Errors
    ///
    /// Returns an error if `operation` is invalid, targets a built-in bridge
    /// operation, is already registered, or does not match a declared
    /// available capability action.
    pub fn register_operation_handler<F>(&self, operation: &str, handler: F) -> io::Result<()>
    where
        F: Fn(&[u8]) -> Result<Vec<u8>, String> + Send + Sync + 'static,
    {
        self.broker.register_operation_handler(operation, handler)
    }

    // TODO: not documented, used just for testing for now.
    #[doc(hidden)]
    pub fn wait(&self) {
        self.runtime.wait();
    }

    fn from_runtime(runtime: Runtime) -> Self {
        Self {
            runtime,
            broker: broker::State::new(),
        }
    }

    pub(crate) fn broker_state(&self) -> broker::State {
        self.broker.clone()
    }
}
