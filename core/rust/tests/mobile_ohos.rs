use flclash::{ipc, ohos};
use serde_json::{json, Value};
use std::{ffi::CString, time::Duration};
use tokio::{
    io::AsyncWriteExt,
    net::{TcpListener, TcpStream},
    time::timeout,
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn embedded_loopback_auth_lightweight_reconnect_and_owned_stop() {
    let directory = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unrelated = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let token = "0123456789abcdef".repeat(4);
    let settings = json!({"address":listener.local_addr().unwrap().to_string(), "token":token,
        "control":directory.path().join("control.json")})
    .to_string();
    let core = tokio::spawn(async move { ohos::run(&settings).await });
    let (mut initial, _) = timeout(Duration::from_secs(3), listener.accept())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        ipc::read_frame(&mut initial).await.unwrap(),
        token.as_bytes()
    );
    let request =
        CString::new(json!({"runningSince":123,"tunnelStatus":"running"}).to_string()).unwrap();
    timeout(Duration::from_secs(3), async {
        loop {
            let error = unsafe { ohos::FlClashEnterLightweight(request.as_ptr()) };
            if error.is_null() {
                break;
            }
            unsafe {
                ohos::FlClashFree(error);
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let path = directory.path().join(".ohos-core-host.json");
    let metadata: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(metadata["runningSince"], 123);
    assert_eq!(metadata["token"], token);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    let address = metadata["address"].as_str().unwrap();
    drop(initial);

    let mut wrong = TcpStream::connect(address).await.unwrap();
    ipc::write_frame(&mut wrong, "f".repeat(64).as_bytes())
        .await
        .unwrap();
    assert!(timeout(Duration::from_secs(3), ipc::read_frame(&mut wrong))
        .await
        .unwrap()
        .is_err());
    assert!(path.exists());

    let mut oversized = TcpStream::connect(address).await.unwrap();
    oversized.write_all(&65u32.to_le_bytes()).await.unwrap();
    assert!(
        timeout(Duration::from_secs(3), ipc::read_frame(&mut oversized))
            .await
            .unwrap()
            .is_err()
    );
    let mut adopted = TcpStream::connect(address).await.unwrap();
    ipc::write_frame(&mut adopted, token.as_bytes())
        .await
        .unwrap();
    assert_eq!(
        timeout(Duration::from_secs(3), ipc::read_frame(&mut adopted))
            .await
            .unwrap()
            .unwrap(),
        token.as_bytes()
    );
    ipc::write_frame(
        &mut adopted,
        br#"{"id":"adopted","method":"getIsInit","arguments":null}"#,
    )
    .await
    .unwrap();
    let response: Value = serde_json::from_slice(
        &timeout(Duration::from_secs(3), ipc::read_frame(&mut adopted))
            .await
            .unwrap()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(response["id"], "adopted");
    assert_eq!(response["result"], false);
    assert!(!path.exists());
    ohos::FlClashStopCore();
    timeout(Duration::from_secs(3), core)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    TcpStream::connect(unrelated.local_addr().unwrap())
        .await
        .unwrap();
    ohos::FlClashStopCore();
}
