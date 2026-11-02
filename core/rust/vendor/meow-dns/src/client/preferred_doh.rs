use super::DnsProxy;
use parking_lot::RwLock;
use std::{
    io,
    net::SocketAddr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
};

pub struct DohRequest<'a> {
    pub address: SocketAddr,
    pub server_name: &'a str,
    pub path: &'a str,
    pub wire: &'a [u8],
    pub proxy: Option<&'a DnsProxy>,
    pub proxy_target: Option<(&'a str, u16)>,
}

#[async_trait::async_trait]
pub trait PreferredDohTransport: Send + Sync {
    async fn exchange(&self, request: DohRequest<'_>) -> io::Result<Vec<u8>>;
}

struct Owner {
    id: u64,
    transport: Option<Arc<dyn PreferredDohTransport>>,
}

static OWNERS: RwLock<Vec<Owner>> = RwLock::new(Vec::new());
static NEXT_OWNER: AtomicU64 = AtomicU64::new(1);

#[must_use = "dropping the guard restores the previous DoH preference"]
pub struct PreferredDohGuard {
    id: u64,
}

impl Drop for PreferredDohGuard {
    fn drop(&mut self) {
        OWNERS.write().retain(|owner| owner.id != self.id);
    }
}

pub fn install(transport: Option<Arc<dyn PreferredDohTransport>>) -> PreferredDohGuard {
    let id = NEXT_OWNER.fetch_add(1, Ordering::Relaxed);
    OWNERS.write().push(Owner { id, transport });
    PreferredDohGuard { id }
}

pub fn current() -> Option<Arc<dyn PreferredDohTransport>> {
    OWNERS
        .read()
        .last()
        .and_then(|owner| owner.transport.clone())
}
