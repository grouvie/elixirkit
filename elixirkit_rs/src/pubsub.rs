use std::io;

use crate::runtime::Runtime;

/// A handle to a `PubSub` connection.
///
/// `PubSub` remains the public compatibility-facing API. Its runtime and
/// transport internals live in a private module so future bridge-core work can
/// evolve without changing today's TCP framed `PubSub` behavior.
#[derive(Clone)]
pub struct PubSub {
    runtime: Runtime,
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
        Runtime::listen(url).map(Self::from_runtime)
    }

    // TODO: not documented, used just for testing for now.
    #[doc(hidden)]
    pub fn connect(url: &str) -> Result<Self, io::Error> {
        Runtime::connect(url).map(Self::from_runtime)
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

    // TODO: not documented, used just for testing for now.
    #[doc(hidden)]
    pub fn wait(&self) {
        self.runtime.wait();
    }

    const fn from_runtime(runtime: Runtime) -> Self {
        Self { runtime }
    }
}
