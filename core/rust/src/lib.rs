pub const ENGINE: &str = "meow-rs";
pub const ENGINE_VERSION: &str = "0.28.0";

pub mod backup;
pub mod core;
pub mod direct_dns;
pub mod dns_http3;
pub mod engine;
pub mod events;
pub mod extras;
pub mod ipc;
mod legacy_defaults;
pub mod links;
pub mod mobile;
pub mod mobile_tun;
pub mod ohos;
pub mod ownership;
pub mod probe;
pub mod profile;
pub mod protocol;
pub mod service_checks;
pub mod socket_policy;
pub mod tun_routes;

use std::sync::{Arc, OnceLock};

pub fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("Core runtime")
    })
}

pub fn shared_core() -> Arc<core::Core> {
    static CORE: OnceLock<Arc<core::Core>> = OnceLock::new();
    Arc::clone(CORE.get_or_init(|| {
        let _runtime = runtime().enter();
        if cfg!(any(target_os = "android", target_env = "ohos")) {
            mobile::prepare();
        }
        core::Core::new()
    }))
}
