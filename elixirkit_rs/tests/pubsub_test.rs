//! Integration tests for the `PubSub` transport.

use serde as _;
use serde_json as _;

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn bidirectional_messaging() {
        let pubsub1 = elixirkit::PubSub::listen("tcp://127.0.0.1:0")
            .expect("listener should bind to an ephemeral local port");
        let pubsub2 = elixirkit::PubSub::connect(&pubsub1.url())
            .expect("client should connect to the listener");

        let (tx1, rx1) = mpsc::channel();
        let (tx2, rx2) = mpsc::channel();

        pubsub1.subscribe("topic", move |msg| {
            tx1.send(msg.to_vec())
                .expect("pubsub1 test receiver should stay alive");
        });
        pubsub2.subscribe("topic", move |msg| {
            tx2.send(msg.to_vec())
                .expect("pubsub2 test receiver should stay alive");
        });

        pubsub1
            .broadcast("topic", b"message1")
            .expect("pubsub1 should send to pubsub2");
        pubsub2
            .broadcast("topic", b"message2")
            .expect("pubsub2 should send to pubsub1");

        let message_for_pubsub2 = rx2
            .recv_timeout(Duration::from_secs(5))
            .expect("pubsub2 should receive pubsub1's message within five seconds");
        assert_eq!(
            message_for_pubsub2, b"message1",
            "pubsub2 should receive pubsub1's message",
        );

        let message_for_pubsub1 = rx1
            .recv_timeout(Duration::from_secs(5))
            .expect("pubsub1 should receive pubsub2's message within five seconds");
        assert_eq!(
            message_for_pubsub1, b"message2",
            "pubsub1 should receive pubsub2's message",
        );
    }
}
