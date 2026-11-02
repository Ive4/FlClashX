use crate::protocol::{self, MethodError};
use anyhow::{bail, Context, Result};
use boring::{
    ssl::{SslContextBuilder, SslMethod, SslVerifyMode},
    x509::{store::X509StoreBuilder, verify::X509CheckFlags, X509},
};
use meow_common::{ConnType, Metadata, Network, ProxyPacketConn};
use meow_dns::client::preferred_doh::{self, DohRequest, PreferredDohTransport};
use parking_lot::Mutex;
use quiche::h3::{Header, NameValue};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, SocketAddr},
    sync::{Arc, OnceLock},
    time::{Duration, Instant},
};
use tokio::net::UdpSocket;

pub type PolicyGuard = preferred_doh::PreferredDohGuard;

pub fn validate(document: &Value) -> protocol::Result<bool> {
    match document["dns"].get("prefer-h3") {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(value) => Err(MethodError::new(
            "unsupported_config",
            "dns.prefer-h3 must be a boolean",
        )
        .details(json!({"path":"dns.prefer-h3","value":value}))),
    }
}

pub fn install(document: &Value) -> Result<PolicyGuard> {
    let transport = validate(document)?
        .then(|| Arc::new(Http3Transport::default()) as Arc<dyn PreferredDohTransport>);
    Ok(preferred_doh::install(transport))
}

#[derive(Default)]
struct Http3Transport {
    retry_after: Mutex<HashMap<String, Instant>>,
    #[cfg(test)]
    extra_roots: Vec<Vec<u8>>,
}

#[async_trait::async_trait]
impl PreferredDohTransport for Http3Transport {
    async fn exchange(&self, request: DohRequest<'_>) -> io::Result<Vec<u8>> {
        let key = format!(
            "{}|{}|{}|{}",
            request.address,
            request.server_name,
            request.path,
            request.proxy.map(|proxy| proxy.name()).unwrap_or("")
        );
        if self
            .retry_after
            .lock()
            .get(&key)
            .is_some_and(|deadline| *deadline > Instant::now())
        {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "HTTP/3 retry deferred",
            ));
        }
        let result =
            tokio::time::timeout(Duration::from_millis(1200), self.exchange_inner(request))
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "HTTP/3 attempt timed out"))
                .and_then(|result| result.map_err(io::Error::other));
        if result.is_err() {
            let mut retries = self.retry_after.lock();
            let now = Instant::now();
            retries.retain(|_, deadline| *deadline > now);
            if retries.len() >= 256 {
                retries.clear();
            }
            retries.insert(key, now + Duration::from_secs(30));
        }
        result
    }
}

impl Http3Transport {
    async fn exchange_inner(&self, request: DohRequest<'_>) -> Result<Vec<u8>> {
        if request.wire.len() > u16::MAX as usize || request.wire.len() < 12 {
            bail!("Invalid DoH request length");
        }
        let server_name = if request.server_name.is_empty() {
            request.address.ip().to_string()
        } else {
            request.server_name.trim_matches(['[', ']']).to_owned()
        };
        let socket = Datagram::connect(&request).await?;
        let local = socket.local_addr()?;
        let peer = request.address;
        let mut config = self.configuration()?;
        let scid = rand::random::<[u8; 20]>();
        let mut connection = quiche::connect(
            server_name
                .parse::<IpAddr>()
                .is_err()
                .then_some(server_name.as_str()),
            &quiche::ConnectionId::from_ref(&scid),
            local,
            peer,
            &mut config,
        )?;
        let mut h3_config = quiche::h3::Config::new()?;
        h3_config.set_max_field_section_size(16384);
        let mut http3 = None;
        let mut stream = None;
        let mut sent = 0;
        let mut response = Http3Response::default();
        let mut incoming = [0_u8; 65535];
        let mut outgoing = [0_u8; 1350];
        loop {
            if connection.is_established() && http3.is_none() {
                verify_peer_name(&connection, &server_name)?;
                http3 = Some(quiche::h3::Connection::with_transport(
                    &mut connection,
                    &h3_config,
                )?);
            }
            if let Some(http3) = &mut http3 {
                if stream.is_none() {
                    let host = if server_name.parse::<std::net::Ipv6Addr>().is_ok() {
                        format!("[{server_name}]")
                    } else {
                        server_name.clone()
                    };
                    let authority = if request.address.port() == 443 {
                        host
                    } else {
                        format!("{}:{}", host, request.address.port())
                    };
                    let headers = [
                        Header::new(b":method", b"POST"),
                        Header::new(b":scheme", b"https"),
                        Header::new(b":authority", authority.as_bytes()),
                        Header::new(b":path", request.path.as_bytes()),
                        Header::new(b"content-type", b"application/dns-message"),
                        Header::new(b"accept", b"application/dns-message"),
                        Header::new(b"content-length", request.wire.len().to_string().as_bytes()),
                    ];
                    match http3.send_request(&mut connection, &headers, false) {
                        Ok(id) => stream = Some(id),
                        Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => {}
                        Err(error) => return Err(error.into()),
                    }
                }
                if let Some(id) = stream {
                    if sent < request.wire.len() {
                        match http3.send_body(&mut connection, id, &request.wire[sent..], true) {
                            Ok(size) => sent += size,
                            Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => {}
                            Err(error) => return Err(error.into()),
                        }
                    }
                    loop {
                        match http3.poll(&mut connection) {
                            Ok((response_id, event)) if response_id == id => match event {
                                quiche::h3::Event::Headers { list, .. } => {
                                    response.headers(&list)?
                                }
                                quiche::h3::Event::Data => loop {
                                    match http3.recv_body(&mut connection, id, &mut incoming) {
                                        Ok(0) => break,
                                        Ok(size) => response.data(&incoming[..size])?,
                                        Err(quiche::h3::Error::Done) => break,
                                        Err(error) => return Err(error.into()),
                                    }
                                },
                                quiche::h3::Event::Finished => return response.finish(),
                                quiche::h3::Event::Reset(code) => bail!("DoH stream reset: {code}"),
                                _ => {}
                            },
                            Ok(_) => {}
                            Err(quiche::h3::Error::Done) => break,
                            Err(error) => return Err(error.into()),
                        }
                    }
                }
            }
            loop {
                match connection.send(&mut outgoing) {
                    Ok((size, info)) => {
                        if info.at > Instant::now() {
                            tokio::time::sleep_until(info.at.into()).await;
                        }
                        socket.send(&outgoing[..size], peer).await?;
                    }
                    Err(quiche::Error::Done) => break,
                    Err(error) => return Err(error.into()),
                }
            }
            if connection.is_closed() {
                bail!("HTTP/3 connection closed before response completion");
            }
            let timeout = connection.timeout().unwrap_or(Duration::from_millis(1200));
            match tokio::time::timeout(timeout, socket.recv(&mut incoming)).await {
                Ok(Ok(size)) => {
                    connection.recv(
                        &mut incoming[..size],
                        quiche::RecvInfo {
                            from: peer,
                            to: local,
                        },
                    )?;
                }
                Ok(Err(error)) => return Err(error.into()),
                Err(_) => connection.on_timeout(),
            }
        }
    }

    fn configuration(&self) -> Result<quiche::Config> {
        let mut store = X509StoreBuilder::new()?;
        static ROOTS: OnceLock<std::result::Result<Vec<X509>, String>> = OnceLock::new();
        let roots = ROOTS.get_or_init(|| {
            webpki_root_certs::TLS_SERVER_ROOT_CERTS
                .iter()
                .map(|cert| X509::from_der(cert.as_ref()).map_err(|error| error.to_string()))
                .collect()
        });
        for cert in roots
            .as_ref()
            .map_err(|error| anyhow::anyhow!(error.clone()))?
        {
            store.add_cert(cert.clone())?;
        }
        #[cfg(test)]
        for cert in &self.extra_roots {
            store.add_cert(X509::from_der(cert)?)?;
        }
        let mut tls = SslContextBuilder::new(SslMethod::tls())?;
        tls.set_cert_store_builder(store);
        tls.set_verify(SslVerifyMode::PEER);
        let mut config =
            quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, tls)?;
        config.verify_peer(true);
        config.set_application_protos(quiche::h3::APPLICATION_PROTOCOL)?;
        config.set_max_idle_timeout(1500);
        config.set_max_recv_udp_payload_size(1350);
        config.set_max_send_udp_payload_size(1350);
        config.set_initial_max_data(256 * 1024);
        config.set_initial_max_stream_data_bidi_local(128 * 1024);
        config.set_initial_max_stream_data_bidi_remote(128 * 1024);
        config.set_initial_max_stream_data_uni(32 * 1024);
        config.set_initial_max_streams_bidi(1);
        config.set_initial_max_streams_uni(3);
        config.set_disable_active_migration(true);
        Ok(config)
    }
}

fn verify_peer_name(connection: &quiche::Connection, name: &str) -> Result<()> {
    let cert = X509::from_der(
        connection
            .peer_cert()
            .context("HTTP/3 peer certificate missing")?,
    )?;
    let valid = if let Ok(ip) = name.parse::<IpAddr>() {
        cert.check_ip_asc(&ip.to_string())?
    } else {
        cert.check_host_with_flags(name, X509CheckFlags::NO_PARTIAL_WILDCARDS)?
    };
    if !valid {
        bail!("HTTP/3 certificate does not match upstream name");
    }
    Ok(())
}

enum Datagram {
    Direct(UdpSocket),
    Proxy(Box<dyn ProxyPacketConn>),
}

impl Datagram {
    async fn connect(request: &DohRequest<'_>) -> Result<Self> {
        if let Some(proxy) = request.proxy {
            if !proxy.support_udp() {
                bail!("Selected DNS proxy does not support HTTP/3 datagrams");
            }
            let (host, port) = request.proxy_target.unwrap_or(("", request.address.port()));
            let metadata = Metadata {
                network: Network::Udp,
                conn_type: ConnType::Tunnel,
                dst_ip: host.is_empty().then_some(request.address.ip()),
                dst_port: port,
                host: host.into(),
                internal: true,
                ..Default::default()
            };
            return Ok(Self::Proxy(proxy.dial_udp(&metadata).await?));
        }
        let bind = if request.address.is_ipv6() {
            "[::]:0"
        } else {
            "0.0.0.0:0"
        };
        let socket = meow_common::bind_udp(bind.parse::<SocketAddr>()?).await?;
        socket.connect(request.address).await?;
        Ok(Self::Direct(socket))
    }

    fn local_addr(&self) -> Result<SocketAddr> {
        match self {
            Self::Direct(socket) => Ok(socket.local_addr()?),
            Self::Proxy(socket) => Ok(socket.local_addr()?),
        }
    }

    async fn send(&self, packet: &[u8], peer: SocketAddr) -> Result<()> {
        let size = match self {
            Self::Direct(socket) => socket.send(packet).await?,
            Self::Proxy(socket) => socket.write_packet(packet, &peer).await?,
        };
        if size != packet.len() {
            bail!("Partial HTTP/3 datagram write");
        }
        Ok(())
    }

    async fn recv(&self, packet: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Direct(socket) => socket.recv(packet).await,
            Self::Proxy(socket) => socket
                .read_packet(packet)
                .await
                .map(|(size, _)| size)
                .map_err(io::Error::other),
        }
    }
}

impl Drop for Datagram {
    fn drop(&mut self) {
        if let Self::Proxy(socket) = self {
            let _ = socket.close();
        }
    }
}

#[derive(Default)]
struct Http3Response {
    accepted: bool,
    length: Option<usize>,
    body: Vec<u8>,
}

impl Http3Response {
    fn headers(&mut self, headers: &[Header]) -> Result<()> {
        if self.accepted {
            bail!("Unexpected DoH trailing headers");
        }
        let status = matching_headers(headers, b":status");
        let mime = matching_headers(headers, b"content-type");
        if status.len() != 1 || status[0].value() != b"200" || mime.len() != 1 {
            bail!("Invalid DoH response status or content type");
        }
        if !std::str::from_utf8(mime[0].value())?
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .eq_ignore_ascii_case("application/dns-message")
        {
            bail!("Invalid DoH response content type");
        }
        let lengths = matching_headers(headers, b"content-length");
        if lengths.len() > 1 {
            bail!("Duplicate DoH content length");
        }
        self.length = lengths
            .first()
            .map(|header| {
                std::str::from_utf8(header.value())?
                    .parse::<usize>()
                    .map_err(anyhow::Error::from)
            })
            .transpose()?;
        if self.length.is_some_and(|length| length > u16::MAX as usize) {
            bail!("DoH body exceeds DNS wire limit");
        }
        self.accepted = true;
        Ok(())
    }

    fn data(&mut self, bytes: &[u8]) -> Result<()> {
        if !self.accepted || self.body.len() + bytes.len() > u16::MAX as usize {
            bail!("Invalid DoH response body");
        }
        self.body.extend_from_slice(bytes);
        Ok(())
    }

    fn finish(self) -> Result<Vec<u8>> {
        if !self.accepted
            || self.body.len() < 12
            || self.length.is_some_and(|length| length != self.body.len())
        {
            bail!("Incomplete DoH response");
        }
        Ok(self.body)
    }
}

fn matching_headers<'a>(headers: &'a [Header], name: &[u8]) -> Vec<&'a Header> {
    headers
        .iter()
        .filter(|header| header.name() == name)
        .collect()
}

#[cfg(test)]
mod tests;
