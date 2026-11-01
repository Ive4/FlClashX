use flclash::{
    core::Core,
    ipc::{read_frame, serve, write_frame},
    protocol::MAX_FRAME,
};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn fragmented_frames_and_oversized_headers() {
    let (mut sender, mut receiver) = tokio::io::duplex(8);
    let write = tokio::spawn(async move {
        for byte in [7u8, 0, 0, 0, b'{', b'"', b'x', b'"', b':', b'1', b'}'] {
            sender.write_all(&[byte]).await.unwrap();
            tokio::task::yield_now().await;
        }
        sender.write_u32_le(MAX_FRAME as u32 + 1).await.unwrap();
    });
    assert_eq!(read_frame(&mut receiver).await.unwrap(), br#"{"x":1}"#);
    assert!(read_frame(&mut receiver)
        .await
        .unwrap_err()
        .to_string()
        .contains("exceeds"));
    write.await.unwrap();
}

#[tokio::test]
async fn rpc_responses_and_events_share_a_framed_transport() {
    let core = Core::new();
    let cancel = CancellationToken::new();
    let (mut host, child) = tokio::io::duplex(4096);
    let server = tokio::spawn(serve(Arc::clone(&core), child, cancel.clone()));
    write_frame(
        &mut host,
        br#"{"id":"init-state","method":"getIsInit","arguments":null}"#,
    )
    .await
    .unwrap();
    let response: Value = serde_json::from_slice(&read_frame(&mut host).await.unwrap()).unwrap();
    assert_eq!(response, json!({"id":"init-state", "result":false}));
    core.events.push("loaded", json!("provider-a"));
    core.events
        .push("geoUpdate", json!({"type":"mmdb", "updating":false}));
    let frame = tokio::time::timeout(Duration::from_secs(2), read_frame(&mut host))
        .await
        .unwrap()
        .unwrap();
    let event: Value = serde_json::from_slice(&frame).unwrap();
    assert_eq!(event["method"], "message");
    assert!(event["arguments"]
        .as_array()
        .unwrap()
        .iter()
        .any(|message| message["data"] == "provider-a"));
    write_frame(
        &mut host,
        br#"{"id":"unknown","method":"unknown","arguments":{}}"#,
    )
    .await
    .unwrap();
    loop {
        let response: Value =
            serde_json::from_slice(&read_frame(&mut host).await.unwrap()).unwrap();
        if response["id"] == "unknown" {
            assert_eq!(response["error"]["code"], "not_implemented");
            assert!(response["result"].is_null());
            break;
        }
    }
    cancel.cancel();
    tokio::time::timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let mut byte = [0u8; 1];
    assert_eq!(host.read(&mut byte).await.unwrap(), 0);
}
