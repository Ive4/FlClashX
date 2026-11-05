#![cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]

use flclash::engine::Engine;
use meow_common::{ConnType, Metadata, Network};
use serde_json::{json, Value};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::broadcast,
};

fn home() -> &'static tempfile::TempDir {
    static HOME: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    HOME.get_or_init(|| tempfile::tempdir().unwrap())
}

fn process_name() -> String {
    std::env::current_exe()
        .unwrap()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned()
}

fn document(mode: &str, policy: &str, rules: &[String]) -> Value {
    json!({
        "mode": mode,
        "find-process-mode": policy,
        "rules": rules,
        "dns": {"enable": false},
        "tun": {"enable": false},
    })
}

fn metadata(network: Network, source: SocketAddr) -> Metadata {
    Metadata {
        network,
        conn_type: ConnType::Tun,
        src_ip: Some(source.ip()),
        src_port: source.port(),
        dst_ip: Some("127.0.0.1".parse().unwrap()),
        dst_port: 80,
        ..Default::default()
    }
}

#[tokio::test]
async fn process_policy_controls_lookup_and_preserves_metadata_for_tcp_and_udp() {
    meow_common::disable_socket_table_cache();
    let tcp = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let udp = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let catch_all = "MATCH,DIRECT".to_owned();
    let process_rule = format!("PROCESS-NAME,{},REJECT", process_name());
    let initial = document("rule", "always", std::slice::from_ref(&catch_all));
    let (logs, _) = broadcast::channel(16);
    let engine = Engine::create(&initial, home().path(), logs).await.unwrap();
    for (network, source) in [
        (Network::Tcp, tcp.local_addr().unwrap()),
        (Network::Udp, udp.local_addr().unwrap()),
    ] {
        let cases = [
            ("rule", "off", vec![catch_all.clone()], false, "DIRECT"),
            ("rule", "strict", vec![catch_all.clone()], false, "DIRECT"),
            ("rule", "always", vec![catch_all.clone()], true, "DIRECT"),
            ("direct", "always", vec![catch_all.clone()], true, "DIRECT"),
            ("global", "always", vec![catch_all.clone()], true, "GLOBAL"),
            (
                "rule",
                "strict",
                vec![process_rule.clone(), catch_all.clone()],
                true,
                "REJECT",
            ),
            (
                "rule",
                "off",
                vec![process_rule.clone(), catch_all.clone()],
                false,
                "DIRECT",
            ),
            (
                "rule",
                "strict",
                vec![catch_all.clone(), process_rule.clone()],
                false,
                "DIRECT",
            ),
        ];
        for (mode, policy, rules, identified, target) in cases {
            engine
                .reload(&document(mode, policy, &rules))
                .await
                .unwrap();
            let mut flow = metadata(network, source);
            let route = engine
                .state
                .tunnel
                .inner()
                .resolve_proxy_lazy(&mut flow)
                .await
                .unwrap();
            assert_eq!(route.adapter.name(), target, "{network:?} {mode} {policy}");
            if identified {
                assert_eq!(flow.process.as_str(), process_name());
                assert!(!flow.process_path.is_empty());
            } else {
                assert!(flow.process.is_empty(), "{network:?} {mode} {policy}");
            }
        }
    }

    engine.reload(&initial).await.unwrap();
    let mut invalid = document("rule", "off", &["NOT-A-RULE,DIRECT".into()]);
    invalid["strict"] = json!(true);
    assert!(engine.reload(&invalid).await.is_err());
    let mut flow = metadata(Network::Tcp, tcp.local_addr().unwrap());
    engine
        .state
        .tunnel
        .inner()
        .resolve_proxy_lazy(&mut flow)
        .await
        .unwrap();
    assert_eq!(
        flow.process.as_str(),
        process_name(),
        "failed reload changed the lookup policy"
    );
    invalid["find-process-mode"] = json!("unknown");
    assert!(engine.reload(&invalid).await.is_err());

    engine
        .reload(&document(
            "rule",
            "off",
            &["PROCESS-NAME,supplied,REJECT".into(), catch_all],
        ))
        .await
        .unwrap();
    flow.process = "supplied".into();
    flow.process_path = "/supplied/application".into();
    let route = engine
        .state
        .tunnel
        .inner()
        .resolve_proxy_lazy(&mut flow)
        .await
        .unwrap();
    assert_eq!(route.adapter.name(), "REJECT");
    assert_eq!(flow.process_path.as_str(), "/supplied/application");
    engine.shutdown().await;
}

#[tokio::test]
async fn always_mode_reports_the_application_for_a_real_http_proxy_connection() {
    meow_common::disable_socket_table_cache();
    let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = origin.local_addr().unwrap().port();
    let reserve = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = reserve.local_addr().unwrap().port();
    drop(reserve);
    let mut config = document("rule", "always", &["MATCH,DIRECT".into()]);
    config["mixed-port"] = json!(port);
    config["allow-lan"] = json!(false);
    let (logs, _) = broadcast::channel(16);
    let engine = Engine::create(&config, home().path(), logs).await.unwrap();
    engine.start_listeners(&config).await.unwrap();
    let mut client = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let source_port = client.local_addr().unwrap().port();
    client
        .write_all(
            format!("CONNECT 127.0.0.1:{target} HTTP/1.1\r\nHost: 127.0.0.1:{target}\r\n\r\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    let mut response = [0; 1024];
    let size = tokio::time::timeout(Duration::from_secs(5), client.read(&mut response))
        .await
        .unwrap()
        .unwrap();
    assert!(String::from_utf8_lossy(&response[..size]).starts_with("HTTP/1.1 200"));
    let (remote, _) = tokio::time::timeout(Duration::from_secs(5), origin.accept())
        .await
        .unwrap()
        .unwrap();
    let snapshot = engine
        .api("GET", "/connections", Value::Null)
        .await
        .unwrap();
    let flow = snapshot["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|flow| flow["metadata"]["sourcePort"].as_u64() == Some(source_port.into()))
        .expect("real proxy connection was not tracked");
    assert_eq!(flow["metadata"]["process"], process_name());
    assert!(!flow["metadata"]["processPath"].as_str().unwrap().is_empty());
    assert_eq!(flow["chains"][0], "DIRECT");
    drop(client);
    drop(remote);
    engine.shutdown().await;
}
