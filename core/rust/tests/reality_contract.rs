use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
use boring::{
    derive::Deriver,
    hash::MessageDigest,
    hmac::Hmac,
    pkey::{Id, PKey},
};
use meow_transport::{
    tls::{RealityConfig, TlsConfig, TlsLayer},
    Transport,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::{
    io::AsyncReadExt,
    net::{TcpListener, TcpStream},
};

fn hmac(key: &[u8], value: &[u8]) -> Vec<u8> {
    let mut hmac = Hmac::init(key, &MessageDigest::sha256()).unwrap();
    hmac.update(value).unwrap();
    hmac.finalize().unwrap()
}

fn x25519_share(hello: &[u8]) -> &[u8] {
    let mut offset = 39 + usize::from(hello[38]);
    let ciphers = u16::from_be_bytes(hello[offset..offset + 2].try_into().unwrap());
    offset += 2 + usize::from(ciphers);
    offset += 1 + usize::from(hello[offset]);
    offset += 2;
    while offset + 4 <= hello.len() {
        let kind = u16::from_be_bytes(hello[offset..offset + 2].try_into().unwrap());
        let size = usize::from(u16::from_be_bytes(
            hello[offset + 2..offset + 4].try_into().unwrap(),
        ));
        offset += 4;
        if kind == 51 {
            let mut share = offset + 2;
            while share + 4 <= offset + size {
                let group = u16::from_be_bytes(hello[share..share + 2].try_into().unwrap());
                let length = usize::from(u16::from_be_bytes(
                    hello[share + 2..share + 4].try_into().unwrap(),
                ));
                share += 4;
                if group == 0x001d {
                    return &hello[share..share + length];
                }
                share += length;
            }
        }
        offset += size;
    }
    panic!("REALITY ClientHello lacks an X25519 key share");
}

#[tokio::test]
async fn real_client_auth_payload_meets_mihomo_version_and_server_identity_contract() {
    let key = PKey::generate(Id::X25519).unwrap();
    let mut public_key = [0u8; 32];
    key.raw_public_key(&mut public_key).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut header = [0u8; 5];
        stream.read_exact(&mut header).await.unwrap();
        assert_eq!(header[0], 22);
        let mut hello = vec![0; usize::from(u16::from_be_bytes([header[3], header[4]]))];
        stream.read_exact(&mut hello).await.unwrap();
        let mut peer_der = key.public_key_to_der().unwrap();
        let point_offset = peer_der.len() - 32;
        peer_der[point_offset..].copy_from_slice(x25519_share(&hello));
        let peer = PKey::public_key_from_der(&peer_der).unwrap();
        let mut derive = Deriver::new(&key).unwrap();
        derive.set_peer(&peer).unwrap();
        let shared = derive.derive_to_vec().unwrap();
        let random = hello[6..38].to_vec();
        let extract = hmac(&random[..20], &shared);
        let auth = hmac(&extract, b"REALITY\x01");
        let encrypted = hello[39..71].to_vec();
        hello[39..71].fill(0);
        Aes256Gcm::new_from_slice(&auth)
            .unwrap()
            .decrypt(
                Nonce::from_slice(&random[20..]),
                aes_gcm::aead::Payload {
                    msg: &encrypted,
                    aad: &hello,
                },
            )
            .unwrap()
    });
    let mut config = TlsConfig::new("example.test");
    config.fingerprint = Some("chrome".into());
    config.reality = Some(RealityConfig {
        public_key,
        short_id: [0x34; 8],
        support_x25519_mlkem768: false,
    });
    let layer = TlsLayer::new(&config).unwrap();
    let connection = TcpStream::connect(address).await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(5), layer.connect(Box::new(connection)))
            .await
            .unwrap()
            .is_err()
    );
    let plaintext = server.await.unwrap();
    assert_eq!(&plaintext[..4], &[1, 8, 2, 0]);
    assert_eq!(&plaintext[8..], &[0x34; 8]);
    let seconds = u32::from_be_bytes(plaintext[4..8].try_into().unwrap());
    assert!(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            .abs_diff(u64::from(seconds))
            < 10
    );
}
