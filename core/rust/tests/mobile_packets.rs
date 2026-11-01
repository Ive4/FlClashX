use async_trait::async_trait;
use flclash::{
    engine::Engine,
    mobile_tun::{Owner, OwnerResolver, PacketSession, TunOptions},
};
use serde_json::json;
use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::{Arc, LazyLock},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, UdpSocket},
    sync::broadcast,
};

static PACKET_TESTS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
static TEST_HOME: LazyLock<tempfile::TempDir> = LazyLock::new(|| tempfile::tempdir().unwrap());

struct NoOwner;
#[async_trait]
impl OwnerResolver for NoOwner {
    async fn resolve(&self, _: u8, _: SocketAddr, _: SocketAddr) -> Option<Owner> {
        None
    }
}

fn ipv4(protocol: u8, target: Ipv4Addr, payload: &[u8]) -> Vec<u8> {
    let mut frame = vec![0x45, 0];
    frame.extend_from_slice(&(20u16 + payload.len() as u16).to_be_bytes());
    frame.extend_from_slice(&[0, 0, 0, 0, 64, protocol, 0, 0]);
    frame.extend_from_slice(&[10, 0, 0, 2]);
    frame.extend_from_slice(&target.octets());
    let mut sum: u32 = frame
        .chunks_exact(2)
        .map(|pair| u16::from_be_bytes([pair[0], pair[1]]) as u32)
        .sum();
    while sum > 65535 {
        sum = (sum & 65535) + (sum >> 16);
    }
    frame[10..12].copy_from_slice(&(!(sum as u16)).to_be_bytes());
    frame.extend_from_slice(payload);
    frame
}

fn udp(target: Ipv4Addr, port: u16, payload: &[u8]) -> Vec<u8> {
    let mut packet = 38000u16.to_be_bytes().to_vec();
    packet.extend_from_slice(&port.to_be_bytes());
    packet.extend_from_slice(&(8u16 + payload.len() as u16).to_be_bytes());
    packet.extend_from_slice(&[0, 0]);
    packet.extend_from_slice(payload);
    ipv4(17, target, &packet)
}

fn tcp(port: u16, sequence: u32, ack: u32, flags: u8, payload: &[u8]) -> Vec<u8> {
    let mut packet = 39000u16.to_be_bytes().to_vec();
    packet.extend_from_slice(&port.to_be_bytes());
    packet.extend_from_slice(&sequence.to_be_bytes());
    packet.extend_from_slice(&ack.to_be_bytes());
    packet.extend_from_slice(&[0x50, flags, 0xff, 0xff, 0, 0, 0, 0]);
    packet.extend_from_slice(payload);
    ipv4(6, Ipv4Addr::LOCALHOST, &packet)
}

fn ipv6(protocol: u8, target: Ipv6Addr, payload: &[u8]) -> Vec<u8> {
    let mut frame = vec![0x60, 0, 0, 0];
    frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    frame.extend_from_slice(&[protocol, 64]);
    frame.extend_from_slice(&"fd00::2".parse::<Ipv6Addr>().unwrap().octets());
    frame.extend_from_slice(&target.octets());
    frame.extend_from_slice(payload);
    frame
}

fn udp6(target: Ipv6Addr, port: u16, payload: &[u8]) -> Vec<u8> {
    let datagram = udp(Ipv4Addr::LOCALHOST, port, payload);
    ipv6(17, target, &datagram[20..])
}

fn tcp6(port: u16, sequence: u32, ack: u32, flags: u8, payload: &[u8]) -> Vec<u8> {
    let datagram = tcp(port, sequence, ack, flags, payload);
    ipv6(6, Ipv6Addr::LOCALHOST, &datagram[20..])
}

async fn packet(session: &mut PacketSession, protocol: u8, version: u8) -> Vec<u8> {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let frame = session.output.recv().await.expect("packet stack closed");
            if frame.len() >= 28
                && frame[0] >> 4 == version
                && frame[if version == 4 { 9 } else { 6 }] == protocol
            {
                return frame;
            }
        }
    })
    .await
    .expect("packet forwarding timed out")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn raw_packets_forward_udp_tcp_dns_and_restart_without_stale_stack() {
    let _serial = PACKET_TESTS.lock().await;
    let home = &*TEST_HOME;
    let (logs, _) = broadcast::channel(16);
    let engine = Engine::create(&json!({"mode":"direct", "ipv6":true, "dns":{"enable":true, "nameserver":["rcode://refused"]}, "hosts":{"packet.test":"192.0.2.91"}}), home.path(), logs).await.unwrap();
    let options = TunOptions::parse(
        "10.0.0.1/32,fd00::1/128",
        "10.0.0.53,fd00::53",
        r#"{"mtu":1500}"#,
    )
    .unwrap();
    let mut session = PacketSession::start(
        engine.state.tunnel.clone(),
        options.clone(),
        Arc::new(NoOwner),
    )
    .unwrap();

    let echo = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let port = echo.local_addr().unwrap().port();
    let udp_echo = tokio::spawn(async move {
        let mut buffer = [0; 64];
        let (size, peer) = echo.recv_from(&mut buffer).await.unwrap();
        echo.send_to(&buffer[..size], peer).await.unwrap();
    });
    session
        .input
        .send(udp(Ipv4Addr::LOCALHOST, port, b"fd-udp-echo"))
        .await
        .unwrap();
    let received = packet(&mut session, 17, 4).await;
    assert_eq!(&received[28..], b"fd-udp-echo");
    assert_eq!(&received[12..16], &[127, 0, 0, 1]);
    assert_eq!(&received[16..20], &[10, 0, 0, 2]);
    udp_echo.await.unwrap();
    assert_eq!(engine.state.tunnel.statistics().snapshot(), (11, 11));

    let query =
        b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x06packet\x04test\x00\x00\x01\x00\x01";
    session
        .input
        .send(udp(Ipv4Addr::new(10, 0, 0, 53), 53, query))
        .await
        .unwrap();
    let answer = packet(&mut session, 17, 4).await;
    assert_eq!(&answer[28..30], &[0x12, 0x34]);
    assert_ne!(answer[30] & 0x80, 0);
    assert!(answer[28..].windows(4).any(|part| part == [192, 0, 2, 91]));

    let echo6 = UdpSocket::bind("[::1]:0").await.unwrap();
    let port6 = echo6.local_addr().unwrap().port();
    let udp6_echo = tokio::spawn(async move {
        let mut buffer = [0; 64];
        let (size, peer) = echo6.recv_from(&mut buffer).await.unwrap();
        echo6.send_to(&buffer[..size], peer).await.unwrap();
    });
    session
        .input
        .send(udp6(Ipv6Addr::LOCALHOST, port6, b"v6-udp-echo"))
        .await
        .unwrap();
    let received6 = packet(&mut session, 17, 6).await;
    assert_eq!(&received6[48..], b"v6-udp-echo");
    assert_eq!(&received6[8..24], &Ipv6Addr::LOCALHOST.octets());
    assert_eq!(
        &received6[24..40],
        &"fd00::2".parse::<Ipv6Addr>().unwrap().octets()
    );
    udp6_echo.await.unwrap();
    session
        .input
        .send(udp6("fd00::53".parse().unwrap(), 53, query))
        .await
        .unwrap();
    let answer6 = packet(&mut session, 17, 6).await;
    assert_eq!(&answer6[48..50], &[0x12, 0x34]);
    assert!(answer6[48..].windows(4).any(|part| part == [192, 0, 2, 91]));

    let listener6 = TcpListener::bind("[::1]:0").await.unwrap();
    let port6 = listener6.local_addr().unwrap().port();
    let tcp6_echo = tokio::spawn(async move {
        let (mut stream, _) = listener6.accept().await.unwrap();
        let mut payload = [0; 11];
        stream.read_exact(&mut payload).await.unwrap();
        assert_eq!(&payload, b"v6-tcp-echo");
        stream.write_all(&payload).await.unwrap();
    });
    session
        .input
        .send(tcp6(port6, 200, 0, 0x02, &[]))
        .await
        .unwrap();
    let syn_ack6 = packet(&mut session, 6, 6).await;
    assert_eq!(syn_ack6[53] & 0x12, 0x12);
    let server_seq6 = u32::from_be_bytes(syn_ack6[44..48].try_into().unwrap());
    session
        .input
        .send(tcp6(port6, 201, server_seq6.wrapping_add(1), 0x10, &[]))
        .await
        .unwrap();
    session
        .input
        .send(tcp6(
            port6,
            201,
            server_seq6.wrapping_add(1),
            0x18,
            b"v6-tcp-echo",
        ))
        .await
        .unwrap();
    let echoed6 = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let frame = packet(&mut session, 6, 6).await;
            let offset = 40 + ((frame[52] >> 4) as usize * 4);
            if frame.len() > offset {
                break frame[offset..].to_vec();
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(echoed6, b"v6-tcp-echo");
    tcp6_echo.await.unwrap();

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let tcp_echo = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut payload = [0; 11];
        stream.read_exact(&mut payload).await.unwrap();
        assert_eq!(&payload, b"fd-tcp-echo");
        stream.write_all(&payload).await.unwrap();
    });
    session
        .input
        .send(tcp(port, 100, 0, 0x02, &[]))
        .await
        .unwrap();
    let syn_ack = packet(&mut session, 6, 4).await;
    assert_eq!(syn_ack[33] & 0x12, 0x12);
    let server_seq = u32::from_be_bytes(syn_ack[24..28].try_into().unwrap());
    session
        .input
        .send(tcp(port, 101, server_seq.wrapping_add(1), 0x10, &[]))
        .await
        .unwrap();
    session
        .input
        .send(tcp(
            port,
            101,
            server_seq.wrapping_add(1),
            0x18,
            b"fd-tcp-echo",
        ))
        .await
        .unwrap();
    let echoed = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let frame = packet(&mut session, 6, 4).await;
            let offset = 20 + ((frame[32] >> 4) as usize * 4);
            if frame.len() > offset {
                break frame[offset..].to_vec();
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(echoed, b"fd-tcp-echo");
    tcp_echo.await.unwrap();
    session.stop().await.unwrap();
    assert!(session.is_finished());
    let mut restarted =
        PacketSession::start(engine.state.tunnel.clone(), options, Arc::new(NoOwner)).unwrap();
    restarted.stop().await.unwrap();
    engine.shutdown().await;
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fd_start_duplicates_and_stop_keeps_callers_descriptor_open() {
    let _serial = PACKET_TESTS.lock().await;
    use std::os::{fd::AsRawFd, unix::net::UnixDatagram};
    let home = &*TEST_HOME;
    let (logs, _) = broadcast::channel(16);
    let engine = Engine::create(
        &json!({"mode":"direct", "dns":{"enable":true, "nameserver":["rcode://refused"]}, "hosts":{"packet.test":"192.0.2.91"}}),
        home.path(),
        logs,
    )
    .await
    .unwrap();
    let (source, peer) = UnixDatagram::pair().unwrap();
    let fd = source.as_raw_fd();
    flclash::mobile_tun::start(
        fd,
        engine.state.tunnel.clone(),
        TunOptions::parse("10.0.0.1/32", "10.0.0.53", "{}").unwrap(),
        Arc::new(NoOwner),
    )
    .await
    .unwrap();
    let transferred = tokio::task::spawn_blocking(move || {
        peer.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let query = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x06packet\x04test\x00\x00\x01\x00\x01";
        peer.send(&udp(Ipv4Addr::new(10, 0, 0, 53), 53, query))
            .unwrap();
        let mut response = [0; 1500];
        let size = peer.recv(&mut response).unwrap();
        assert_eq!(&response[28..30], &[0x12, 0x34]);
        assert!(response[28..size]
            .windows(4)
            .any(|part| part == [192, 0, 2, 91]));
    });
    transferred.await.unwrap();
    flclash::mobile_tun::stop().await.unwrap();
    assert!(unsafe { libc::fcntl(fd, libc::F_GETFD) } >= 0);
    assert!(flclash::mobile_tun::start(
        -1,
        engine.state.tunnel.clone(),
        TunOptions::parse("10.0.0.1/32", "", "{}").unwrap(),
        Arc::new(NoOwner)
    )
    .await
    .is_err());
    engine.shutdown().await;
}
