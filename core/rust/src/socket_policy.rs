use crate::protocol::{self, MethodError};
use meow_common::tcp_socket_policy::{
    install_tcp_socket_policy, TcpSocketPolicy, TcpSocketPolicyGuard,
};
use serde_json::{json, Value};
use socket2::{Domain, Protocol, Socket, TcpKeepalive, Type};
use std::{io, sync::Arc, time::Duration};

pub type PolicyGuard = TcpSocketPolicyGuard;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TcpKeepalivePolicy {
    pub enabled: bool,
    pub idle: Duration,
    pub interval: Duration,
}

impl Default for TcpKeepalivePolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            idle: Duration::from_secs(15),
            interval: Duration::from_secs(30),
        }
    }
}

impl TcpKeepalivePolicy {
    pub fn from_document(document: &Value) -> protocol::Result<Self> {
        protocol::object(document)?;
        let defaults = Self::default();
        let enabled = match document.get("disable-keep-alive") {
            None => defaults.enabled,
            Some(value) => !value
                .as_bool()
                .ok_or_else(|| invalid("disable-keep-alive", value, "expected a boolean"))?,
        };
        Ok(Self {
            enabled,
            idle: seconds(document, "keep-alive-idle", defaults.idle)?,
            interval: seconds(document, "keep-alive-interval", defaults.interval)?,
        })
    }

    pub fn check_support(&self) -> io::Result<()> {
        let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
        self.apply_socket(&socket)
    }

    #[cfg(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "windows"
    ))]
    pub fn apply_socket(&self, socket: &Socket) -> io::Result<()> {
        let keepalive = TcpKeepalive::new()
            .with_time(self.idle)
            .with_interval(self.interval);
        socket.set_tcp_keepalive(&keepalive)?;
        socket.set_keepalive(self.enabled)?;
        let actual = Self::read_socket(socket)?;
        if actual != *self {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                format!("TCP keepalive readback {actual:?} differs from requested {self:?}"),
            ));
        }
        Ok(())
    }

    #[cfg(not(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "windows"
    )))]
    pub fn apply_socket(&self, _socket: &Socket) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "TCP keepalive timing is not implemented on this platform",
        ))
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_os = "macos"))]
    pub fn read_socket(socket: &Socket) -> io::Result<Self> {
        Ok(Self {
            enabled: socket.keepalive()?,
            idle: socket.keepalive_time()?,
            interval: socket.keepalive_interval()?,
        })
    }

    #[cfg(target_os = "windows")]
    pub fn read_socket(socket: &Socket) -> io::Result<Self> {
        use windows_sys::Win32::Networking::WinSock::{TCP_KEEPIDLE, TCP_KEEPINTVL};
        Ok(Self {
            enabled: socket.keepalive()?,
            idle: Duration::from_secs(u64::from(windows_tcp_option(socket, TCP_KEEPIDLE)?)),
            interval: Duration::from_secs(u64::from(windows_tcp_option(socket, TCP_KEEPINTVL)?)),
        })
    }
}

impl TcpSocketPolicy for TcpKeepalivePolicy {
    fn apply(&self, socket: &Socket) -> io::Result<()> {
        self.apply_socket(socket)
    }
}

pub fn validate(document: &Value) -> protocol::Result<()> {
    let policy = TcpKeepalivePolicy::from_document(document)?;
    policy.check_support().map_err(|error| {
        MethodError::new(
            "unsupported_config",
            format!("OS rejected outbound TCP keepalive policy: {error}"),
        )
        .details(json!({
            "path": "tcp-keepalive",
            "keep-alive-idle": policy.idle.as_secs(),
            "keep-alive-interval": policy.interval.as_secs(),
            "disable-keep-alive": !policy.enabled,
            "os-error": error.raw_os_error(),
        }))
    })
}

pub fn install(document: &Value) -> anyhow::Result<PolicyGuard> {
    validate(document)?;
    Ok(install_tcp_socket_policy(Arc::new(
        TcpKeepalivePolicy::from_document(document)?,
    )))
}

fn seconds(document: &Value, key: &str, default: Duration) -> protocol::Result<Duration> {
    let Some(value) = document.get(key) else {
        return Ok(default);
    };
    let max = if cfg!(windows) {
        (u64::from(u32::MAX) - 1) / 1000
    } else {
        i32::MAX as u64
    };
    value
        .as_u64()
        .filter(|seconds| *seconds > 0 && *seconds <= max)
        .map(Duration::from_secs)
        .ok_or_else(|| {
            invalid(
                key,
                value,
                "expected positive whole seconds representable by the OS",
            )
        })
}

fn invalid(path: &str, value: &Value, reason: &str) -> MethodError {
    MethodError::new("unsupported_config", format!("Invalid {path}: {reason}"))
        .details(json!({"path": path, "value": value}))
}

#[cfg(target_os = "windows")]
fn windows_tcp_option(socket: &Socket, option: i32) -> io::Result<u32> {
    use std::os::windows::io::AsRawSocket;
    use windows_sys::Win32::Networking::WinSock::{
        getsockopt, WSAGetLastError, IPPROTO_TCP, SOCKET_ERROR,
    };
    let mut value = 0_u32;
    let mut length = std::mem::size_of_val(&value) as i32;
    // Winsock writes a DWORD into a live, aligned buffer of exactly that size.
    let result = unsafe {
        getsockopt(
            socket.as_raw_socket() as _,
            IPPROTO_TCP,
            option,
            (&mut value as *mut u32).cast(),
            &mut length,
        )
    };
    if result == SOCKET_ERROR {
        return Err(io::Error::from_raw_os_error(unsafe { WSAGetLastError() }));
    }
    if length != std::mem::size_of_val(&value) as i32 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Winsock returned a TCP keepalive option with an unexpected length",
        ));
    }
    Ok(value)
}
