use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;

type Callback = Arc<dyn Fn(&[u8]) + Send + Sync + 'static>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ConnectionState {
    WaitingForConnection,
    Connected,
    Closed,
}

struct Inner {
    port: u16,
    stream: Mutex<Option<TcpStream>>,
    subscribers: Mutex<HashMap<String, Vec<Callback>>>,
    connection_state: Mutex<ConnectionState>,
    connection_state_changed: Condvar,
}

/// A handle to a `PubSub` connection.
#[derive(Clone)]
pub struct PubSub {
    inner: Arc<Inner>,
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
        let port = parse_url(url)?;
        let listener = TcpListener::bind(("127.0.0.1", port))?;
        let actual_port = listener.local_addr()?.port();

        let pubsub = Self {
            inner: Arc::new(Inner {
                port: actual_port,
                stream: Mutex::new(None),
                subscribers: Mutex::new(HashMap::new()),
                connection_state: Mutex::new(ConnectionState::WaitingForConnection),
                connection_state_changed: Condvar::new(),
            }),
        };

        let inner = Arc::clone(&pubsub.inner);
        thread::Builder::new()
            .name("elixirkit-pubsub".into())
            .spawn(move || {
                let Ok((tcp_stream, _peer_address)) = listener.accept() else {
                    set_connection_state(&inner, ConnectionState::Closed);
                    return;
                };
                drop(tcp_stream.set_nodelay(true));

                let Ok(reader_stream) = tcp_stream.try_clone() else {
                    set_connection_state(&inner, ConnectionState::Closed);
                    return;
                };
                *lock_recover(&inner.stream) = Some(tcp_stream);
                set_connection_state(&inner, ConnectionState::Connected);

                read_loop(&inner, reader_stream);
                *lock_recover(&inner.stream) = None;
                set_connection_state(&inner, ConnectionState::Closed);
            })?;

        Ok(pubsub)
    }

    // TODO: not documented, used just for testing for now.
    #[doc(hidden)]
    pub fn connect(url: &str) -> Result<Self, io::Error> {
        let port = parse_url(url)?;
        let tcp_stream = TcpStream::connect(("127.0.0.1", port))?;
        tcp_stream.set_nodelay(true)?;

        let reader_stream = tcp_stream.try_clone()?;

        let pubsub = Self {
            inner: Arc::new(Inner {
                port,
                stream: Mutex::new(Some(tcp_stream)),
                subscribers: Mutex::new(HashMap::new()),
                connection_state: Mutex::new(ConnectionState::Connected),
                connection_state_changed: Condvar::new(),
            }),
        };

        let inner = Arc::clone(&pubsub.inner);
        thread::Builder::new()
            .name("elixirkit-pubsub".into())
            .spawn(move || {
                read_loop(&inner, reader_stream);
                *lock_recover(&inner.stream) = None;
                set_connection_state(&inner, ConnectionState::Closed);
            })?;

        Ok(pubsub)
    }

    /// Returns the URL for this `PubSub` connection.
    #[must_use]
    pub fn url(&self) -> String {
        let port = self.inner.port;
        format!("tcp://127.0.0.1:{port}")
    }

    /// Subscribes to messages on the given topic from the Elixir side.
    ///
    /// The callback runs on the background reader thread whenever a matching
    /// message arrives.
    pub fn subscribe<F>(&self, topic: &str, callback: F)
    where
        F: Fn(&[u8]) + Send + Sync + 'static,
    {
        lock_recover(&self.inner.subscribers)
            .entry(topic.to_owned())
            .or_default()
            .push(Arc::new(callback));
    }

    /// Broadcasts a message on the given topic to the Elixir side.
    ///
    /// # Errors
    ///
    /// Returns an error if the topic is longer than 255 bytes, the peer has not
    /// connected yet, the connection has already closed, or writing to the
    /// socket fails.
    pub fn broadcast(&self, topic: &str, message: &[u8]) -> io::Result<()> {
        if topic.len() > usize::from(u8::MAX) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "topic must be at most 255 bytes",
            ));
        }

        let mut state = lock_recover(&self.inner.connection_state);
        while *state == ConnectionState::WaitingForConnection {
            state = wait_recover(&self.inner.connection_state_changed, state);
        }
        drop(state);

        let guard = lock_recover(&self.inner.stream);
        guard.as_ref().map_or_else(
            || Err(io::Error::new(io::ErrorKind::NotConnected, "not connected")),
            |stream| write_message(stream, topic.as_bytes(), message),
        )
    }

    // TODO: not documented, used just for testing for now.
    #[doc(hidden)]
    pub fn wait(&self) {
        let mut state = lock_recover(&self.inner.connection_state);
        while *state != ConnectionState::Closed {
            state = wait_recover(&self.inner.connection_state_changed, state);
        }
        drop(state);
    }
}

fn read_loop(inner: &Inner, mut reader: TcpStream) {
    loop {
        let mut len_buf = [0_u8; 4];
        if reader.read_exact(&mut len_buf).is_err() {
            break;
        }
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        let mut frame = vec![0_u8; frame_len];
        if reader.read_exact(&mut frame).is_err() {
            break;
        }

        let Some((&topic_len, frame_body)) = frame.split_first() else {
            continue;
        };
        let Some((topic, payload)) = frame_body.split_at_checked(usize::from(topic_len)) else {
            continue;
        };

        let topic_str = String::from_utf8_lossy(topic);
        let callbacks = {
            let subscribers = lock_recover(&inner.subscribers);
            subscribers
                .get(topic_str.as_ref())
                .map_or_else(Vec::new, |callbacks| {
                    callbacks.iter().map(Arc::clone).collect()
                })
        };

        for callback in callbacks {
            callback(payload);
        }
    }
}

fn parse_url(url: &str) -> Result<u16, io::Error> {
    url.strip_prefix("tcp://127.0.0.1:")
        .and_then(|port| port.parse::<u16>().ok())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("expected tcp://127.0.0.1:{{port}}, got: {url:?}"),
            )
        })
}

fn set_connection_state(inner: &Inner, state: ConnectionState) {
    *lock_recover(&inner.connection_state) = state;
    inner.connection_state_changed.notify_all();
}

fn lock_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn wait_recover<'guard, T>(
    condvar: &Condvar,
    guard: MutexGuard<'guard, T>,
) -> MutexGuard<'guard, T> {
    match condvar.wait(guard) {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn write_message(mut stream: &TcpStream, topic: &[u8], payload: &[u8]) -> io::Result<()> {
    let topic_len = u8::try_from(topic.len())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    let inner_len = 1 + topic.len() + payload.len();
    let frame_len = u32::try_from(inner_len)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;

    stream.write_all(&frame_len.to_be_bytes())?;
    stream.write_all(&[topic_len])?;
    stream.write_all(topic)?;
    stream.write_all(payload)?;
    stream.flush()
}
