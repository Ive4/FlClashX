use super::*;
use boring::{pkey::PKey, ssl::SslAcceptor};
use hickory_proto::{
    op::{Message, MessageType, OpCode},
    rr::{rdata::A, RData, Record, RecordType},
    serialize::binary::{BinDecodable, BinEncodable},
};
use meow_dns::client::DnsClient;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
};

struct Certificate {
    der: Vec<u8>,
    key: Vec<u8>,
}

impl Certificate {
    fn new() -> Self {
        let certified =
            rcgen::generate_simple_self_signed(vec!["localhost".into(), "127.0.0.1".into()])
                .unwrap();
        Self {
            der: certified.cert.der().to_vec(),
            key: certified.key_pair.serialize_der(),
        }
    }

    fn server_config(&self) -> quiche::Config {
        let mut tls = SslContextBuilder::new(SslMethod::tls()).unwrap();
        tls.set_certificate(&X509::from_der(&self.der).unwrap())
            .unwrap();
        tls.set_private_key(&PKey::private_key_from_der(&self.key).unwrap())
            .unwrap();
        let mut config =
            quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, tls).unwrap();
        config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        config.set_max_idle_timeout(5000);
        config.set_max_recv_udp_payload_size(1350);
        config.set_max_send_udp_payload_size(1350);
        config.set_initial_max_data(256 * 1024);
        config.set_initial_max_stream_data_bidi_local(128 * 1024);
        config.set_initial_max_stream_data_bidi_remote(128 * 1024);
        config.set_initial_max_stream_data_uni(32 * 1024);
        config.set_initial_max_streams_bidi(4);
        config.set_initial_max_streams_uni(3);
        config
    }

    fn transport(&self) -> Http3Transport {
        Http3Transport {
            extra_roots: vec![self.der.clone()],
            ..Default::default()
        }
    }
}

async fn paired_sockets() -> (UdpSocket, TcpListener) {
    for _ in 0..128 {
        let port = 10000 + rand::random::<u16>() % 50000;
        let Ok(udp) = UdpSocket::bind(("127.0.0.1", port)).await else {
            continue;
        };
        if let Ok(tcp) = TcpListener::bind(("127.0.0.1", port)).await {
            return (udp, tcp);
        }
    }
    panic!("No paired loopback test port");
}

fn answer(wire: &[u8], wrong_id: bool) -> Vec<u8> {
    let query = Message::from_bytes(wire).unwrap();
    let mut response = Message::new(
        query.metadata.id ^ u16::from(wrong_id),
        MessageType::Response,
        OpCode::Query,
    );
    response.metadata.recursion_available = true;
    for question in &query.queries {
        response.add_query(question.clone());
        response.add_answer(Record::from_rdata(
            question.name.clone(),
            30,
            RData::A(A("192.0.2.7".parse().unwrap())),
        ));
    }
    response.to_bytes().unwrap()
}

fn spawn_http3(
    socket: UdpSocket,
    mut config: quiche::Config,
    wrong_id: bool,
    calls: Arc<AtomicUsize>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let local = socket.local_addr().unwrap();
        let mut input = [0_u8; 65535];
        let mut output = [0_u8; 1350];
        let (size, peer) = socket.recv_from(&mut input).await.unwrap();
        let header =
            quiche::Header::from_slice(&mut input[..size], quiche::MAX_CONN_ID_LEN).unwrap();
        let mut connection = quiche::accept(&header.dcid, None, local, peer, &mut config).unwrap();
        connection
            .recv(
                &mut input[..size],
                quiche::RecvInfo {
                    from: peer,
                    to: local,
                },
            )
            .unwrap();
        let h3_config = quiche::h3::Config::new().unwrap();
        let mut http3 = None;
        let mut bodies = HashMap::<u64, Vec<u8>>::new();
        loop {
            if connection.is_established() && http3.is_none() {
                http3 = Some(
                    quiche::h3::Connection::with_transport(&mut connection, &h3_config).unwrap(),
                );
            }
            if let Some(http3) = &mut http3 {
                loop {
                    match http3.poll(&mut connection) {
                        Ok((_id, quiche::h3::Event::Headers { list, .. })) => {
                            assert!(list
                                .iter()
                                .any(|header| header.name() == b":method"
                                    && header.value() == b"POST"));
                            assert!(list.iter().any(|header| header.name() == b":path"
                                && header.value() == b"/custom-dns"));
                            calls.fetch_add(1, Ordering::SeqCst);
                        }
                        Ok((id, quiche::h3::Event::Data)) => loop {
                            match http3.recv_body(&mut connection, id, &mut input) {
                                Ok(0) => break,
                                Ok(size) => bodies
                                    .entry(id)
                                    .or_default()
                                    .extend_from_slice(&input[..size]),
                                Err(quiche::h3::Error::Done) => break,
                                Err(error) => panic!("HTTP/3 request body: {error}"),
                            }
                        },
                        Ok((id, quiche::h3::Event::Finished)) => {
                            let response = answer(bodies.get(&id).unwrap(), wrong_id);
                            let headers = [
                                Header::new(b":status", b"200"),
                                Header::new(b"content-type", b"application/dns-message"),
                                Header::new(
                                    b"content-length",
                                    response.len().to_string().as_bytes(),
                                ),
                            ];
                            http3
                                .send_response(&mut connection, id, &headers, false)
                                .unwrap();
                            assert_eq!(
                                http3
                                    .send_body(&mut connection, id, &response, true)
                                    .unwrap(),
                                response.len()
                            );
                        }
                        Ok(_) => {}
                        Err(quiche::h3::Error::Done) => break,
                        Err(error) => panic!("HTTP/3 server: {error}"),
                    }
                }
            }
            while let Ok((size, info)) = connection.send(&mut output) {
                socket.send_to(&output[..size], info.to).await.unwrap();
            }
            if connection.is_closed() {
                break;
            }
            match tokio::time::timeout(
                connection.timeout().unwrap_or(Duration::from_secs(5)),
                socket.recv_from(&mut input),
            )
            .await
            {
                Ok(Ok((size, from))) => {
                    let _ =
                        connection.recv(&mut input[..size], quiche::RecvInfo { from, to: local });
                }
                Ok(Err(error)) => panic!("HTTP/3 server socket: {error}"),
                Err(_) => connection.on_timeout(),
            }
        }
    })
}

fn spawn_https(
    listener: TcpListener,
    cert: &Certificate,
    requests: usize,
    calls: Arc<AtomicUsize>,
) -> JoinHandle<()> {
    let mut acceptor = SslAcceptor::mozilla_intermediate(SslMethod::tls()).unwrap();
    acceptor
        .set_certificate(&X509::from_der(&cert.der).unwrap())
        .unwrap();
    acceptor
        .set_private_key(&PKey::private_key_from_der(&cert.key).unwrap())
        .unwrap();
    let acceptor = acceptor.build();
    tokio::spawn(async move {
        for _ in 0..requests {
            let (socket, _) = listener.accept().await.unwrap();
            let mut stream = tokio_boring::accept(&acceptor, socket).await.unwrap();
            let mut data = Vec::new();
            let end = loop {
                let mut byte = [0_u8];
                stream.read_exact(&mut byte).await.unwrap();
                data.push(byte[0]);
                if data.ends_with(b"\r\n\r\n") {
                    break data.len();
                }
            };
            let headers = std::str::from_utf8(&data).unwrap();
            assert!(headers.starts_with("POST /custom-dns HTTP/1.1"));
            let size = headers
                .lines()
                .find_map(|line| {
                    line.to_lowercase()
                        .strip_prefix("content-length:")
                        .map(|value| value.trim().parse::<usize>().unwrap())
                })
                .unwrap();
            data.resize(end + size, 0);
            stream.read_exact(&mut data[end..]).await.unwrap();
            let body = answer(&data[end..], false);
            stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).as_bytes()).await.unwrap();
            stream.write_all(&body).await.unwrap();
            stream.flush().await.unwrap();
            calls.fetch_add(1, Ordering::SeqCst);
        }
    })
}

#[tokio::test]
async fn actual_http3_doh_verifies_dns_and_never_opens_tcp() {
    for name in ["localhost", "127.0.0.1"] {
        let cert = Certificate::new();
        let (udp, tcp) = paired_sockets().await;
        let addr = udp.local_addr().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let server = spawn_http3(udp, cert.server_config(), false, calls.clone());
        let _guard = preferred_doh::install(Some(Arc::new(cert.transport())));
        let client = DnsClient::doh(addr, name, "/custom-dns");
        let message = client.query("http3.test", RecordType::A).await.unwrap();
        assert_eq!(message.answers.len(), 1);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(
            tokio::time::timeout(Duration::from_millis(50), tcp.accept())
                .await
                .is_err()
        );
        server.abort();
        let _ = server.await;
    }
}

#[tokio::test]
async fn unavailable_http3_falls_back_to_verified_tls_and_backs_off() {
    let cert = Certificate::new();
    let (udp, tcp) = paired_sockets().await;
    let addr = udp.local_addr().unwrap();
    let packets = Arc::new(AtomicUsize::new(0));
    let observed = packets.clone();
    let blackhole = tokio::spawn(async move {
        let mut buffer = [0_u8; 65535];
        while udp.recv(&mut buffer).await.is_ok() {
            observed.fetch_add(1, Ordering::SeqCst);
        }
    });
    let calls = Arc::new(AtomicUsize::new(0));
    let server = spawn_https(tcp, &cert, 2, calls.clone());
    let _guard = preferred_doh::install(Some(Arc::new(cert.transport())));
    let client =
        DnsClient::doh(addr, "localhost", "/custom-dns").with_tls_additional_roots(cert.der);
    client.query("fallback.test", RecordType::A).await.unwrap();
    let before = packets.load(Ordering::SeqCst);
    assert!(before > 0);
    client.query("backoff.test", RecordType::A).await.unwrap();
    assert_eq!(packets.load(Ordering::SeqCst), before);
    server.await.unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    blackhole.abort();
    let _ = blackhole.await;
}

#[tokio::test]
async fn invalid_http3_dns_transaction_falls_back_without_accepting_wrong_answer() {
    let cert = Certificate::new();
    let (udp, tcp) = paired_sockets().await;
    let addr = udp.local_addr().unwrap();
    let h3_calls = Arc::new(AtomicUsize::new(0));
    let h3 = spawn_http3(udp, cert.server_config(), true, h3_calls.clone());
    let tls_calls = Arc::new(AtomicUsize::new(0));
    let tls = spawn_https(tcp, &cert, 1, tls_calls.clone());
    let _guard = preferred_doh::install(Some(Arc::new(cert.transport())));
    let client =
        DnsClient::doh(addr, "localhost", "/custom-dns").with_tls_additional_roots(cert.der);
    client
        .query("transaction.test", RecordType::A)
        .await
        .unwrap();
    tls.await.unwrap();
    assert_eq!(h3_calls.load(Ordering::SeqCst), 1);
    assert_eq!(tls_calls.load(Ordering::SeqCst), 1);
    h3.abort();
    let _ = h3.await;
}

#[tokio::test]
async fn certificate_chain_and_hostname_failure_never_send_dns() {
    for (trusted, name) in [(false, "localhost"), (true, "wrong.invalid")] {
        let cert = Certificate::new();
        let (udp, _tcp) = paired_sockets().await;
        let addr = udp.local_addr().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let server = spawn_http3(udp, cert.server_config(), false, calls.clone());
        let mut wire = Message::new(7, MessageType::Query, OpCode::Query);
        wire.add_query(hickory_proto::op::Query::query(
            "verify.test".parse().unwrap(),
            RecordType::A,
        ));
        let transport = if trusted {
            cert.transport()
        } else {
            Http3Transport::default()
        };
        assert!(transport
            .exchange(DohRequest {
                address: addr,
                server_name: name,
                path: "/custom-dns",
                wire: &wire.to_bytes().unwrap(),
                proxy: None,
                proxy_target: None
            })
            .await
            .is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        server.abort();
        let _ = server.await;
    }
}

struct RecordingProxy {
    address: SocketAddr,
    metadata: Mutex<Vec<Metadata>>,
    health: meow_common::ProxyHealth,
}

struct BoundDatagram(UdpSocket);

#[async_trait::async_trait]
impl ProxyPacketConn for BoundDatagram {
    async fn read_packet(&self, bytes: &mut [u8]) -> meow_common::Result<(usize, SocketAddr)> {
        Ok((self.0.recv(bytes).await?, self.0.peer_addr()?))
    }
    async fn write_packet(
        &self,
        bytes: &[u8],
        _address: &SocketAddr,
    ) -> meow_common::Result<usize> {
        Ok(self.0.send(bytes).await?)
    }
    fn local_addr(&self) -> meow_common::Result<SocketAddr> {
        Ok(self.0.local_addr()?)
    }
    fn close(&self) -> meow_common::Result<()> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl meow_common::ProxyAdapter for RecordingProxy {
    fn health(&self) -> &meow_common::ProxyHealth {
        &self.health
    }
    fn name(&self) -> &str {
        "selected-dns-proxy"
    }
    fn addr(&self) -> &str {
        "test-proxy"
    }
    fn adapter_type(&self) -> meow_common::AdapterType {
        meow_common::AdapterType::Direct
    }
    fn support_udp(&self) -> bool {
        true
    }
    async fn dial_tcp(
        &self,
        _metadata: &Metadata,
    ) -> meow_common::Result<Box<dyn meow_common::ProxyConn>> {
        Err(meow_common::MeowError::NotSupported(
            "TCP must not be used".into(),
        ))
    }
    async fn dial_udp(&self, metadata: &Metadata) -> meow_common::Result<Box<dyn ProxyPacketConn>> {
        self.metadata.lock().push(metadata.clone());
        let socket = UdpSocket::bind("127.0.0.1:0").await?;
        socket.connect(self.address).await?;
        Ok(Box::new(BoundDatagram(socket)))
    }
}

impl meow_common::Proxy for RecordingProxy {
    fn alive(&self) -> bool {
        true
    }
    fn alive_for_url(&self, _url: &str) -> bool {
        true
    }
    fn last_delay(&self) -> u16 {
        0
    }
    fn last_delay_for_url(&self, _url: &str) -> u16 {
        0
    }
    fn delay_history(&self) -> Vec<meow_common::DelayHistory> {
        Vec::new()
    }
}

#[tokio::test]
async fn http3_uses_selected_proxy_with_remote_hostname_and_internal_metadata() {
    let cert = Certificate::new();
    let (udp, _tcp) = paired_sockets().await;
    let address = udp.local_addr().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let server = spawn_http3(udp, cert.server_config(), false, calls.clone());
    let recorded = Arc::new(RecordingProxy {
        address,
        metadata: Mutex::new(Vec::new()),
        health: meow_common::ProxyHealth::new(),
    });
    let proxy: meow_dns::client::DnsProxy = recorded.clone();
    let mut wire = Message::new(9, MessageType::Query, OpCode::Query);
    wire.add_query(hickory_proto::op::Query::query(
        "proxy.test".parse().unwrap(),
        RecordType::A,
    ));
    let response = cert
        .transport()
        .exchange(DohRequest {
            address: SocketAddr::from(([0, 0, 0, 0], address.port())),
            server_name: "localhost",
            path: "/custom-dns",
            wire: &wire.to_bytes().unwrap(),
            proxy: Some(&proxy),
            proxy_target: Some(("unresolvable.invalid", address.port())),
        })
        .await
        .unwrap();
    assert_eq!(Message::from_bytes(&response).unwrap().answers.len(), 1);
    let metadata = recorded.metadata.lock();
    assert_eq!(metadata.len(), 1);
    assert_eq!(metadata[0].host, "unresolvable.invalid");
    assert_eq!(metadata[0].dst_ip, None);
    assert!(metadata[0].internal);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn engine_reload_failure_restores_preference_and_old_shutdown_keeps_successor() {
    let home = tempfile::tempdir().unwrap();
    let (logs, _) = tokio::sync::broadcast::channel(8);
    let document = json!({"mode":"direct","dns":{"enable":false,"prefer-h3":true}});
    let engine = crate::engine::Engine::create(&document, home.path(), logs.clone())
        .await
        .unwrap();
    assert!(preferred_doh::current().is_some());
    assert!(engine
        .reload(&json!({"mixed-port":"invalid-port","dns":{"prefer-h3":false}}))
        .await
        .is_err());
    assert!(preferred_doh::current().is_some());
    let successor = crate::engine::Engine::create(&document, home.path(), logs)
        .await
        .unwrap();
    engine.shutdown().await;
    assert!(preferred_doh::current().is_some());
    successor.shutdown().await;
}

#[test]
fn preference_validation_and_scoped_rollback_are_exact() {
    assert!(!validate(&json!({})).unwrap());
    assert!(validate(&json!({"dns":{"prefer-h3":true}})).unwrap());
    for value in [json!(1), json!("true"), json!([])] {
        assert_eq!(
            validate(&json!({"dns":{"prefer-h3":value}}))
                .unwrap_err()
                .details["path"],
            "dns.prefer-h3"
        );
    }
    let base = install(&json!({"dns":{"prefer-h3":false}})).unwrap();
    assert!(preferred_doh::current().is_none());
    {
        let _candidate = install(&json!({"dns":{"prefer-h3":true}})).unwrap();
        assert!(preferred_doh::current().is_some());
    }
    assert!(preferred_doh::current().is_none());
    let successor = install(&json!({"dns":{"prefer-h3":true}})).unwrap();
    drop(base);
    assert!(preferred_doh::current().is_some());
    drop(successor);
}

#[tokio::test]
async fn actual_http3_direct_dns_group_bootstraps_its_dial_hostname_separately_from_sni() {
    let certified = rcgen::generate_simple_self_signed(vec![
        "different-sni.test".into(),
        "upstream-bootstrap.test".into(),
    ])
    .unwrap();
    let cert = Certificate {
        der: certified.cert.der().to_vec(),
        key: certified.key_pair.serialize_der(),
    };
    for fragment in ["different-sni.test?proxy=dns-route", "dns-route"] {
        let (udp, tcp) = paired_sockets().await;
        let address = udp.local_addr().unwrap();
        let h3_calls = Arc::new(AtomicUsize::new(0));
        let server = spawn_http3(udp, cert.server_config(), false, Arc::clone(&h3_calls));
        let bootstrap = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let bootstrap_address = bootstrap.local_addr().unwrap();
        let bootstrap_calls = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&bootstrap_calls);
        let bootstrap = tokio::spawn(async move {
            for _ in 0..2 {
                let mut wire = [0; 4096];
                let (size, peer) = bootstrap.recv_from(&mut wire).await.unwrap();
                let request = Message::from_bytes(&wire[..size]).unwrap();
                let mut response =
                    Message::new(request.metadata.id, MessageType::Response, OpCode::Query);
                response.metadata.recursion_available = true;
                for question in request.queries {
                    assert_eq!(question.name.to_string(), "upstream-bootstrap.test.");
                    response.add_query(question.clone());
                    if question.query_type == RecordType::A {
                        response.add_answer(Record::from_rdata(
                            question.name,
                            30,
                            RData::A(A("127.0.0.1".parse().unwrap())),
                        ));
                    }
                }
                counted.fetch_add(1, Ordering::SeqCst);
                bootstrap
                    .send_to(&response.to_bytes().unwrap(), peer)
                    .await
                    .unwrap();
            }
        });
        let document = json!({
            "strict":true,"rules":["MATCH,DIRECT"],
            "proxy-groups":[{"name":"dns-route","type":"select","proxies":["DIRECT"]}],
            "dns":{"enable":true,"enhanced-mode":"redir-host","use-system-hosts":false,
                "nameserver":["rcode://refused"],
                "default-nameserver":[bootstrap_address.to_string()],
                "direct-nameserver":[format!("https://upstream-bootstrap.test:{}/custom-dns#{fragment}",address.port())]},
        });
        let _guard = preferred_doh::install(Some(Arc::new(cert.transport())));
        let raw =
            meow_config::parse_raw_yaml(&serde_saphyr::to_string(&document).unwrap()).unwrap();
        let config = meow_config::build_config(raw, None).await.unwrap();
        assert_eq!(
            serde_json::to_value(config.raw.dns.as_ref().unwrap()).unwrap()["direct-nameserver"],
            document["dns"]["direct-nameserver"]
        );
        let direct = config.dns.resolver.direct_resolver().unwrap();
        let answer = tokio::time::timeout(
            Duration::from_secs(5),
            direct.resolve_ip("actual-direct-h3.test"),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(answer, Some("192.0.2.7".parse().unwrap()));
        assert_eq!(h3_calls.load(Ordering::SeqCst), 1);
        assert_eq!(bootstrap_calls.load(Ordering::SeqCst), 2);
        bootstrap.await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(50), tcp.accept())
                .await
                .is_err()
        );
        server.abort();
        let _ = server.await;
    }
}

#[tokio::test]
async fn prefer_h3_only_reload_changes_real_transport_for_unchanged_nameservers() {
    use base64::Engine as _;
    let cert = Certificate::new();
    let (udp, tcp) = paired_sockets().await;
    let address = udp.local_addr().unwrap();
    let h3_calls = Arc::new(AtomicUsize::new(0));
    let server = spawn_http3(udp, cert.server_config(), false, Arc::clone(&h3_calls));
    let home = tempfile::tempdir().unwrap();
    let (logs, _) = tokio::sync::broadcast::channel(8);
    let mut document = json!({"rules":["MATCH,DIRECT"],"dns":{"enable":true,"enhanced-mode":"redir-host","prefer-h3":false,"use-system-hosts":false,"nameserver":[format!("https://127.0.0.1:{}/custom-dns",address.port())]}});
    let engine = crate::engine::Engine::create(&document, home.path(), logs)
        .await
        .unwrap();
    let previous = engine.state.tunnel.resolver();
    let preference = preferred_doh::install(Some(Arc::new(cert.transport())));
    document["dns"]["prefer-h3"] = json!(true);
    let payload = base64::engine::general_purpose::STANDARD
        .encode(serde_saphyr::to_string(&document).unwrap());
    engine
        .api("PUT", "/configs", json!({"payload":payload}))
        .await
        .unwrap();
    let resolver = engine.state.tunnel.resolver();
    assert!(!Arc::ptr_eq(&previous, &resolver));
    assert_eq!(
        resolver
            .resolve_ip("enabled-only-toggle.test")
            .await
            .unwrap(),
        Some("192.0.2.7".parse().unwrap())
    );
    assert_eq!(h3_calls.load(Ordering::SeqCst), 1);
    server.abort();
    let _ = server.await;
    let udp = UdpSocket::bind(address).await.unwrap();
    let udp_calls = Arc::new(AtomicUsize::new(0));
    let observed = Arc::clone(&udp_calls);
    let spy = tokio::spawn(async move {
        let mut wire = [0; 4096];
        while udp.recv_from(&mut wire).await.is_ok() {
            observed.fetch_add(1, Ordering::SeqCst);
        }
    });
    let mut acceptor = SslAcceptor::mozilla_intermediate_v5(SslMethod::tls()).unwrap();
    acceptor
        .set_certificate(&X509::from_der(&cert.der).unwrap())
        .unwrap();
    acceptor
        .set_private_key(&PKey::private_key_from_der(&cert.key).unwrap())
        .unwrap();
    let acceptor = acceptor.build();
    let tcp_calls = Arc::new(AtomicUsize::new(0));
    let observed = Arc::clone(&tcp_calls);
    let tls = tokio::spawn(async move {
        let (stream, _) = tcp.accept().await.unwrap();
        observed.fetch_add(1, Ordering::SeqCst);
        assert!(tokio_boring::accept(&acceptor, stream).await.is_err());
    });
    drop(preference);
    let _off = preferred_doh::install(None);
    document["dns"]["prefer-h3"] = json!(false);
    let payload = base64::engine::general_purpose::STANDARD
        .encode(serde_saphyr::to_string(&document).unwrap());
    engine
        .api("PUT", "/configs", json!({"payload":payload}))
        .await
        .unwrap();
    let disabled = engine.state.tunnel.resolver();
    assert!(!Arc::ptr_eq(&resolver, &disabled));
    assert!(tokio::time::timeout(
        Duration::from_secs(5),
        disabled.resolve_ip("disabled-only-toggle.test")
    )
    .await
    .unwrap()
    .is_err());
    tls.await.unwrap();
    assert_eq!(tcp_calls.load(Ordering::SeqCst), 1);
    assert_eq!(h3_calls.load(Ordering::SeqCst), 1);
    assert_eq!(udp_calls.load(Ordering::SeqCst), 0);
    spy.abort();
    let _ = spy.await;
    engine.shutdown().await;
}
