use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use futures::{FutureExt, SinkExt, StreamExt};
use meow_common::{ConnType, Metadata, Network, ProxyPacketConn};
use meow_dns::server::DnsServer;
use meow_tunnel::{ConnectionGuard, PreHandleVerdict, Tunnel};
use serde::Deserialize;
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::{atomic::Ordering, Arc, LazyLock},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::{mpsc, Mutex, Semaphore},
    task::{JoinHandle, JoinSet},
    time::{sleep, Instant},
};
use tokio_util::{sync::CancellationToken, task::TaskTracker};

const MAX_FLOWS: usize = 1024;
const FLOW_QUEUE: usize = 64;
const PACKET_QUEUE: usize = 512;
static STACK_LEASE: LazyLock<Arc<Mutex<()>>> = LazyLock::new(|| Arc::new(Mutex::new(())));

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Owner {
    pub uid: u32,
    pub package: String,
}

#[async_trait]
pub trait OwnerResolver: Send + Sync {
    async fn resolve(&self, protocol: u8, source: SocketAddr, target: SocketAddr) -> Option<Owner>;
}

#[derive(Clone, Debug)]
pub struct TunOptions {
    pub mtu: usize,
    pub addresses: Vec<(IpAddr, u8)>,
    pub dns: Vec<IpAddr>,
    pub udp_timeout: Duration,
}

#[derive(Deserialize)]
struct RawOptions {
    #[serde(default = "default_mtu")]
    mtu: usize,
    #[serde(default = "default_timeout", rename = "udp-timeout")]
    udp_timeout: u64,
}

fn default_mtu() -> usize {
    9000
}
fn default_timeout() -> u64 {
    60
}

impl TunOptions {
    pub fn parse(address: &str, dns: &str, options: &str) -> Result<Self> {
        let raw: RawOptions = serde_json::from_str(if options.trim().is_empty() {
            "{}"
        } else {
            options
        })?;
        if !(576..=65535).contains(&raw.mtu) {
            bail!("TUN MTU must be between 576 and 65535");
        }
        if !(1..=3600).contains(&raw.udp_timeout) {
            bail!("Invalid UDP timeout");
        }
        let mut addresses = Vec::new();
        for value in address.split(',').map(str::trim).filter(|s| !s.is_empty()) {
            let (ip, prefix) = value
                .split_once('/')
                .context("TUN address requires a prefix")?;
            let ip: IpAddr = ip.parse()?;
            let prefix: u8 = prefix.parse()?;
            if prefix > if ip.is_ipv4() { 32 } else { 128 } {
                bail!("Invalid TUN address prefix");
            }
            addresses.push((ip, prefix));
        }
        if addresses.is_empty() {
            bail!("TUN has no addresses");
        }
        let dns = dns
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::parse)
            .collect::<std::result::Result<Vec<IpAddr>, _>>()?;
        Ok(Self {
            mtu: raw.mtu,
            addresses,
            dns,
            udp_timeout: Duration::from_secs(raw.udp_timeout),
        })
    }

    pub fn hijacks_dns(&self, target: SocketAddr) -> bool {
        target.port() == 53
            && self.dns.iter().any(|ip| {
                *ip == target.ip() || (ip.is_unspecified() && ip.is_ipv4() == target.is_ipv4())
            })
    }

    fn loops(&self, ip: IpAddr) -> bool {
        if ip.is_unspecified() || ip.is_multicast() {
            return true;
        }
        match ip {
            IpAddr::V4(ip) => {
                ip == std::net::Ipv4Addr::BROADCAST
                    || self
                        .addresses
                        .iter()
                        .any(|(local, _)| *local == IpAddr::V4(ip))
            }
            IpAddr::V6(ip) => self
                .addresses
                .iter()
                .any(|(local, _)| *local == IpAddr::V6(ip)),
        }
    }
}

pub async fn metadata(
    network: Network,
    source: SocketAddr,
    target: SocketAddr,
    owner: &dyn OwnerResolver,
) -> Metadata {
    let protocol = if network == Network::Tcp { 6 } else { 17 };
    let mut metadata = Metadata {
        network,
        conn_type: ConnType::Tun,
        src_ip: Some(source.ip()),
        src_port: source.port(),
        dst_ip: Some(target.ip()),
        dst_port: target.port(),
        in_name: "FlClash".into(),
        ..Default::default()
    };
    if let Some(owner) = owner.resolve(protocol, source, target).await {
        metadata.uid = Some(owner.uid);
        metadata.process = owner.package.as_str().into();
        metadata.process_path = owner.package.into();
    }
    metadata
}

pub struct PacketSession {
    pub input: mpsc::Sender<Vec<u8>>,
    pub output: mpsc::Receiver<Vec<u8>>,
    cancel: CancellationToken,
    task: Option<JoinHandle<Result<()>>>,
}

impl PacketSession {
    pub fn start(
        tunnel: Tunnel,
        options: TunOptions,
        owners: Arc<dyn OwnerResolver>,
    ) -> Result<Self> {
        let lease = STACK_LEASE
            .clone()
            .try_lock_owned()
            .map_err(|_| anyhow::anyhow!("Previous mobile packet stack is still running"))?;
        let (stack, tcp, udp) = lwip::NetStack::with_buffer_size(PACKET_QUEUE, FLOW_QUEUE)?;
        let mut done = stack.core_done();
        let (input, incoming) = mpsc::channel(PACKET_QUEUE);
        let (outgoing, output) = mpsc::channel(PACKET_QUEUE);
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let task = tokio::spawn(async move {
            let _lease = lease;
            let children = TaskTracker::new();
            let result = std::panic::AssertUnwindSafe(run_stack(
                tunnel,
                options,
                owners,
                stack,
                tcp,
                udp,
                incoming,
                outgoing,
                token,
                children.clone(),
            ))
            .catch_unwind()
            .await;
            children.close();
            children.wait().await;
            done.wait_for(|finished| *finished)
                .await
                .context("lwIP teardown signal closed")?;
            result.unwrap_or_else(|_| Err(anyhow::anyhow!("Mobile packet stack panicked")))
        });
        Ok(Self {
            input,
            output,
            cancel,
            task: Some(task),
        })
    }

    pub fn is_finished(&self) -> bool {
        self.task.as_ref().is_none_or(JoinHandle::is_finished)
    }

    pub async fn stop(&mut self) -> Result<()> {
        self.cancel.cancel();
        if let Some(task) = self.task.take() {
            task.await.context("Mobile packet stack panicked")??;
        }
        Ok(())
    }
}

impl Drop for PacketSession {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_stack(
    tunnel: Tunnel,
    options: TunOptions,
    owners: Arc<dyn OwnerResolver>,
    stack: lwip::NetStack,
    mut tcp: lwip::TcpListener,
    udp: Box<lwip::UdpSocket>,
    mut incoming: mpsc::Receiver<Vec<u8>>,
    outgoing: mpsc::Sender<Vec<u8>>,
    cancel: CancellationToken,
    children: TaskTracker,
) -> Result<()> {
    let (mut writer, mut reader) = stack.split();
    let mut tasks = JoinSet::<Result<()>>::new();
    let ingress_cancel = cancel.clone();
    tasks.spawn(async move {
        let result = async {
            while let Some(packet) = incoming.recv().await {
                if packet.len() > 65535 {
                    continue;
                }
                writer.send(packet).await?;
            }
            Ok(())
        }
        .await;
        ingress_cancel.cancel();
        result
    });
    let egress_cancel = cancel.clone();
    tasks.spawn(async move {
        let result = async {
            while let Some(packet) = reader.next().await {
                if outgoing.send(packet?).await.is_err() {
                    break;
                }
            }
            Ok(())
        }
        .await;
        egress_cancel.cancel();
        result
    });
    tasks.spawn(run_udp(
        tunnel.clone(),
        options.clone(),
        owners.clone(),
        udp,
        children,
    ));
    let permits = Arc::new(Semaphore::new(MAX_FLOWS));
    let result = loop {
        tokio::select! {
            _ = cancel.cancelled() => break Ok(()),
            accepted = tcp.next() => match accepted {
                Some((mut stream, source, target)) => {
                    if options.loops(target.ip()) && !options.hijacks_dns(target) { continue; }
                    let Ok(permit) = permits.clone().try_acquire_owned() else { continue; };
                    let tunnel = tunnel.clone();
                    let owners = owners.clone();
                    let hijack = options.hijacks_dns(target);
                    tasks.spawn(async move {
                        let _permit = permit;
                        if hijack { return tcp_dns(&mut stream, &tunnel).await; }
                        let metadata = metadata(Network::Tcp, source, target, owners.as_ref()).await;
                        let mut prefix = [0u8; 8192];
                        let size = match tokio::time::timeout(Duration::from_millis(200), stream.read(&mut prefix)).await {
                            Ok(Ok(0)) => return Ok(()),
                            Ok(Ok(size)) => size,
                            Ok(Err(error)) => return Err(error.into()),
                            Err(_) => 0,
                        };
                        meow_tunnel::route_inbound_tcp(tunnel.inner(), &mut stream, metadata, &prefix[..size]).await;
                        Ok(())
                    });
                }
                None => break Err(anyhow::anyhow!("lwIP TCP listener closed")),
            },
            completed = tasks.join_next() => match completed {
                Some(Err(error)) => break Err(error.into()),
                Some(Ok(Err(error))) => tracing::debug!("Mobile flow ended: {error}"),
                _ => {}
            }
        }
    };
    drop(tcp);
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    result
}

async fn tcp_dns(stream: &mut lwip::TcpStream, tunnel: &Tunnel) -> Result<()> {
    loop {
        let length = match stream.read_u16().await {
            Ok(length) if length > 0 => length as usize,
            Ok(_) => bail!("Empty DNS TCP query"),
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error.into()),
        };
        let mut request = vec![0; length];
        stream.read_exact(&mut request).await?;
        let response = tokio::time::timeout(
            Duration::from_secs(10),
            DnsServer::handle_query(&request, &tunnel.resolver()),
        )
        .await?
        .map_err(anyhow::Error::from_boxed)?;
        let size: u16 = response.len().try_into()?;
        stream.write_u16(size).await?;
        stream.write_all(&response).await?;
        stream.flush().await?;
    }
}

type FlowKey = (SocketAddr, SocketAddr);
type Reply = (Vec<u8>, SocketAddr, SocketAddr);
struct Flow {
    input: mpsc::Sender<Vec<u8>>,
    last: Arc<parking_lot::Mutex<Instant>>,
    cancel: CancellationToken,
}

async fn run_udp(
    tunnel: Tunnel,
    options: TunOptions,
    owners: Arc<dyn OwnerResolver>,
    socket: Box<lwip::UdpSocket>,
    children: TaskTracker,
) -> Result<()> {
    let (writer, mut reader) = socket.split();
    let (reply, mut replies) = mpsc::channel::<Reply>(PACKET_QUEUE);
    let mut flows: HashMap<FlowKey, Flow> = HashMap::new();
    let mut tasks = JoinSet::<Result<()>>::new();
    let dns_permits = Arc::new(Semaphore::new(64));
    let mut sweep = tokio::time::interval(Duration::from_secs(5));
    loop {
        tokio::select! {
            received = reader.next() => {
                let Some((packet, source, target)) = received else { return Ok(()); };
                if options.hijacks_dns(target) {
                    let Ok(permit) = dns_permits.clone().try_acquire_owned() else { continue; };
                    let reply = reply.clone();
                    let resolver = tunnel.resolver();
                    tasks.spawn(children.track_future(async move {
                        let _permit = permit;
                        let response = tokio::time::timeout(Duration::from_secs(10), DnsServer::handle_query(&packet, &resolver)).await?.map_err(anyhow::Error::from_boxed)?;
                        let _ = reply.send((response, target, source)).await;
                        Ok(())
                    }));
                    continue;
                }
                if options.loops(target.ip()) { continue; }
                let key = (source, target);
                if let Some(flow) = flows.get(&key) {
                    *flow.last.lock() = Instant::now();
                    match flow.input.try_send(packet.clone()) {
                        Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => continue,
                        Err(mpsc::error::TrySendError::Closed(_)) => {}
                    }
                    flows.remove(&key);
                }
                if flows.len() >= MAX_FLOWS {
                    if let Some(oldest) = flows.iter().min_by_key(|(_, flow)| *flow.last.lock()).map(|(key, _)| *key) {
                        if let Some(flow) = flows.remove(&oldest) { flow.cancel.cancel(); }
                    }
                }
                let (input, incoming) = mpsc::channel(FLOW_QUEUE);
                let _ = input.try_send(packet);
                let last = Arc::new(parking_lot::Mutex::new(Instant::now()));
                let cancel = CancellationToken::new();
                flows.insert(key, Flow { input, last: last.clone(), cancel: cancel.clone() });
                let tunnel = tunnel.clone();
                let owners = owners.clone();
                let reply = reply.clone();
                let timeout = options.udp_timeout;
                let descendants = children.clone();
                tasks.spawn(children.track_future(async move {
                    tokio::select! {
                        _ = cancel.cancelled() => Ok(()),
                        result = relay_udp(tunnel, owners, key, incoming, reply, timeout, last, descendants) => result,
                    }
                }));
            }
            Some((packet, source, target)) = replies.recv() => {
                if let Err(error) = writer.send_to(&packet, &source, &target) {
                    if error.kind() != std::io::ErrorKind::WouldBlock { return Err(error.into()); }
                }
            }
            _ = sweep.tick() => flows.retain(|_, flow| !flow.input.is_closed()),
            Some(result) = tasks.join_next() => {
                if let Ok(Err(error)) = result { tracing::debug!("Mobile UDP flow ended: {error}"); }
            }
        }
    }
}

struct UdpConnection(Arc<dyn ProxyPacketConn>);
impl Drop for UdpConnection {
    fn drop(&mut self) {
        let _ = self.0.close();
    }
}

#[allow(clippy::too_many_arguments)]
async fn relay_udp(
    tunnel: Tunnel,
    owners: Arc<dyn OwnerResolver>,
    (source, target): FlowKey,
    mut incoming: mpsc::Receiver<Vec<u8>>,
    reply: mpsc::Sender<Reply>,
    timeout: Duration,
    last: Arc<parking_lot::Mutex<Instant>>,
    children: TaskTracker,
) -> Result<()> {
    let mut metadata = metadata(Network::Udp, source, target, owners.as_ref()).await;
    let inner = tunnel.inner();
    if matches!(
        inner.pre_handle_metadata(&mut metadata),
        PreHandleVerdict::Drop
    ) {
        return Ok(());
    }
    inner.pre_resolve(&mut metadata).await;
    if metadata.dst_ip.is_none() && !metadata.host.is_empty() {
        metadata.dst_ip = inner.resolver().resolve_ip_real(&metadata.host).await;
    }
    let destination = SocketAddr::new(
        metadata.dst_ip.context("UDP destination did not resolve")?,
        metadata.dst_port,
    );
    let route = inner
        .resolve_proxy(&metadata)
        .await
        .context("No UDP route matched")?;
    let mut flush = inner.udp_flush_watch();
    let guard = ConnectionGuard::track(
        tunnel.statistics(),
        metadata.clone(),
        route.rule_name.clone(),
        route.rule_payload.clone(),
        std::iter::once(Arc::<str>::from(route.adapter.name())).collect(),
    );
    let Some(conn) = guard
        .run_until_closed(tokio::time::timeout(
            Duration::from_secs(10),
            inner.dial_udp(route.adapter.as_ref(), &metadata),
        ))
        .await
    else {
        return Ok(());
    };
    let conn = UdpConnection(Arc::from(conn??));
    drop(route);
    let conn_read = conn.0.clone();
    let (answers, mut received) = mpsc::channel(FLOW_QUEUE);
    let mut tasks = JoinSet::new();
    tasks.spawn(children.track_future(async move {
        let mut buffer = vec![0; 65535];
        while let Ok((size, _)) = conn_read.read_packet(&mut buffer).await {
            if answers.send(buffer[..size].to_vec()).await.is_err() {
                break;
            }
        }
    }));
    let idle = sleep(timeout);
    tokio::pin!(idle);
    let result = guard
        .run_until_closed(async {
            loop {
                tokio::select! {
                    _ = &mut idle => break,
                    _ = flush.flushed() => break,
                    packet = incoming.recv() => {
                        let Some(packet) = packet else { break; };
                        conn.0.write_packet(&packet, &destination).await?;
                        guard.counters().upload.fetch_add(packet.len() as _, Ordering::Relaxed);
                        *last.lock() = Instant::now();
                        idle.as_mut().reset(Instant::now() + timeout);
                    }
                    packet = received.recv() => {
                        let Some(packet) = packet else { break; };
                        guard.counters().download.fetch_add(packet.len() as _, Ordering::Relaxed);
                        if reply.send((packet, target, source)).await.is_err() { break; }
                        *last.lock() = Instant::now();
                        idle.as_mut().reset(Instant::now() + timeout);
                    }
                }
            }
            Ok(())
        })
        .await
        .unwrap_or(Ok(()));
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    result
}

#[cfg(unix)]
mod fd {
    use super::*;
    use std::{
        io,
        os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
    };
    use tokio::io::unix::AsyncFd;

    struct Running {
        cancel: CancellationToken,
        task: JoinHandle<Result<()>>,
    }
    static ACTIVE: Mutex<Option<Running>> = Mutex::const_new(None);

    pub async fn start(
        fd: RawFd,
        tunnel: Tunnel,
        options: TunOptions,
        owners: Arc<dyn OwnerResolver>,
    ) -> Result<()> {
        let mut active = ACTIVE.lock().await;
        stop_locked(&mut active).await?;
        if fd < 0 {
            bail!("Invalid VPN file descriptor");
        }
        let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
        if duplicate < 0 {
            return Err(io::Error::last_os_error().into());
        }
        let owned = unsafe { OwnedFd::from_raw_fd(duplicate) };
        let flags = unsafe { libc::fcntl(owned.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(owned.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err(io::Error::last_os_error().into());
        }
        let device = Arc::new(AsyncFd::new(owned)?);
        let mut session = PacketSession::start(tunnel, options, owners)?;
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let task = tokio::spawn(async move {
            let mut pumps = JoinSet::<Result<()>>::new();
            let incoming = device.clone();
            let input = session.input.clone();
            pumps.spawn(async move {
                let mut buffer = vec![0u8; 65535];
                loop {
                    let size = read(&incoming, &mut buffer).await?;
                    if size == 0 {
                        bail!("VPN descriptor closed");
                    }
                    input
                        .send(buffer[..size].to_vec())
                        .await
                        .context("Mobile packet stack closed")?;
                }
            });
            let mut output = std::mem::replace(&mut session.output, mpsc::channel(1).1);
            pumps.spawn(async move {
                while let Some(packet) = output.recv().await {
                    write(&device, &packet).await?;
                }
                bail!("Mobile packet stack closed");
            });
            let result = tokio::select! {
                _ = token.cancelled() => Ok(()),
                completed = pumps.join_next() => match completed {
                    Some(Ok(result)) => result,
                    Some(Err(error)) => Err(error.into()),
                    None => Ok(()),
                },
            };
            pumps.abort_all();
            while pumps.join_next().await.is_some() {}
            let stopped = session.stop().await;
            result.and(stopped)
        });
        *active = Some(Running { cancel, task });
        Ok(())
    }

    async fn read(device: &AsyncFd<OwnedFd>, buffer: &mut [u8]) -> io::Result<usize> {
        loop {
            let mut ready = device.readable().await?;
            match ready.try_io(|fd| {
                let size = unsafe {
                    libc::read(
                        fd.get_ref().as_raw_fd(),
                        buffer.as_mut_ptr().cast(),
                        buffer.len(),
                    )
                };
                if size < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(size as usize)
                }
            }) {
                Ok(result) => return result,
                Err(_) => continue,
            }
        }
    }

    async fn write(device: &AsyncFd<OwnedFd>, packet: &[u8]) -> io::Result<()> {
        loop {
            let mut ready = device.writable().await?;
            match ready.try_io(|fd| {
                let size = unsafe {
                    libc::write(
                        fd.get_ref().as_raw_fd(),
                        packet.as_ptr().cast(),
                        packet.len(),
                    )
                };
                if size < 0 {
                    Err(io::Error::last_os_error())
                } else if size as usize != packet.len() {
                    Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "Partial VPN packet write",
                    ))
                } else {
                    Ok(())
                }
            }) {
                Ok(result) => return result,
                Err(_) => continue,
            }
        }
    }

    async fn stop_locked(active: &mut Option<Running>) -> Result<()> {
        if let Some(running) = active.take() {
            running.cancel.cancel();
            if let Err(error) = running.task.await.context("VPN task panicked")? {
                tracing::debug!("VPN stopped: {error}");
            }
        }
        Ok(())
    }

    pub async fn stop() -> Result<()> {
        stop_locked(&mut *ACTIVE.lock().await).await
    }
}

#[cfg(unix)]
pub use fd::{start, stop};
