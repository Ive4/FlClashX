use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use parking_lot::{Mutex, RwLock};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::{HashMap, VecDeque},
    ffi::{c_char, c_int, c_uint, CStr, CString},
    net::{Ipv4Addr, SocketAddr},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, LazyLock,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
};
use tokio_util::sync::CancellationToken;

const OWNER_LIMIT: usize = 64;
const OWNER_TIMEOUT: Duration = Duration::from_millis(500);

#[derive(Clone, Debug, Serialize)]
pub struct OwnerRequest {
    pub id: u32,
    pub protocol: String,
    pub local: String,
    pub remote: String,
}

#[derive(Default)]
struct OwnerState {
    next: u32,
    pending: HashMap<u32, oneshot::Sender<crate::mobile_tun::Owner>>,
    queue: VecDeque<OwnerRequest>,
}

#[derive(Default)]
pub struct OwnerBroker {
    state: Mutex<OwnerState>,
}

struct PendingOwner<'a> {
    broker: &'a OwnerBroker,
    id: u32,
}
impl Drop for PendingOwner<'_> {
    fn drop(&mut self) {
        let mut state = self.broker.state.lock();
        state.pending.remove(&self.id);
        state.queue.retain(|request| request.id != self.id);
    }
}

impl OwnerBroker {
    pub fn take(&self) -> Vec<OwnerRequest> {
        let mut state = self.state.lock();
        let requests = state.queue.drain(..).collect::<Vec<_>>();
        requests
            .into_iter()
            .filter(|request| state.pending.contains_key(&request.id))
            .collect()
    }

    pub fn answer(&self, id: u32, uid: i32, bundle: String) {
        if let Some(sender) = self.state.lock().pending.remove(&id) {
            if uid >= 0 {
                let _ = sender.send(crate::mobile_tun::Owner {
                    uid: uid as u32,
                    package: bundle,
                });
            }
        }
    }

    pub fn clear(&self) {
        let mut state = self.state.lock();
        state.pending.clear();
        state.queue.clear();
    }

    pub async fn lookup(
        &self,
        protocol: u8,
        source: SocketAddr,
        target: SocketAddr,
    ) -> Option<crate::mobile_tun::Owner> {
        if !matches!(protocol, 6 | 17) || source.port() == 0 || target.port() == 0 {
            return None;
        }
        let (pending, receiver) = {
            let mut state = self.state.lock();
            if state.pending.len() >= OWNER_LIMIT || state.queue.len() >= OWNER_LIMIT {
                return None;
            }
            loop {
                state.next = state.next.wrapping_add(1).max(1);
                if !state.pending.contains_key(&state.next) {
                    break;
                }
            }
            let id = state.next;
            let (sender, receiver) = oneshot::channel();
            state.pending.insert(id, sender);
            state.queue.push_back(OwnerRequest {
                id,
                protocol: if protocol == 6 { "tcp" } else { "udp" }.into(),
                local: source.to_string(),
                remote: target.to_string(),
            });
            (PendingOwner { broker: self, id }, receiver)
        };
        let result = tokio::time::timeout(OWNER_TIMEOUT, receiver)
            .await
            .ok()
            .and_then(std::result::Result::ok);
        drop(pending);
        result
    }
}

#[async_trait]
impl crate::mobile_tun::OwnerResolver for OwnerBroker {
    async fn resolve(
        &self,
        protocol: u8,
        source: SocketAddr,
        target: SocketAddr,
    ) -> Option<crate::mobile_tun::Owner> {
        self.lookup(protocol, source, target).await
    }
}

static OWNERS: LazyLock<Arc<OwnerBroker>> = LazyLock::new(|| Arc::new(OwnerBroker::default()));
static CONTROLLER: RwLock<Option<Arc<Controller>>> = RwLock::new(None);

#[derive(Deserialize)]
pub struct RunSettings {
    pub address: String,
    pub token: String,
    #[serde(default)]
    pub control: String,
}

impl RunSettings {
    pub fn validate(&self) -> Result<SocketAddr> {
        let address: SocketAddr = self.address.parse()?;
        if address.ip() != Ipv4Addr::LOCALHOST || address.port() == 0 {
            bail!("Invalid Core loopback endpoint");
        }
        if self.token.len() != 64 || !self.token.bytes().all(|c| c.is_ascii_hexdigit()) {
            bail!("Invalid Core authentication token");
        }
        if !self.control.is_empty() && !Path::new(&self.control).is_absolute() {
            bail!("Core control path must be absolute");
        }
        Ok(address)
    }
}

struct Controller {
    cancel: CancellationToken,
    connected: AtomicBool,
    lightweight: AtomicBool,
    endpoint: SocketAddr,
    token: String,
    control: String,
    metadata: Mutex<()>,
}

impl Controller {
    fn metadata_path(&self) -> Option<PathBuf> {
        if self.control.is_empty() {
            return None;
        }
        Some(
            Path::new(&self.control)
                .parent()?
                .join(".ohos-core-host.json"),
        )
    }

    fn remove_metadata(&self) {
        let _guard = self.metadata.lock();
        let Some(path) = self.metadata_path() else {
            return;
        };
        let Ok(bytes) = std::fs::read(&path) else {
            return;
        };
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            return;
        };
        if value["token"].as_str() == Some(&self.token)
            && value["address"].as_str() == Some(&self.endpoint.to_string())
        {
            let _ = std::fs::remove_file(path);
        }
    }

    fn enter_lightweight(&self, raw: &str) -> Result<()> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Request {
            running_since: Option<i64>,
            tunnel_status: String,
        }
        let request: Request = serde_json::from_str(raw)?;
        if self.cancel.is_cancelled() || !self.connected.load(Ordering::Acquire) {
            bail!("Core is not connected");
        }
        let path = self
            .metadata_path()
            .context("Core has no lightweight control path")?;
        let value = json!({"address":self.endpoint.to_string(), "token":self.token, "control":self.control,
            "runningSince":request.running_since, "tunnelStatus":request.tunnel_status});
        let _guard = self.metadata.lock();
        let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let result = (|| -> Result<()> {
            use std::io::Write;
            let mut file = options.open(&temp)?;
            file.write_all(&serde_json::to_vec(&value)?)?;
            file.sync_all()?;
            std::fs::rename(&temp, &path)?;
            self.lightweight.store(true, Ordering::Release);
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(temp);
        }
        result
    }
}

pub fn token_matches(left: &[u8], right: &[u8]) -> bool {
    if left.len() != 64 || right.len() != 64 {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0u8, |difference, (left, right)| difference | (left ^ right))
        == 0
}

async fn authenticate(stream: &mut TcpStream, token: &str) -> Result<()> {
    let mut header = [0; 4];
    stream.read_exact(&mut header).await?;
    if u32::from_le_bytes(header) != 64 {
        bail!("Invalid Core authentication frame");
    }
    let mut received = [0; 64];
    stream.read_exact(&mut received).await?;
    if !token_matches(&received, token.as_bytes()) {
        bail!("Core authentication failed");
    }
    crate::ipc::write_frame(stream, token.as_bytes()).await?;
    stream.flush().await?;
    Ok(())
}

pub async fn run(raw: &str) -> Result<()> {
    crate::mobile::prepare();
    let settings: RunSettings = serde_json::from_str(raw)?;
    let endpoint = settings.validate()?;
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
    let controller = Arc::new(Controller {
        cancel: CancellationToken::new(),
        connected: AtomicBool::new(false),
        lightweight: AtomicBool::new(false),
        endpoint: listener.local_addr()?,
        token: settings.token,
        control: settings.control,
        metadata: Mutex::new(()),
    });
    {
        let mut current = CONTROLLER.write();
        if current.is_some() {
            bail!("An embedded Core controller is already running");
        }
        *current = Some(controller.clone());
    }
    let result = run_controller(controller.clone(), listener, endpoint).await;
    controller.connected.store(false, Ordering::Release);
    controller.cancel.cancel();
    #[cfg(unix)]
    {
        let _ = crate::mobile_tun::stop().await;
    }
    OWNERS.clear();
    crate::shared_core().shutdown().await;
    controller.remove_metadata();
    let mut current = CONTROLLER.write();
    if current
        .as_ref()
        .is_some_and(|current| Arc::ptr_eq(current, &controller))
    {
        *current = None;
    }
    result
}

async fn run_controller(
    controller: Arc<Controller>,
    listener: TcpListener,
    endpoint: SocketAddr,
) -> Result<()> {
    let mut stream = tokio::select! {
        _ = controller.cancel.cancelled() => return Ok(()),
        result = tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(endpoint)) => result??,
    };
    tokio::select! {
        _ = controller.cancel.cancelled() => return Ok(()),
        result = tokio::time::timeout(Duration::from_secs(10), crate::ipc::write_frame(&mut stream, controller.token.as_bytes())) => result??,
    }
    loop {
        controller.connected.store(true, Ordering::Release);
        let result = crate::ipc::serve(
            crate::shared_core(),
            stream,
            controller.cancel.child_token(),
        )
        .await;
        controller.connected.store(false, Ordering::Release);
        if controller.cancel.is_cancelled() || !controller.lightweight.load(Ordering::Acquire) {
            return result;
        }
        loop {
            let (mut candidate, peer) = tokio::select! {
                _ = controller.cancel.cancelled() => return Ok(()),
                accepted = listener.accept() => accepted?,
            };
            if peer.ip() != Ipv4Addr::LOCALHOST {
                continue;
            }
            let authenticated = tokio::select! {
                _ = controller.cancel.cancelled() => return Ok(()),
                result = tokio::time::timeout(Duration::from_secs(3), authenticate(&mut candidate, &controller.token)) => matches!(result, Ok(Ok(()))),
            };
            if !authenticated {
                continue;
            }
            controller.lightweight.store(false, Ordering::Release);
            controller.remove_metadata();
            stream = candidate;
            break;
        }
    }
}

#[derive(Deserialize)]
struct TunSettings {
    #[serde(default)]
    address: String,
    #[serde(default, rename = "dns")]
    dns: String,
}

pub async fn start_tun(fd: i32, raw: &str) -> Result<()> {
    let controller = CONTROLLER.read().clone().context("Core is not running")?;
    if controller.cancel.is_cancelled() || !controller.connected.load(Ordering::Acquire) {
        bail!("Core is not connected");
    }
    let settings: TunSettings = serde_json::from_str(raw)?;
    let options = crate::mobile_tun::TunOptions::parse(&settings.address, &settings.dns, raw)?;
    #[cfg(unix)]
    {
        let engine = crate::shared_core().active()?;
        crate::mobile_tun::start(fd, engine.state.tunnel.clone(), options, OWNERS.clone()).await?;
        crate::shared_core().route_changed(false);
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = (fd, options);
        bail!("fd-driven TUN requires Unix");
    }
}

fn string_result(value: impl AsRef<str>) -> *mut c_char {
    CString::new(value.as_ref().replace('\0', " "))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn ffi_result(action: impl FnOnce() -> Result<()>) -> *mut c_char {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(action)) {
        Ok(Ok(())) => std::ptr::null_mut(),
        Ok(Err(error)) => string_result(error.to_string()),
        Err(_) => string_result("Embedded Core operation panicked"),
    }
}

unsafe fn input<'a>(value: *const c_char) -> Result<&'a str> {
    if value.is_null() {
        bail!("Missing Core bridge argument");
    }
    Ok(CStr::from_ptr(value).to_str()?)
}

#[no_mangle]
pub unsafe extern "C" fn FlClashRun(settings: *const c_char) -> *mut c_char {
    ffi_result(|| crate::runtime().block_on(run(input(settings)?)))
}

#[no_mangle]
pub unsafe extern "C" fn FlClashFree(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub unsafe extern "C" fn FlClashBackupCodec(request: *const c_char, length: c_int) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if request.is_null() || length <= 0 || length as usize > crate::backup::MAX_WIRE {
            return b"{\"error\":\"tooLarge\"}".to_vec();
        }
        crate::backup::handle(std::slice::from_raw_parts(
            request.cast::<u8>(),
            length as usize,
        ))
    })
    .unwrap_or_else(|_| b"{\"error\":\"internal\"}".to_vec());
    string_result(String::from_utf8_lossy(&result))
}

#[no_mangle]
pub unsafe extern "C" fn FlClashStartTun(fd: c_int, settings: *const c_char) -> *mut c_char {
    ffi_result(|| crate::runtime().block_on(start_tun(fd, input(settings)?)))
}

#[no_mangle]
pub extern "C" fn FlClashStopTun() {
    let error = ffi_result(|| {
        #[cfg(unix)]
        crate::runtime().block_on(crate::mobile_tun::stop())?;
        OWNERS.clear();
        Ok(())
    });
    if !error.is_null() {
        unsafe {
            drop(CString::from_raw(error));
        }
    }
}

#[no_mangle]
pub extern "C" fn FlClashStopCore() {
    let _ = std::panic::catch_unwind(|| {
        if let Some(controller) = CONTROLLER.read().clone() {
            controller.cancel.cancel();
        }
    });
}

#[no_mangle]
pub extern "C" fn FlClashTrimMemory() {
    let _ = std::panic::catch_unwind(|| {
        crate::runtime().spawn_blocking(crate::mobile::trim_memory);
    });
}

#[no_mangle]
pub unsafe extern "C" fn FlClashEnterLightweight(settings: *const c_char) -> *mut c_char {
    ffi_result(|| {
        CONTROLLER
            .read()
            .clone()
            .context("Core is not running")?
            .enter_lightweight(input(settings)?)
    })
}

#[no_mangle]
pub extern "C" fn FlClashTakeOwners() -> *mut c_char {
    std::panic::catch_unwind(|| {
        string_result(serde_json::to_string(&OWNERS.take()).unwrap_or_else(|_| "[]".into()))
    })
    .unwrap_or_else(|_| string_result("[]"))
}

#[no_mangle]
pub unsafe extern "C" fn FlClashResolveOwner(id: c_uint, uid: c_int, bundle: *const c_char) {
    let _ = std::panic::catch_unwind(|| OWNERS.answer(id, uid, input(bundle).unwrap_or("").into()));
}
