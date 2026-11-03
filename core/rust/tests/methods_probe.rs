use flclash::{core::Core, probe};
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{Arc, OnceLock},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

fn home() -> &'static Path {
    static HOME: OnceLock<tempfile::TempDir> = OnceLock::new();
    HOME.get_or_init(|| tempfile::tempdir().unwrap()).path()
}

async fn invoke(core: &Core, method: &str, arguments: Value) -> Value {
    serde_json::from_slice(
        &core
            .invoke(
                &serde_json::to_vec(&json!({"id":"test","method":method,"arguments":arguments}))
                    .unwrap(),
                core.next_sequence(),
            )
            .await,
    )
    .unwrap()
}

async fn configured(document: Value) -> Arc<Core> {
    let core = Core::new();
    assert_eq!(
        invoke(&core, "initClash", json!({"home-dir":home(),"version":35})).await["result"],
        true
    );
    let path = home().join(format!("{}.yaml", uuid::Uuid::new_v4()));
    std::fs::write(&path, serde_saphyr::to_string(&document).unwrap()).unwrap();
    let result = invoke(
        &core,
        "setupConfig",
        json!({"base":{"path":path,"overlay":serde_saphyr::to_string(&document).unwrap()}}),
    )
    .await;
    assert_eq!(result["result"], "", "{result}");
    core
}

#[tokio::test]
async fn loaded_events_name_real_providers_not_plain_config_application() {
    fn loaded_events(core: &Core) -> Vec<Value> {
        let mut names = Vec::new();
        while let Some(batch) = core.events.batch() {
            let batch: Value = serde_json::from_slice(&batch).unwrap();
            names.extend(
                batch["arguments"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|event| event["type"] == "loaded")
                    .map(|event| event["data"].clone()),
            );
        }
        names
    }

    let core = configured(json!({"dns":{"enable":false},"rules":["MATCH,DIRECT"]})).await;
    core.events
        .enabled
        .store(true, std::sync::atomic::Ordering::Release);
    let result = invoke(&core, "updateConfig", json!({"mode":"direct"})).await;
    assert_eq!(result["result"], "", "{result}");
    assert!(loaded_events(&core).is_empty());

    let provider = home().join("loaded-events-provider.yaml");
    std::fs::write(
        &provider,
        "proxies:\n - {name: first, type: socks5, server: 127.0.0.1, port: 1080}\n",
    )
    .unwrap();
    let document = json!({"dns":{"enable":false},"proxy-providers":{"feed":{"type":"file","path":provider}},"proxy-groups":[{"name":"group","type":"select","use":["feed"]}],"rules":["MATCH,group"]});
    let profile = home().join("loaded-events-profile.yaml");
    let yaml = serde_saphyr::to_string(&document).unwrap();
    std::fs::write(&profile, &yaml).unwrap();
    let result = invoke(
        &core,
        "setupConfig",
        json!({"base":{"path":profile,"overlay":yaml}}),
    )
    .await;
    assert_eq!(result["result"], "", "{result}");
    assert_eq!(loaded_events(&core), vec![json!("feed")]);
    let result = invoke(
        &core,
        "sideLoadExternalProvider",
        json!({"providerName":"feed","data":"proxies:\n - {name: second, type: socks5, server: 127.0.0.1, port: 1081}\n"}),
    )
    .await;
    assert_eq!(result["result"], "", "{result}");
    assert_eq!(loaded_events(&core), vec![json!("feed")]);
    core.shutdown().await;
}

#[tokio::test]
async fn real_http_probe_follows_redirects_caps_body_and_preserves_route_hits() {
    let socket = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = socket.local_addr().unwrap();
    let server = tokio::spawn(async move {
        for _ in 0..2 {
            let (mut stream, _) = socket.accept().await.unwrap();
            let mut data = [0; 4096];
            let size = stream.read(&mut data).await.unwrap();
            let request = String::from_utf8_lossy(&data[..size]);
            if request.starts_with("GET /redirect ") {
                stream.write_all(b"HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
            } else {
                stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n0123456789").await.unwrap();
            }
        }
    });
    let core = configured(json!({"dns":{"enable":false},"rules":["MATCH,DIRECT"]})).await;
    let result=invoke(&core,"probe",json!({"url":format!("http://{address}/redirect"),"proxy-name":"DIRECT","timeout":3000,"max-body":4})).await;
    assert_eq!(result["result"]["status-code"], 200, "{result}");
    assert_eq!(result["result"]["body"], "0123");
    assert_eq!(result["result"]["chains"], json!(["DIRECT"]));
    assert_eq!(result["result"]["url"], format!("http://{address}/final"));
    let hits = &result["result"]["hits"];
    assert_eq!(hits[0]["host"], address.to_string());
    let check = invoke(&core, "checkRoutes", json!({"routes":[hits]})).await;
    assert_eq!(check["result"]["held"], json!([true]));
    server.await.unwrap();
    core.shutdown().await;
}

#[tokio::test]
async fn probe_timeout_is_a_real_timeout_result() {
    let socket = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = socket.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (_stream, _) = socket.accept().await.unwrap();
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    });
    let core = configured(json!({"dns":{"enable":false},"rules":["MATCH,DIRECT"]})).await;
    let result = probe::run(
        core.active().unwrap(),
        &json!({"url":format!("http://{address}/"),"proxy-name":"DIRECT","timeout":5}),
    )
    .await
    .unwrap_err();
    assert_eq!(probe::error_kind(&result), "timeout");
    server.abort();
    core.shutdown().await;
}

#[tokio::test]
async fn side_loaded_provider_rebuilds_groups_without_replacing_mobile_tunnel() {
    let path = home().join("method-provider.yaml");
    std::fs::write(
        &path,
        "proxies:\n - {name: first, type: socks5, server: 127.0.0.1, port: 1080}\n",
    )
    .unwrap();
    let core=configured(json!({"dns":{"enable":false},"proxy-providers":{"feed":{"type":"file","path":path}},"proxy-groups":[{"name":"group","type":"select","use":["feed"]}],"rules":["MATCH,group"]})).await;
    let prior = core.active().unwrap();
    assert!(
        prior.state.proxy_providers.contains_key("feed"),
        "missing initial provider: {}",
        core.document().await
    );
    let result = invoke(
        &core,
        "sideLoadExternalProvider",
        json!({"providerName":"feed","data":"proxies:\n - {name: second, type: socks5, server: 127.0.0.1, port: 1080}\n"}),
    )
    .await;
    assert_eq!(result["result"], "", "{result}");
    assert!(Arc::ptr_eq(&prior, &core.active().unwrap()));
    assert!(
        prior.state.proxy_providers.contains_key("feed"),
        "missing provider after reload; raw={:?}; saved={}",
        prior.state.raw_config.read().proxy_providers,
        core.document().await
    );
    let proxies = invoke(&core, "getProxies", Value::Null).await;
    assert!(
        proxies["result"]["proxies"].get("second").is_some(),
        "{proxies}"
    );
    assert_eq!(
        proxies["result"]["proxies"]["group"]["all"],
        json!(["second"])
    );
    let provider = invoke(&core, "getExternalProvider", json!("feed")).await;
    assert_eq!(provider["result"]["count"], 1);
    assert_eq!(provider["result"]["vehicle-type"], "File");
    core.shutdown().await;
}

#[tokio::test]
async fn occupied_listener_update_rolls_back_saved_config_and_runtime() {
    let core =
        configured(json!({"dns":{"enable":false},"mixed-port":0,"rules":["MATCH,DIRECT"]})).await;
    assert_eq!(
        invoke(&core, "startListener", Value::Null).await["result"],
        true
    );
    let path = home().join("config.yaml");
    let original = std::fs::read(&path).unwrap();
    let occupied = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let result = invoke(
        &core,
        "updateConfig",
        json!({"mixed-port":occupied.local_addr().unwrap().port()}),
    )
    .await;
    assert!(
        result["error"].is_object()
            || result["result"]
                .as_str()
                .is_some_and(|message| !message.is_empty()),
        "{result}"
    );
    assert_eq!(std::fs::read(path).unwrap(), original);
    assert!(core.active().unwrap().proxy("DIRECT").is_ok());
    assert_eq!(
        invoke(&core, "stopListener", Value::Null).await["result"],
        true
    );
    core.shutdown().await;
}

#[tokio::test]
async fn http_provider_side_load_uses_uploaded_payload_without_refetching_remote() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let socket = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = socket.local_addr().unwrap();
    let requests = Arc::new(AtomicUsize::new(0));
    let observed = Arc::clone(&requests);
    let server = tokio::spawn(async move {
        loop {
            let (mut stream, _) = socket.accept().await.unwrap();
            let mut buffer = [0; 4096];
            let _ = stream.read(&mut buffer).await.unwrap();
            observed.fetch_add(1, Ordering::SeqCst);
            let body = "proxies:\n - {name: remote, type: socks5, server: 127.0.0.1, port: 1080}\n";
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes()).await;
        }
    });
    let path = home().join("method-http-provider.yaml");
    let core=configured(json!({"dns":{"enable":false},"proxy-providers":{"http-feed":{"type":"http","url":format!("http://{address}/feed"),"path":path,"interval":0}},"proxy-groups":[{"name":"http-group","type":"select","use":["http-feed"]}],"rules":["MATCH,http-group"]})).await;
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let prior = core.active().unwrap();
    let before = requests.load(Ordering::SeqCst);
    let result=invoke(&core,"sideLoadExternalProvider",json!({"providerName":"http-feed","data":"proxies:\n - {name: uploaded, type: socks5, server: 127.0.0.1, port: 1081}\n"})).await;
    assert_eq!(result["result"], "", "{result}");
    let proxies = invoke(&core, "getProxies", Value::Null).await;
    assert_eq!(
        proxies["result"]["proxies"]["http-group"]["all"],
        json!(["uploaded"]),
        "{proxies}"
    );
    assert!(Arc::ptr_eq(&prior, &core.active().unwrap()));
    assert_eq!(requests.load(Ordering::SeqCst), before);
    core.shutdown().await;
    server.abort();
}

#[tokio::test]
async fn rule_provider_side_load_changes_real_route_and_rejects_invalid_replacement() {
    let path = home().join("method-rule-provider.yaml");
    std::fs::write(&path, "payload:\n - old.example\n").unwrap();
    let core=configured(json!({"dns":{"enable":false},"rule-providers":{"rules-feed":{"type":"file","path":path,"behavior":"domain","format":"yaml"}},"rules":["RULE-SET,rules-feed,REJECT","MATCH,DIRECT"]})).await;
    let engine = core.active().unwrap();
    let before = probe::exit(&engine, "new.example:443", "").await.unwrap();
    assert!(before.contains("DIRECT"));
    let result = invoke(
        &core,
        "sideLoadExternalProvider",
        json!({"providerName":"rules-feed","data":"payload:\n - new.example\n"}),
    )
    .await;
    assert_eq!(result["result"], "", "{result}");
    assert!(Arc::ptr_eq(&engine, &core.active().unwrap()));
    assert!(probe::exit(&engine, "new.example:443", "")
        .await
        .unwrap()
        .contains("REJECT"));
    let good = std::fs::read(&path).unwrap();
    let invalid = invoke(
        &core,
        "sideLoadExternalProvider",
        json!({"providerName":"rules-feed","data":"payload:\n - 10.0.0.0/8\n"}),
    )
    .await;
    assert!(invalid["error"].is_object(), "{invalid}");
    assert_eq!(std::fs::read(path).unwrap(), good);
    assert!(probe::exit(&engine, "new.example:443", "")
        .await
        .unwrap()
        .contains("REJECT"));
    core.shutdown().await;
}

#[tokio::test]
async fn provider_restart_failure_restores_prior_provider_for_disk_rollback() {
    let path = home().join("method-provider-rollback.yaml");
    let original = "proxies:\n - {name: previous, type: socks5, server: 127.0.0.1, port: 1080}\n";
    std::fs::write(&path, original).unwrap();
    let reservation = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = reservation.local_addr().unwrap().port();
    drop(reservation);
    let core = configured(json!({"mixed-port":port,"dns":{"enable":false},"proxy-providers":{"rollback-feed":{"type":"file","path":path}},"proxy-groups":[{"name":"rollback-group","type":"select","use":["rollback-feed"]}],"rules":["MATCH,rollback-group"]})).await;
    assert_eq!(
        invoke(&core, "startListener", Value::Null).await["result"],
        true
    );
    let engine = core.active().unwrap();
    let previous = engine
        .state
        .proxy_providers
        .get("rollback-feed")
        .unwrap()
        .value()
        .clone();
    engine.stop_listeners().await;
    let occupied = TcpListener::bind(("127.0.0.1", port)).await.unwrap();
    std::fs::write(
        &path,
        "proxies:\n - {name: replacement, type: socks5, server: 127.0.0.1, port: 1081}\n",
    )
    .unwrap();
    assert!(core.reload_provider("rollback-feed", false).await.is_err());
    assert!(Arc::ptr_eq(
        &previous,
        engine
            .state
            .proxy_providers
            .get("rollback-feed")
            .unwrap()
            .value()
    ));
    std::fs::write(&path, original).unwrap();
    drop(occupied);
    core.reload_current().await.unwrap();
    let proxies = invoke(&core, "getProxies", Value::Null).await;
    assert_eq!(
        proxies["result"]["proxies"]["rollback-group"]["all"],
        json!(["previous"]),
        "{proxies}"
    );
    assert_eq!(std::fs::read_to_string(path).unwrap(), original);
    assert!(Arc::ptr_eq(&engine, &core.active().unwrap()));
    core.shutdown().await;
}
