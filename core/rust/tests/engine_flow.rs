use flclash::engine::{listener_auth, Engine};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::broadcast,
};

fn home() -> &'static tempfile::TempDir {
    static HOME: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    HOME.get_or_init(|| tempfile::tempdir().unwrap())
}

async fn fetch(port: u16, target: u16, auth: bool) -> String {
    let mut connection = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let authorization = if auth {
        "Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n"
    } else {
        ""
    };
    connection.write_all(format!("GET http://127.0.0.1:{target}/sentinel HTTP/1.1\r\nHost: 127.0.0.1:{target}\r\n{authorization}Connection: close\r\n\r\n").as_bytes()).await.unwrap();
    let mut response = String::new();
    tokio::time::timeout(
        Duration::from_secs(5),
        connection.read_to_string(&mut response),
    )
    .await
    .unwrap()
    .unwrap();
    response
}

#[test]
fn local_authentication_has_no_implicit_loopback_exemption() {
    let raw =
        meow_config::parse_raw_yaml("authentication: [alice:secret]\nskip-auth-prefixes: []\n")
            .unwrap();
    let auth = listener_auth(&raw).unwrap();
    assert!(!auth.should_skip(&"127.0.0.1".parse().unwrap()));
    assert!(!auth.should_skip(&"::1".parse().unwrap()));
    assert!(auth.credentials.verify("alice", "secret"));
    assert!(!auth.credentials.verify("alice", "bad"));
}

#[tokio::test]
async fn mixed_proxy_forwards_authenticated_traffic_and_stops_cleanly() {
    let home = home();
    let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = origin.local_addr().unwrap().port();
    let origin = tokio::spawn(async move {
        let (mut connection, _) = origin.accept().await.unwrap();
        let mut request = vec![0; 4096];
        let size = connection.read(&mut request).await.unwrap();
        assert!(String::from_utf8_lossy(&request[..size]).contains("/sentinel"));
        connection
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nmeow-routed",
            )
            .await
            .unwrap();
    });
    let reserve = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = reserve.local_addr().unwrap().port();
    drop(reserve);
    let document = json!({"mixed-port":port,"allow-lan":false,"authentication":["alice:secret"],"skip-auth-prefixes":[],"rules":["MATCH,DIRECT"],"dns":{"enable":false},"tun":{"enable":false}});
    let (logs, _) = broadcast::channel(16);
    let engine = Engine::create(&document, home.path(), logs).await.unwrap();
    engine.start_listeners(&document).await.unwrap();
    let denied = fetch(port, target, false).await;
    assert!(denied.starts_with("HTTP/1.1 407"), "{denied}");
    let accepted = fetch(port, target, true).await;
    assert!(accepted.starts_with("HTTP/1.1 200"), "{accepted}");
    assert!(accepted.ends_with("meow-routed"));
    origin.await.unwrap();
    let (_, downloaded) = engine.state.tunnel.statistics().snapshot();
    assert!(downloaded > 0);
    engine.shutdown().await;
    let rebound = TcpListener::bind(("127.0.0.1", port)).await.unwrap();
    drop(rebound);
}

#[tokio::test]
async fn rejected_reload_keeps_the_previous_proxy_generation() {
    let home = home();
    let (logs, _) = broadcast::channel(16);
    let document = json!({"strict":true,"proxies":[{"name":"upstream","type":"socks5","server":"127.0.0.1","port":1080}],"rules":["MATCH,upstream"],"dns":{"enable":false}});
    let engine = Engine::create(&document, home.path(), logs).await.unwrap();
    let before = engine.proxy("upstream").unwrap();
    let invalid = json!({"strict":true,"proxies":[{"name":"bad","type":"unknown-protocol"}],"rules":["MATCH,bad"]});
    assert!(engine.reload(&invalid).await.is_err());
    assert!(Arc::ptr_eq(&before, &engine.proxy("upstream").unwrap()));
    assert!(engine.proxy("bad").is_err());
    let result: Value = engine.api("GET", "/proxies", Value::Null).await.unwrap();
    assert!(result["proxies"]["upstream"].is_object());
    engine.shutdown().await;
}

#[tokio::test]
async fn external_controller_requires_its_secret_and_releases_failed_startup() {
    let home = home();
    let reserved = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = reserved.local_addr().unwrap().port();
    drop(reserved);
    let controller = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = controller.local_addr().unwrap();
    let document = json!({"mixed-port":port,"external-controller":address.to_string(),"secret":"test-secret","dns":{"enable":false},"rules":["MATCH,DIRECT"]});
    let (logs, _) = broadcast::channel(16);
    let engine = Engine::create(&document, home.path(), logs).await.unwrap();
    assert!(engine.start_listeners(&document).await.is_err());
    let reclaimed = TcpListener::bind(("127.0.0.1", port)).await.unwrap();
    drop(reclaimed);
    drop(controller);
    engine.start_listeners(&document).await.unwrap();
    for (authorization, status) in [
        ("", "401"),
        ("Authorization: Bearer test-secret\r\n", "200"),
    ] {
        let mut client = TcpStream::connect(address).await.unwrap();
        client.write_all(format!("GET /proxies HTTP/1.1\r\nHost: {address}\r\n{authorization}Connection: close\r\n\r\n").as_bytes()).await.unwrap();
        let mut response = String::new();
        tokio::time::timeout(Duration::from_secs(5), client.read_to_string(&mut response))
            .await
            .unwrap()
            .unwrap();
        assert!(
            response.starts_with(&format!("HTTP/1.1 {status}")),
            "{response}"
        );
    }
    engine.shutdown().await;
}

#[tokio::test]
async fn stopping_mixed_listener_closes_pending_authentication() {
    let reservation = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = reservation.local_addr().unwrap().port();
    drop(reservation);
    let document = json!({"mixed-port":port,"authentication":["alice:secret"],"dns":{"enable":false},"rules":["MATCH,DIRECT"]});
    let (logs, _) = broadcast::channel(16);
    let engine = Engine::create(&document, home().path(), logs)
        .await
        .unwrap();
    engine.start_listeners(&document).await.unwrap();
    let mut client = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    client.write_all(&[5, 1, 2]).await.unwrap();
    let mut reply = [0; 2];
    tokio::time::timeout(Duration::from_secs(2), client.read_exact(&mut reply))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reply, [5, 2]);
    engine.stop_listeners().await;
    let mut replacement = document.clone();
    replacement["authentication"] = json!(["bob:new-secret"]);
    engine.start_listeners(&replacement).await.unwrap();
    let mut next = [0; 1];
    let read = tokio::time::timeout(Duration::from_secs(2), client.read(&mut next))
        .await
        .expect("stopped listener retained an authentication task");
    assert!(
        matches!(read, Ok(0) | Err(_)),
        "stale authentication replied after stop"
    );
    let mut fresh = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    fresh.write_all(&[5, 1, 2]).await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), fresh.read_exact(&mut reply))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reply, [5, 2]);
    fresh.write_all(b"\x01\x05alice\x06secret").await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), fresh.read_exact(&mut reply))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reply, [1, 1]);
    engine.shutdown().await;
}

#[tokio::test]
async fn shadowsocks_udp_traffic_stops_and_releases_its_port_before_restart() {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        relay::{udprelay::proxy_socket::UdpSocketType, Address},
        ProxySocket,
    };
    use tokio::net::UdpSocket;
    let reserved = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = reserved.local_addr().unwrap();
    drop(reserved);
    let origin = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let target = origin.local_addr().unwrap();
    let echo = tokio::spawn(async move {
        let mut bytes = [0; 128];
        loop {
            let (size, source) = origin.recv_from(&mut bytes).await.unwrap();
            origin.send_to(&bytes[..size], source).await.unwrap();
        }
    });
    let document = json!({"listeners":[{"name":"encrypted-in","type":"shadowsocks","listen":"127.0.0.1","port":address.port(),"cipher":"aes-256-gcm","password":"test-secret","udp":true}],"dns":{"enable":false},"rules":["MATCH,DIRECT"]});
    let (logs, _) = broadcast::channel(16);
    let engine = Engine::create(&document, home().path(), logs)
        .await
        .unwrap();
    for _ in 0..2 {
        engine.start_listeners(&document).await.unwrap();
        let config =
            ServerConfig::new(address, "test-secret", "aes-256-gcm".parse().unwrap()).unwrap();
        let raw = shadowsocks::net::UdpSocket::bind(&"127.0.0.1:0".parse().unwrap())
            .await
            .unwrap();
        let client = ProxySocket::from_socket(
            UdpSocketType::Client,
            Context::new_shared(ServerType::Local),
            &config,
            raw,
        );
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                client
                    .send_to(address, &Address::SocketAddress(target), b"encrypted-udp")
                    .await
                    .unwrap();
                let mut response = [0; 128];
                if let Ok(Ok((size, ..))) = tokio::time::timeout(
                    Duration::from_millis(200),
                    client.recv_from(&mut response),
                )
                .await
                {
                    assert_eq!(&response[..size], b"encrypted-udp");
                    break;
                }
            }
        })
        .await
        .unwrap();
        engine.stop_listeners().await;
        let udp = UdpSocket::bind(address)
            .await
            .expect("stopped encrypted listener retained its UDP port");
        let tcp = TcpListener::bind(address).await.unwrap();
        drop((udp, tcp));
    }
    engine.shutdown().await;
    echo.abort();
    let _ = echo.await;
}
