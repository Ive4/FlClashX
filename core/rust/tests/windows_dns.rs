#[path = "../vendor/meow-listener/src/tun/dns_tcp.rs"]
mod dns_tcp;
#[cfg(windows)]
#[path = "../vendor/meow-listener/src/tun/windows_dns.rs"]
mod windows_dns;

#[tokio::test]
async fn tcp_dns_handles_framing_and_reads_the_current_resolver_for_each_query() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let home = tempfile::tempdir().unwrap();
    let (logs, _) = tokio::sync::broadcast::channel(16);
    let document = |last: u8| {
        serde_json::json!({
            "ipv6":true,"hosts":{"dns-test.example":[format!("192.0.2.{last}"),format!("2001:db8::{last}")]},
            "tun":{"enable":false},"dns":{"enable":true,"ipv6":true,"use-hosts":true,"use-system-hosts":false,"enhanced-mode":"redir-host","nameserver":["rcode://refused"]},"rules":["MATCH,DIRECT"]
        })
    };
    let engine = flclash::engine::Engine::create(&document(10), home.path(), logs)
        .await
        .unwrap();
    let slot = engine.state.tunnel.resolver_slot();
    let (mut client, server) = tokio::io::duplex(4096);
    let task = tokio::spawn(dns_tcp::serve(server, slot.clone()));
    for (id, kind, last) in [(1u16, 1u16, 10u8), (2, 1, 11), (3, 28, 11)] {
        if id == 2 {
            engine.reload(&document(last)).await.unwrap();
        }
        let mut query = vec![0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
        query[..2].copy_from_slice(&id.to_be_bytes());
        query.extend_from_slice(b"\x08dns-test\x07example\x00");
        query.extend_from_slice(&kind.to_be_bytes());
        query.extend_from_slice(&1u16.to_be_bytes());
        client.write_u16(query.len() as u16).await.unwrap();
        for piece in query.chunks(3) {
            client.write_all(piece).await.unwrap();
        }
        let length = client.read_u16().await.unwrap();
        let mut reply = vec![0; length as usize];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply[..2], &id.to_be_bytes());
        assert_eq!(u16::from_be_bytes([reply[6], reply[7]]), 1);
        if kind == 1 {
            assert!(reply.windows(4).any(|bytes| bytes == [192, 0, 2, last]));
        } else {
            let ip: std::net::Ipv6Addr = "2001:db8::11".parse().unwrap();
            assert!(reply.windows(16).any(|bytes| bytes == ip.octets()));
        }
    }
    client.shutdown().await.unwrap();
    assert!(task.await.unwrap().is_ok());
    let (mut client, server) = tokio::io::duplex(16);
    let task = tokio::spawn(dns_tcp::serve(server, slot));
    client.write_u16(0).await.unwrap();
    assert_eq!(
        task.await.unwrap().unwrap_err().kind(),
        std::io::ErrorKind::InvalidData
    );
    engine.shutdown().await;
}

#[cfg(windows)]
#[test]
#[ignore = "Uses a separately created, disconnected FlClashDNS-Test-* adapter"]
fn native_dns_changes_only_the_owned_test_adapter() {
    let index: u32 = std::env::var("FLCLASH_DNS_TEST_INTERFACE")
        .unwrap()
        .parse()
        .unwrap();
    let output = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-Command",
            &format!("(Get-NetAdapter -InterfaceIndex {index}).Name"),
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout)
        .trim()
        .starts_with("FlClashDNS-Test-"));
    windows_dns::test_owned_adapter(index);
}
