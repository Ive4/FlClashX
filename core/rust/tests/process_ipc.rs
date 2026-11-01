use flclash::ipc::{read_frame, write_frame};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    process::Command,
};

async fn request<S: AsyncRead + AsyncWrite + Unpin>(
    host: &mut S,
    id: &str,
    method: &str,
    arguments: Value,
) -> Value {
    write_frame(
        host,
        &serde_json::to_vec(&json!({"id":id,"method":method,"arguments":arguments})).unwrap(),
    )
    .await
    .unwrap();
    loop {
        let bytes = tokio::time::timeout(Duration::from_secs(10), read_frame(host))
            .await
            .unwrap()
            .unwrap();
        let response: Value = serde_json::from_slice(&bytes).unwrap();
        if response["id"] == id {
            return response;
        }
    }
}

#[tokio::test]
async fn core_process_preserves_config_and_spills_large_responses() {
    let directory = tempfile::tempdir().unwrap();
    let config = directory.path().join("config.yaml");
    std::fs::write(
        &config,
        "mode: direct\n# keep existing user configuration\n",
    )
    .unwrap();
    let original = std::fs::read(&config).unwrap();
    #[cfg(windows)]
    let address = format!(r"\\.\pipe\FlClashCore_{}", uuid::Uuid::new_v4().simple());
    #[cfg(windows)]
    let server = tokio::net::windows::named_pipe::ServerOptions::new()
        .first_pipe_instance(true)
        .create(&address)
        .unwrap();
    #[cfg(unix)]
    let address = directory
        .path()
        .join("Core.sock")
        .to_string_lossy()
        .into_owned();
    #[cfg(unix)]
    let server = tokio::net::UnixListener::bind(&address).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_FlClashCore"))
        .arg(&address)
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let pid = child.id().unwrap();
    eprintln!("test-owned Core pid={pid}");
    #[cfg(windows)]
    let mut host = {
        tokio::time::timeout(Duration::from_secs(10), server.connect())
            .await
            .unwrap()
            .unwrap();
        server
    };
    #[cfg(unix)]
    let mut host = tokio::time::timeout(Duration::from_secs(10), server.accept())
        .await
        .unwrap()
        .unwrap()
        .0;
    let init = request(
        &mut host,
        "init",
        "initClash",
        json!({"home-dir":directory.path(),"version":1}),
    )
    .await;
    assert_eq!(init["result"], true, "{init}");
    assert_eq!(std::fs::read(&config).unwrap(), original);
    let profile = directory.path().join("large.yaml");
    let entries = (0..50_000)
        .map(|index| format!("  - DOMAIN-SUFFIX,entry-{index}.example,DIRECT\n"))
        .collect::<String>();
    std::fs::write(&profile, format!("mode: rule\nrules:\n{entries}")).unwrap();
    let response = request(&mut host, "large", "getConfig", json!(profile)).await;
    let spilled = std::path::PathBuf::from(
        response["file"]
            .as_str()
            .expect("large response should spill"),
    );
    assert_eq!(
        spilled.parent().unwrap(),
        directory.path().join("responses")
    );
    assert!(response["result"].is_null());
    let response: Value = serde_json::from_slice(&std::fs::read(&spilled).unwrap()).unwrap();
    assert_eq!(response["id"], "large");
    assert_eq!(
        response["result"]["rules"].as_array().unwrap().len(),
        50_000
    );
    let stopped = request(&mut host, "shutdown", "shutdown", Value::Null).await;
    assert_eq!(stopped["result"], true);
    drop(host);
    let exit = tokio::time::timeout(Duration::from_secs(10), child.wait())
        .await
        .unwrap()
        .unwrap();
    assert!(exit.success(), "test-owned Core {pid} exited with {exit}");
}
