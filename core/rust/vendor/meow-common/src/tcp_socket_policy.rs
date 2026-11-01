use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use parking_lot::RwLock;

pub trait TcpSocketPolicy: Send + Sync {
    fn apply(&self, socket: &socket2::Socket) -> io::Result<()>;
}

struct Owner {
    id: u64,
    policy: Arc<dyn TcpSocketPolicy>,
}

static OWNERS: RwLock<Vec<Owner>> = RwLock::new(Vec::new());
static NEXT_OWNER: AtomicU64 = AtomicU64::new(1);

#[must_use = "dropping the guard restores the previous TCP socket policy"]
pub struct TcpSocketPolicyGuard {
    id: u64,
}

impl Drop for TcpSocketPolicyGuard {
    fn drop(&mut self) {
        OWNERS.write().retain(|owner| owner.id != self.id);
    }
}

pub fn install_tcp_socket_policy(policy: Arc<dyn TcpSocketPolicy>) -> TcpSocketPolicyGuard {
    let id = NEXT_OWNER.fetch_add(1, Ordering::Relaxed);
    OWNERS.write().push(Owner { id, policy });
    TcpSocketPolicyGuard { id }
}

pub fn tcp_socket_policy() -> Option<Arc<dyn TcpSocketPolicy>> {
    OWNERS.read().last().map(|owner| Arc::clone(&owner.policy))
}

pub fn apply_tcp_socket_policy(socket: &socket2::Socket) -> io::Result<()> {
    if let Some(policy) = tcp_socket_policy() {
        policy.apply(socket)?;
    }
    Ok(())
}

#[cfg(all(
    test,
    any(target_os = "linux", target_os = "macos", target_os = "windows")
))]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    struct Probe(Arc<AtomicUsize>);

    impl TcpSocketPolicy for Probe {
        fn apply(&self, socket: &socket2::Socket) -> io::Result<()> {
            assert!(socket.peer_addr().is_err());
            self.0.fetch_add(1, Ordering::Relaxed);
            socket.set_keepalive(true)
        }
    }

    #[tokio::test]
    async fn plain_and_interface_bound_tcp_apply_policy_before_connect() {
        let calls = Arc::new(AtomicUsize::new(0));
        let _guard = install_tcp_socket_policy(Arc::new(Probe(Arc::clone(&calls))));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let plain = crate::connect_tcp(address).await.unwrap();
        assert!(socket2::SockRef::from(&plain).keepalive().unwrap());
        let (incoming, _) = listener.accept().await.unwrap();
        drop(incoming);
        let bound = crate::socket_protect::connect_tcp_iface_bound(address)
            .await
            .unwrap();
        assert!(socket2::SockRef::from(&bound).keepalive().unwrap());
        assert_eq!(calls.load(Ordering::Relaxed), 2);
    }
}
