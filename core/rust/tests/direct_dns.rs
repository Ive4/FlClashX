use flclash::engine::Engine;
use hickory_proto::{
    op::{Message, MessageType, OpCode, ResponseCode},
    rr::{
        rdata::{A, AAAA},
        RData, Record, RecordType,
    },
    serialize::binary::{BinDecodable, BinEncodable},
};
use meow_common::{Metadata, Network, Proxy};
use serde_json::{json, Value};
use std::{
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, UdpSocket},
    sync::broadcast,
    task::{JoinHandle, JoinSet},
};

const WAIT: Duration = Duration::from_secs(5);

struct Server {
    address: SocketAddr,
    calls: Arc<AtomicUsize>,
    task: JoinHandle<()>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn answer(wire: &[u8], addresses: &[IpAddr]) -> Vec<u8> {
    let query = Message::from_bytes(wire).unwrap();
    let mut response = Message::new(query.metadata.id, MessageType::Response, OpCode::Query);
    response.metadata.recursion_available = true;
    if addresses.is_empty() {
        response.metadata.response_code = ResponseCode::NXDomain;
    }
    for question in query.queries {
        response.add_query(question.clone());
        for ip in addresses {
            let data = match (question.query_type, ip) {
                (RecordType::A, IpAddr::V4(ip)) => RData::A(A(*ip)),
                (RecordType::AAAA, IpAddr::V6(ip)) => RData::AAAA(AAAA(*ip)),
                _ => continue,
            };
            response.add_answer(Record::from_rdata(question.name.clone(), 30, data));
        }
    }
    response.to_bytes().unwrap()
}

async fn dns(addresses: &[&str]) -> Server {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let address = socket.local_addr().unwrap();
    let addresses: Vec<IpAddr> = addresses.iter().map(|ip| ip.parse().unwrap()).collect();
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    let task = tokio::spawn(async move {
        let mut wire = [0; 4096];
        while let Ok((size, peer)) = socket.recv_from(&mut wire).await {
            counted.fetch_add(1, Ordering::SeqCst);
            socket
                .send_to(&answer(&wire[..size], &addresses), peer)
                .await
                .unwrap();
        }
    });
    Server {
        address,
        calls,
        task,
    }
}

async fn origin(bind: &str) -> Server {
    let listener = TcpListener::bind(bind).await.unwrap();
    let address = listener.local_addr().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    let task = tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            counted.fetch_add(1, Ordering::SeqCst);
            let destination = socket.local_addr().unwrap().ip().to_string();
            let mut request = [0; 4096];
            socket.read(&mut request).await.unwrap();
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{destination}", destination.len()).as_bytes()).await.unwrap();
            socket.shutdown().await.unwrap();
        }
    });
    Server {
        address,
        calls,
        task,
    }
}

fn document(main: &Server, direct: &Server) -> Value {
    json!({
        "strict":true,"rules":["MATCH,DIRECT"],"tun":{"enable":false},
        "dns":{"enable":true,"enhanced-mode":"redir-host","use-system-hosts":false,
            "nameserver":[main.address.to_string()],"direct-nameserver":[direct.address.to_string()]},
    })
}

async fn engine(document: &Value) -> Arc<Engine> {
    static HOME: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    let home = HOME.get_or_init(|| tempfile::tempdir().unwrap());
    let (logs, _) = broadcast::channel(16);
    tokio::time::timeout(WAIT, Engine::create(document, home.path(), logs))
        .await
        .unwrap()
        .unwrap()
}

fn metadata(host: &str, address: SocketAddr) -> Metadata {
    Metadata {
        host: host.into(),
        dst_ip: Some(address.ip()),
        dst_port: address.port(),
        ..Default::default()
    }
}

async fn dial(proxy: Arc<dyn Proxy>, metadata: &Metadata) -> String {
    tokio::time::timeout(WAIT, async {
        let mut stream = proxy.dial_tcp(metadata).await.unwrap();
        stream
            .write_all(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).await.unwrap();
        response.split_once("\r\n\r\n").unwrap().1.to_owned()
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn direct_dns_changes_real_dial_destination_without_changing_main_or_proxy_dns() {
    let main = dns(&["127.0.0.1"]).await;
    let direct = dns(&["127.0.0.2"]).await;
    let proxy = dns(&["127.0.0.4"]).await;
    let target = origin("0.0.0.0:0").await;
    let mut config = document(&main, &direct);
    config["dns"]["proxy-server-nameserver"] = json!([proxy.address.to_string()]);
    let reserve = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = reserve.local_addr().unwrap().port();
    drop(reserve);
    config["mixed-port"] = json!(port);
    let engine = engine(&config).await;
    let host = "direct-separation.test";
    assert_eq!(
        engine
            .state
            .tunnel
            .resolver()
            .resolve_ip(host)
            .await
            .unwrap(),
        Some("127.0.0.1".parse().unwrap())
    );
    assert_eq!(
        meow_common::host_resolver()
            .unwrap()
            .resolve(host)
            .await
            .unwrap(),
        "127.0.0.4".parse::<IpAddr>().unwrap()
    );
    let previous = SocketAddr::new("127.0.0.1".parse().unwrap(), target.address.port());
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &metadata(host, previous)).await,
        "127.0.0.2"
    );
    assert_eq!(
        dial(
            engine.proxy("DIRECT").unwrap(),
            &metadata("127.0.0.1", previous)
        )
        .await,
        "127.0.0.1"
    );
    engine.start_listeners(&config).await.unwrap();
    let response = tokio::time::timeout(WAIT, async {
        let mut socket = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        socket
            .write_all(
                format!(
                    "GET http://{host}:{}/ HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n",
                    target.address.port()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut response = String::new();
        socket.read_to_string(&mut response).await.unwrap();
        response
    })
    .await
    .unwrap();
    assert!(response.ends_with("127.0.0.2"), "{response}");
    assert_eq!(main.calls.load(Ordering::SeqCst), 1);
    assert_eq!(direct.calls.load(Ordering::SeqCst), 1);
    assert_eq!(proxy.calls.load(Ordering::SeqCst), 1);
    let resolver = engine.state.tunnel.resolver();
    let records = resolver.dns_results(Some(host), 10);
    assert_eq!(records.len(), 2);
    assert!(records
        .iter()
        .any(|record| record.ips == ["127.0.0.1".parse::<IpAddr>().unwrap()]));
    assert!(records
        .iter()
        .any(|record| record.ips == ["127.0.0.2".parse::<IpAddr>().unwrap()]));
    assert_eq!(resolver.dns_results(Some("127.0.0.2"), 1).len(), 1);
    resolver.clear_cache();
    assert!(resolver.dns_results(None, 10).is_empty());
    engine.shutdown().await;
}

#[tokio::test]
async fn policy_is_opt_in_for_direct_and_direct_only_reload_replaces_its_cache() {
    let main = dns(&["127.0.0.1"]).await;
    let direct = dns(&["127.0.0.2"]).await;
    let policy = dns(&["127.0.0.3"]).await;
    let next_direct = dns(&["127.0.0.5"]).await;
    let target = origin("0.0.0.0:0").await;
    let mut config = document(&main, &direct);
    let host = "policy-target.test";
    config["dns"]["nameserver-policy"] = json!({host:policy.address.to_string()});
    let engine = engine(&config).await;
    let meta = metadata(
        host,
        SocketAddr::new("127.0.0.1".parse().unwrap(), target.address.port()),
    );
    assert_eq!(
        engine
            .state
            .tunnel
            .resolver()
            .resolve_ip(host)
            .await
            .unwrap(),
        Some("127.0.0.3".parse().unwrap())
    );
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.2"
    );
    config["dns"]["direct-nameserver-follow-policy"] = json!(true);
    engine.reload(&config).await.unwrap();
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.3"
    );
    config["dns"]["direct-nameserver-follow-policy"] = json!(false);
    config["dns"]["direct-nameserver"] = json!([next_direct.address.to_string()]);
    engine.reload(&config).await.unwrap();
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.5"
    );
    assert_eq!(
        engine
            .state
            .tunnel
            .resolver()
            .resolve_ip(host)
            .await
            .unwrap(),
        Some("127.0.0.3".parse().unwrap())
    );
    let previous = engine.state.tunnel.resolver();
    let mut rejected = config.clone();
    rejected["dns"]["direct-nameserver"] = json!(["tcp://127.0.0.1:5353#absent-proxy"]);
    assert!(engine.reload(&rejected).await.is_err());
    assert!(Arc::ptr_eq(&previous, &engine.state.tunnel.resolver()));
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.5"
    );
    config["dns"]["direct-nameserver"] = json!([]);
    config["dns"]["direct-nameserver-follow-policy"] = json!(true);
    engine.reload(&config).await.unwrap();
    let mut unresolved = meta.clone();
    unresolved.dst_ip = None;
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &unresolved).await,
        "127.0.0.3"
    );
    engine.shutdown().await;
}

#[tokio::test]
async fn authoritative_direct_negative_never_retries_general_or_fallback_dns() {
    let main = dns(&["127.0.0.1"]).await;
    let direct = dns(&[]).await;
    let fallback = dns(&["127.0.0.2"]).await;
    let mut config = document(&main, &direct);
    config["dns"]["fallback"] = json!([fallback.address.to_string()]);
    let engine = engine(&config).await;
    let host = "direct-nxdomain.test";
    assert!(engine
        .state
        .tunnel
        .resolver()
        .resolve_ip(host)
        .await
        .unwrap()
        .is_some());
    let before_main = main.calls.load(Ordering::SeqCst);
    let before_fallback = fallback.calls.load(Ordering::SeqCst);
    assert!(tokio::time::timeout(
        WAIT,
        engine
            .proxy("DIRECT")
            .unwrap()
            .dial_tcp(&metadata(host, "127.0.0.1:1".parse().unwrap()))
    )
    .await
    .unwrap()
    .is_err());
    assert_eq!(direct.calls.load(Ordering::SeqCst), 1);
    assert_eq!(main.calls.load(Ordering::SeqCst), before_main);
    assert_eq!(fallback.calls.load(Ordering::SeqCst), before_fallback);
    engine.shutdown().await;
}

#[tokio::test]
async fn udp_uses_direct_answer_and_preserves_the_original_reply_destination() {
    let main = dns(&["127.0.0.1"]).await;
    let direct = dns(&["127.0.0.2"]).await;
    let target = UdpSocket::bind("127.0.0.2:0").await.unwrap();
    let address = target.local_addr().unwrap();
    let config = document(&main, &direct);
    let engine = engine(&config).await;
    let original = SocketAddr::new("127.0.0.1".parse().unwrap(), address.port());
    let mut meta = metadata("direct-udp.test", original);
    meta.network = Network::Udp;
    let conn = tokio::time::timeout(WAIT, engine.proxy("DIRECT").unwrap().dial_udp(&meta))
        .await
        .unwrap()
        .unwrap();
    let echo = tokio::spawn(async move {
        let mut input = [0; 64];
        let (size, peer) = target.recv_from(&mut input).await.unwrap();
        assert_eq!(&input[..size], b"direct-udp");
        target.send_to(&input[..size], peer).await.unwrap();
    });
    conn.write_packet(b"direct-udp", &original).await.unwrap();
    let mut received = [0; 64];
    let (size, from) = tokio::time::timeout(WAIT, conn.read_packet(&mut received))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&received[..size], b"direct-udp");
    assert_eq!(from, original);
    echo.await.unwrap();
    assert_eq!(direct.calls.load(Ordering::SeqCst), 1);
    assert_eq!(main.calls.load(Ordering::SeqCst), 0);
    engine.shutdown().await;
}

#[tokio::test]
async fn direct_resolution_preserves_hosts_and_ipv6_family_rules_and_literal_bypass() {
    let main = dns(&["127.0.0.1"]).await;
    let direct = dns(&["::1"]).await;
    let target = origin("[::1]:0").await;
    let mut config = document(&main, &direct);
    config["ipv6"] = json!(true);
    config["hosts"] =
        json!({"static-target.test":["::1"],"alias-target.test":"static-target.test"});
    let engine = engine(&config).await;
    let mut meta = metadata("v6-target.test", target.address);
    assert_eq!(dial(engine.proxy("DIRECT").unwrap(), &meta).await, "::1");
    let before = direct.calls.load(Ordering::SeqCst);
    for host in ["::1", "[::1]", "static-target.test", "alias-target.test"] {
        meta.host = host.into();
        assert_eq!(dial(engine.proxy("DIRECT").unwrap(), &meta).await, "::1");
    }
    assert_eq!(direct.calls.load(Ordering::SeqCst), before);
    config["ipv6"] = json!(false);
    engine.reload(&config).await.unwrap();
    meta.host = "v6-disabled.test".into();
    assert!(engine
        .proxy("DIRECT")
        .unwrap()
        .dial_tcp(&meta)
        .await
        .is_err());
    engine.shutdown().await;
}

async fn dns_proxy(answer_ip: &str) -> Server {
    dns_proxy_for(answer_ip, None).await
}

async fn dns_proxy_for(answer_ip: &str, expected_domain: Option<&str>) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let answer_ip: IpAddr = answer_ip.parse().unwrap();
    let expected_domain = expected_domain.map(str::to_owned);
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    let task = tokio::spawn(async move {
        let mut clients = JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (mut socket, _) = accepted.unwrap();
                    let counted = Arc::clone(&counted);
                    let expected_domain = expected_domain.clone();
                    clients.spawn(async move {
                        let mut greeting = [0;2];
                        socket.read_exact(&mut greeting).await.unwrap();
                        assert_eq!(greeting[0], 5);
                        let mut methods = vec![0; greeting[1] as usize];
                        socket.read_exact(&mut methods).await.unwrap();
                        socket.write_all(&[5,0]).await.unwrap();
                        let mut request = [0;4];
                        socket.read_exact(&mut request).await.unwrap();
                        assert_eq!(&request[..3], &[5,1,0]);
                        let destination = match request[3] {
                            1 => {
                                let mut ip = [0;4];
                                socket.read_exact(&mut ip).await.unwrap();
                                std::net::Ipv4Addr::from(ip).to_string()
                            }
                            3 => {
                                let length = socket.read_u8().await.unwrap();
                                let mut domain = vec![0;length as usize];
                                socket.read_exact(&mut domain).await.unwrap();
                                String::from_utf8(domain).unwrap()
                            }
                            _ => panic!("unexpected SOCKS address family"),
                        };
                        assert_eq!(destination, expected_domain.as_deref().unwrap_or("203.0.113.53"));
                        assert_eq!(socket.read_u16().await.unwrap(), 5353);
                        socket.write_all(&[5,0,0,1,127,0,0,1,0,0]).await.unwrap();
                        while let Ok(size) = socket.read_u16().await {
                            let mut wire = vec![0;size as usize];
                            socket.read_exact(&mut wire).await.unwrap();
                            counted.fetch_add(1, Ordering::SeqCst);
                            let response = answer(&wire, &[answer_ip]);
                            socket.write_u16(response.len() as u16).await.unwrap();
                            socket.write_all(&response).await.unwrap();
                        }
                    });
                },
                Some(result) = clients.join_next(), if !clients.is_empty() => { result.unwrap(); },
            }
        }
    });
    Server {
        address,
        calls,
        task,
    }
}

#[tokio::test]
async fn unchanged_direct_dns_urls_follow_replaced_proxy_objects_and_failed_reload_rolls_back() {
    let main = dns(&["127.0.0.1"]).await;
    let unused_direct = dns(&["127.0.0.2"]).await;
    let old_proxy = dns_proxy("127.0.0.6").await;
    let new_proxy = dns_proxy("127.0.0.7").await;
    let target = origin("0.0.0.0:0").await;
    let mut config = document(&main, &unused_direct);
    config["proxies"] = json!([{"name":"dns-route","type":"socks5","server":"127.0.0.1","port":old_proxy.address.port()}]);
    config["dns"]["direct-nameserver"] = json!(["tcp://203.0.113.53:5353#dns-route"]);
    let engine = engine(&config).await;
    let mut meta = metadata(
        "proxy-generation.test",
        SocketAddr::new("127.0.0.1".parse().unwrap(), target.address.port()),
    );
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.6"
    );
    let old_generation = engine.state.tunnel.resolver();
    config["proxies"][0]["port"] = json!(new_proxy.address.port());
    engine.reload(&config).await.unwrap();
    assert!(!Arc::ptr_eq(
        &old_generation,
        &engine.state.tunnel.resolver()
    ));
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.7"
    );
    let new_generation = engine.state.tunnel.resolver();
    let mut invalid = config.clone();
    invalid["proxies"][0]["type"] = json!("unknown-protocol");
    assert!(engine.reload(&invalid).await.is_err());
    assert!(Arc::ptr_eq(
        &new_generation,
        &engine.state.tunnel.resolver()
    ));
    meta.host = "after-failed-reload.test".into();
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.7"
    );
    assert_eq!(old_proxy.calls.load(Ordering::SeqCst), 1);
    assert_eq!(new_proxy.calls.load(Ordering::SeqCst), 2);
    assert_eq!(unused_direct.calls.load(Ordering::SeqCst), 0);
    assert_eq!(main.calls.load(Ordering::SeqCst), 0);
    engine.shutdown().await;
}

async fn tcp_dns(addresses: &[&str]) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    tcp_dns_listener(listener, addresses)
}

fn tcp_dns_listener(listener: TcpListener, addresses: &[&str]) -> Server {
    let address = listener.local_addr().unwrap();
    let addresses: Vec<IpAddr> = addresses.iter().map(|ip| ip.parse().unwrap()).collect();
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    let task = tokio::spawn(async move {
        let mut clients = JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (mut socket, _) = accepted.unwrap();
                    let addresses = addresses.clone();
                    let counted = Arc::clone(&counted);
                    clients.spawn(async move {
                        while let Ok(size) = socket.read_u16().await {
                            let mut wire = vec![0; size as usize];
                            socket.read_exact(&mut wire).await.unwrap();
                            counted.fetch_add(1, Ordering::SeqCst);
                            let response = answer(&wire, &addresses);
                            socket.write_u16(response.len() as u16).await.unwrap();
                            socket.write_all(&response).await.unwrap();
                        }
                    });
                },
                Some(result) = clients.join_next(), if !clients.is_empty() => { result.unwrap(); },
            }
        }
    });
    Server {
        address,
        calls,
        task,
    }
}

#[tokio::test]
async fn direct_tagged_dns_upstream_uses_configured_bootstrap_even_after_reload_and_group_selection(
) {
    let main = dns(&["127.0.0.9"]).await;
    let bootstrap = dns(&["127.0.0.1"]).await;
    let negative_bootstrap = dns(&[]).await;
    let upstream = tcp_dns(&["127.0.0.2"]).await;
    let target = origin("0.0.0.0:0").await;
    let mut config = document(&main, &bootstrap);
    config["dns"]["default-nameserver"] = json!([bootstrap.address.to_string()]);
    config["dns"]["direct-nameserver"] = json!([format!(
        "tcp://localhost:{}#DIRECT",
        upstream.address.port()
    )]);
    let engine = engine(&config).await;
    let mut meta = metadata(
        "tagged-bootstrap.test",
        SocketAddr::new("127.0.0.9".parse().unwrap(), target.address.port()),
    );
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.2"
    );
    assert_eq!(bootstrap.calls.load(Ordering::SeqCst), 2);
    engine.reload(&config).await.unwrap();
    meta.host = "after-tagged-reload.test".into();
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.2"
    );
    config["proxy-groups"] = json!([{"name":"dns-route","type":"select","proxies":["DIRECT"]}]);
    config["dns"]["direct-nameserver"] = json!([format!(
        "tcp://localhost:{}#dns-route",
        upstream.address.port()
    )]);
    engine.reload(&config).await.unwrap();
    meta.host = "group-direct-bootstrap.test".into();
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.2"
    );
    config["dns"]["default-nameserver"] = json!([negative_bootstrap.address.to_string()]);
    engine.reload(&config).await.unwrap();
    meta.host = "no-system-fallback.test".into();
    assert!(
        tokio::time::timeout(WAIT, engine.proxy("DIRECT").unwrap().dial_tcp(&meta))
            .await
            .unwrap()
            .is_err()
    );
    assert!(negative_bootstrap.calls.load(Ordering::SeqCst) > 0);
    assert_eq!(main.calls.load(Ordering::SeqCst), 0);
    assert_eq!(upstream.calls.load(Ordering::SeqCst), 3);
    engine.shutdown().await;
}

#[tokio::test]
async fn remote_proxy_keeps_the_upstream_hostname_and_never_queries_local_bootstrap() {
    let main = dns(&["127.0.0.1"]).await;
    let bootstrap = dns(&[]).await;
    let proxy = dns_proxy_for("127.0.0.6", Some("remote-only-dns.test")).await;
    let target = origin("0.0.0.0:0").await;
    let mut config = document(&main, &bootstrap);
    config["dns"]["default-nameserver"] = json!([bootstrap.address.to_string()]);
    config["dns"]["direct-nameserver"] = json!(["tcp://remote-only-dns.test:5353#dns-route"]);
    config["proxies"] = json!([{"name":"dns-route","type":"socks5","server":"127.0.0.1","port":proxy.address.port()}]);
    let engine = engine(&config).await;
    let meta = metadata(
        "remote-lookup.test",
        SocketAddr::new("127.0.0.1".parse().unwrap(), target.address.port()),
    );
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.6"
    );
    assert_eq!(proxy.calls.load(Ordering::SeqCst), 1);
    assert_eq!(bootstrap.calls.load(Ordering::SeqCst), 0);
    assert_eq!(main.calls.load(Ordering::SeqCst), 0);
    engine.shutdown().await;
}

struct PreferredProxyDatagram;

#[async_trait::async_trait]
impl meow_dns::client::preferred_doh::PreferredDohTransport for PreferredProxyDatagram {
    async fn exchange(
        &self,
        request: meow_dns::client::preferred_doh::DohRequest<'_>,
    ) -> std::io::Result<Vec<u8>> {
        assert_eq!(request.server_name, "different-tls-name.test");
        let (host, port) = request.proxy_target.unwrap();
        assert_eq!(host, "upstream-bootstrap.test");
        let metadata = Metadata {
            host: host.into(),
            dst_port: port,
            network: Network::Udp,
            internal: true,
            ..Default::default()
        };
        let connection = request
            .proxy
            .unwrap()
            .dial_udp(&metadata)
            .await
            .map_err(std::io::Error::other)?;
        connection
            .write_packet(request.wire, &request.address)
            .await
            .map_err(std::io::Error::other)?;
        let mut wire = vec![0; 4096];
        let (size, _) = connection
            .read_packet(&mut wire)
            .await
            .map_err(std::io::Error::other)?;
        wire.truncate(size);
        Ok(wire)
    }
}

#[tokio::test]
async fn preferred_transport_direct_udp_bootstraps_the_dial_hostname_independently_of_sni() {
    let main = dns(&["127.0.0.9"]).await;
    let bootstrap = dns(&["127.0.0.1"]).await;
    let upstream = dns(&["127.0.0.2"]).await;
    let target = origin("0.0.0.0:0").await;
    let mut document = document(&main, &bootstrap);
    document["dns"]["default-nameserver"] = json!([bootstrap.address.to_string()]);
    document["dns"]["direct-nameserver"] = json!([format!(
        "https://upstream-bootstrap.test:{}/dns-query#different-tls-name.test?proxy=DIRECT",
        upstream.address.port()
    )]);
    let _preference =
        meow_dns::client::preferred_doh::install(Some(Arc::new(PreferredProxyDatagram)));
    let raw = meow_config::parse_raw_yaml(&serde_saphyr::to_string(&document).unwrap()).unwrap();
    let config = meow_config::build_config(raw, None).await.unwrap();
    let meta = metadata(
        "preferred-direct.test",
        SocketAddr::new("127.0.0.9".parse().unwrap(), target.address.port()),
    );
    assert_eq!(
        dial(Arc::clone(config.proxies.get("DIRECT").unwrap()), &meta).await,
        "127.0.0.2"
    );
    assert_eq!(upstream.calls.load(Ordering::SeqCst), 1);
    assert_eq!(bootstrap.calls.load(Ordering::SeqCst), 2);
    assert_eq!(main.calls.load(Ordering::SeqCst), 0);
}

struct PreferredProxyStream;

#[async_trait::async_trait]
impl meow_dns::client::preferred_doh::PreferredDohTransport for PreferredProxyStream {
    async fn exchange(
        &self,
        request: meow_dns::client::preferred_doh::DohRequest<'_>,
    ) -> std::io::Result<Vec<u8>> {
        assert_eq!(request.server_name, "203.0.113.53");
        assert!(request.proxy_target.is_none());
        let meta = metadata("203.0.113.53", request.address);
        let mut connection = request
            .proxy
            .unwrap()
            .dial_tcp(&meta)
            .await
            .map_err(std::io::Error::other)?;
        connection.write_u16(request.wire.len() as u16).await?;
        connection.write_all(request.wire).await?;
        let size = connection.read_u16().await?;
        let mut wire = vec![0; size as usize];
        connection.read_exact(&mut wire).await?;
        Ok(wire)
    }
}

async fn native_reload(engine: &Engine, document: &Value) -> anyhow::Result<Value> {
    use base64::Engine as _;
    let yaml = serde_saphyr::to_string(document).unwrap();
    engine
        .api(
            "PUT",
            "/configs",
            json!({"payload":base64::engine::general_purpose::STANDARD.encode(yaml)}),
        )
        .await
}

#[tokio::test]
async fn legacy_encrypted_fragment_retains_raw_config_and_tracks_replaced_proxy_generation() {
    let main = dns(&["127.0.0.1"]).await;
    let unused = dns(&["127.0.0.2"]).await;
    let old_proxy = dns_proxy("127.0.0.6").await;
    let new_proxy = dns_proxy("127.0.0.7").await;
    let target = origin("0.0.0.0:0").await;
    let mut config = document(&main, &unused);
    config["dns"]["direct-nameserver"] = json!([]);
    config["proxies"] = json!([{"name":"dns-route","type":"socks5","server":"127.0.0.1","port":old_proxy.address.port()}]);
    let engine = engine(&config).await;
    let _preference =
        meow_dns::client::preferred_doh::install(Some(Arc::new(PreferredProxyStream)));
    config["dns"]["direct-nameserver"] = json!(["https://203.0.113.53:5353/dns-query#dns-route"]);
    let original = config.clone();
    flclash::direct_dns::validate(&config).unwrap();
    native_reload(&engine, &config).await.unwrap();
    let mut meta = metadata(
        "legacy-proxy-generation.test",
        SocketAddr::new("127.0.0.1".parse().unwrap(), target.address.port()),
    );
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.6"
    );
    assert_eq!(config, original);
    assert_eq!(
        serde_json::to_value(engine.state.raw_config.read().dns.as_ref().unwrap()).unwrap()
            ["direct-nameserver"],
        config["dns"]["direct-nameserver"]
    );
    let before = engine.state.tunnel.resolver();
    config["proxies"][0]["port"] = json!(new_proxy.address.port());
    native_reload(&engine, &config).await.unwrap();
    assert!(!Arc::ptr_eq(&before, &engine.state.tunnel.resolver()));
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.7"
    );
    let before = engine.state.tunnel.resolver();
    config["proxies"][0]["type"] = json!("unknown-protocol");
    assert!(native_reload(&engine, &config).await.is_err());
    assert!(Arc::ptr_eq(&before, &engine.state.tunnel.resolver()));
    meta.host = "legacy-after-failed-reload.test".into();
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.7"
    );
    assert_eq!(old_proxy.calls.load(Ordering::SeqCst), 1);
    assert_eq!(new_proxy.calls.load(Ordering::SeqCst), 2);
    assert_eq!(main.calls.load(Ordering::SeqCst), 0);
    assert_eq!(unused.calls.load(Ordering::SeqCst), 0);
    engine.shutdown().await;
}

async fn paired_loopback_sockets() -> (TcpListener, UdpSocket) {
    for _ in 0..128 {
        let port = 10000 + rand::random::<u16>() % 50000;
        let Ok(tcp) = TcpListener::bind(("127.0.0.1", port)).await else {
            continue;
        };
        if let Ok(udp) = UdpSocket::bind(("127.0.0.1", port)).await {
            return (tcp, udp);
        }
    }
    panic!("no available TCP/UDP loopback port pair");
}

fn udp_spy(socket: UdpSocket) -> Server {
    let address = socket.local_addr().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    let task = tokio::spawn(async move {
        let mut wire = [0; 4096];
        while socket.recv_from(&mut wire).await.is_ok() {
            counted.fetch_add(1, Ordering::SeqCst);
        }
    });
    Server {
        address,
        calls,
        task,
    }
}

#[tokio::test]
async fn configured_tcp_bootstrap_roots_use_tcp_for_ordinary_and_direct_tagged_upstreams() {
    let main = dns(&["127.0.0.9"]).await;
    let (listener, udp) = paired_loopback_sockets().await;
    let bootstrap = tcp_dns_listener(listener, &["127.0.0.1"]);
    let udp = udp_spy(udp);
    let upstream = tcp_dns(&["127.0.0.2"]).await;
    let target = origin("0.0.0.0:0").await;
    let mut config = document(&main, &udp);
    config["dns"]["default-nameserver"] = json!([format!("tcp://{}", bootstrap.address)]);
    config["dns"]["direct-nameserver"] =
        json!([format!("tcp://localhost:{}", upstream.address.port())]);
    let engine = engine(&config).await;
    let mut meta = metadata(
        "tcp-bootstrap.test",
        SocketAddr::new("127.0.0.9".parse().unwrap(), target.address.port()),
    );
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.2"
    );
    assert_eq!(bootstrap.calls.load(Ordering::SeqCst), 2);
    config["dns"]["direct-nameserver"] = json!([format!(
        "tcp://localhost:{}#DIRECT",
        upstream.address.port()
    )]);
    engine.reload(&config).await.unwrap();
    meta.host = "scoped-tcp-bootstrap.test".into();
    assert_eq!(
        dial(engine.proxy("DIRECT").unwrap(), &meta).await,
        "127.0.0.2"
    );
    assert_eq!(bootstrap.calls.load(Ordering::SeqCst), 4);
    assert_eq!(upstream.calls.load(Ordering::SeqCst), 2);
    assert_eq!(udp.calls.load(Ordering::SeqCst), 0);
    assert_eq!(main.calls.load(Ordering::SeqCst), 0);
    engine.shutdown().await;
}

async fn untrusted_tls_root() -> (Server, Arc<AtomicUsize>, UdpSocket) {
    use boring::{
        pkey::PKey,
        ssl::{SslAcceptor, SslMethod},
        x509::X509,
    };
    let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
    let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
    acceptor
        .set_certificate(&X509::from_der(certificate.cert.der()).unwrap())
        .unwrap();
    acceptor
        .set_private_key(
            &PKey::private_key_from_der(&certificate.key_pair.serialize_der()).unwrap(),
        )
        .unwrap();
    let acceptor = Arc::new(acceptor.build());
    let (listener, udp) = paired_loopback_sockets().await;
    let address = listener.local_addr().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    let application_bytes = Arc::new(AtomicUsize::new(0));
    let application = Arc::clone(&application_bytes);
    let task = tokio::spawn(async move {
        let mut clients = JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (socket, _) = accepted.unwrap();
                    counted.fetch_add(1, Ordering::SeqCst);
                    let acceptor = Arc::clone(&acceptor);
                    let application = Arc::clone(&application);
                    clients.spawn(async move {
                        if let Ok(mut stream) = tokio_boring::accept(&acceptor, socket).await {
                            if stream.read_u8().await.is_ok() {
                                application.fetch_add(1, Ordering::SeqCst);
                            }
                        }
                    });
                },
                Some(result) = clients.join_next(), if !clients.is_empty() => { result.unwrap(); },
            }
        }
    });
    (
        Server {
            address,
            calls,
            task,
        },
        application_bytes,
        udp,
    )
}

#[tokio::test]
async fn encrypted_bootstrap_roots_reject_untrusted_certificates_without_udp_downgrade() {
    for scheme in ["tls", "https"] {
        for routed in [false, true] {
            let main = dns(&["127.0.0.9"]).await;
            let (root, application_bytes, udp) = untrusted_tls_root().await;
            let udp = udp_spy(udp);
            let upstream = tcp_dns(&["127.0.0.2"]).await;
            let mut config = document(&main, &udp);
            config["dns"]["default-nameserver"] = json!([format!("{scheme}://{}", root.address)]);
            let tag = if routed { "#DIRECT" } else { "" };
            config["dns"]["direct-nameserver"] =
                json!([format!("tcp://localhost:{}{tag}", upstream.address.port())]);
            if routed {
                let engine = engine(&config).await;
                let meta = metadata("untrusted-bootstrap.test", "127.0.0.1:1".parse().unwrap());
                let error =
                    tokio::time::timeout(WAIT, engine.proxy("DIRECT").unwrap().dial_tcp(&meta))
                        .await
                        .unwrap()
                        .err()
                        .unwrap();
                assert!(
                    error
                        .to_string()
                        .to_ascii_lowercase()
                        .contains("certificate"),
                    "{scheme}: {error}"
                );
                engine.shutdown().await;
            } else {
                let (logs, _) = broadcast::channel(8);
                let home = tempfile::tempdir().unwrap();
                let error = tokio::time::timeout(WAIT, Engine::create(&config, home.path(), logs))
                    .await
                    .unwrap()
                    .err()
                    .unwrap();
                assert!(
                    format!("{error:#}")
                        .to_ascii_lowercase()
                        .contains("certificate"),
                    "{scheme}: {error:#}"
                );
            }
            assert!(root.calls.load(Ordering::SeqCst) > 0);
            assert_eq!(application_bytes.load(Ordering::SeqCst), 0);
            assert_eq!(udp.calls.load(Ordering::SeqCst), 0);
            assert_eq!(upstream.calls.load(Ordering::SeqCst), 0);
            assert_eq!(main.calls.load(Ordering::SeqCst), 0);
        }
    }
}
