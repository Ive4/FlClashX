use anyhow::{bail, Result};
use parking_lot::RwLock;
use serde_json::{json, Value};
use std::{
    net::IpAddr,
    sync::{
        atomic::{AtomicU64, Ordering},
        LazyLock,
    },
};

static SYSTEM_DNS: LazyLock<RwLock<Vec<String>>> = LazyLock::new(|| RwLock::new(Vec::new()));
static DNS_REVISION: AtomicU64 = AtomicU64::new(0);

#[path = "mobile_procfs.rs"]
pub mod procfs;

pub fn prepare() {
    meow_common::process_lookup::enable_inbound_process_info();
}

pub fn set_system_dns(value: &str) {
    let mut servers = Vec::new();
    for ip in value
        .split(',')
        .map(str::trim)
        .filter_map(|s| s.parse::<IpAddr>().ok())
    {
        let server = match ip {
            IpAddr::V4(ip) => format!("udp://{ip}:53"),
            IpAddr::V6(ip) => format!("udp://[{ip}]:53"),
        };
        if !servers.contains(&server) {
            servers.push(server);
        }
    }
    *SYSTEM_DNS.write() = servers;
    DNS_REVISION.fetch_add(1, Ordering::AcqRel);
}

pub fn patch_system_dns(document: &mut Value) {
    fn replace(value: &mut Value, servers: &[String]) {
        match value {
            Value::Array(entries) => {
                let mut result = Vec::new();
                for mut entry in std::mem::take(entries) {
                    if matches!(entry.as_str(), Some("system" | "system://")) {
                        if servers.is_empty() {
                            result.push(json!("rcode://refused"));
                        } else {
                            result.extend(servers.iter().map(|server| json!(server)));
                        }
                    } else {
                        replace(&mut entry, servers);
                        result.push(entry);
                    }
                }
                *entries = result;
            }
            Value::Object(entries) => {
                for entry in entries.values_mut() {
                    replace(entry, servers);
                }
            }
            Value::String(value) if matches!(value.as_str(), "system" | "system://") => {
                *value = servers
                    .first()
                    .cloned()
                    .unwrap_or_else(|| "rcode://refused".into());
            }
            _ => {}
        }
    }
    if let Some(dns) = document.get_mut("dns") {
        let servers = SYSTEM_DNS.read();
        for field in [
            "nameserver",
            "fallback",
            "default-nameserver",
            "proxy-server-nameserver",
            "direct-nameserver",
            "nameserver-policy",
        ] {
            if let Some(value) = dns.get_mut(field) {
                replace(value, &servers);
            }
        }
    }
}

pub async fn invoke_value(method: &str, arguments: Value) -> Result<Value> {
    let core = crate::shared_core();
    let request = serde_json::to_vec(&json!({"method":method, "arguments":arguments}))?;
    let mut response: Value =
        serde_json::from_slice(&core.invoke(&request, core.next_sequence()).await)?;
    if let Some(path) = response["file"].as_str() {
        let file = tokio::fs::read(path).await?;
        response = serde_json::from_slice(&file)?;
    }
    if let Some(error) = response.get("error").filter(|error| !error.is_null()) {
        bail!(
            "{}",
            error["message"].as_str().unwrap_or("Core method failed")
        );
    }
    Ok(response["result"].take())
}

pub async fn quick_setup(init: &str, setup: &str) -> Result<()> {
    prepare();
    invoke_value("initClash", serde_json::from_str(init)?).await?;
    let result = invoke_value("setupConfig", serde_json::from_str(setup)?).await?;
    if let Some(message) = result.as_str().filter(|message| !message.is_empty()) {
        bail!("{message}");
    }
    invoke_value("startListener", Value::Null).await?;
    Ok(())
}

pub async fn update_dns(value: &str) -> Result<()> {
    invoke_value("updateDns", json!(value)).await?;
    Ok(())
}

pub fn trim_memory() {
    if let Ok(engine) = crate::shared_core().active() {
        engine.state.tunnel.resolver().clear_cache();
    }
}

#[cfg(target_os = "android")]
mod android {
    use super::*;
    use crate::mobile_tun::{Owner, OwnerResolver, TunOptions};
    use async_trait::async_trait;
    use futures::FutureExt;
    use jni::{
        objects::{GlobalRef, JByteArray, JClass, JObject, JString, JValue},
        sys::{jboolean, jbyteArray, jint, jstring, JNI_FALSE, JNI_TRUE, JNI_VERSION_1_6},
        JNIEnv, JavaVM,
    };
    use std::{
        io,
        net::SocketAddr,
        os::fd::{AsRawFd, FromRawFd, OwnedFd},
        panic::{catch_unwind, AssertUnwindSafe},
        sync::{atomic::AtomicI32, Arc},
        time::Duration,
    };
    use tokio::{sync::Mutex, task::JoinHandle};
    use tokio_util::sync::CancellationToken;

    struct Callback {
        vm: JavaVM,
        object: GlobalRef,
    }
    static TUN: RwLock<Option<Arc<Callback>>> = RwLock::new(None);
    static EVENTS: Mutex<Option<(CancellationToken, JoinHandle<()>)>> = Mutex::const_new(None);
    static SDK_LEVEL: AtomicI32 = AtomicI32::new(29);

    impl Callback {
        fn new(env: &JNIEnv, object: JObject) -> jni::errors::Result<Arc<Self>> {
            Ok(Arc::new(Self {
                vm: env.get_java_vm()?,
                object: env.new_global_ref(object)?,
            }))
        }

        fn call<T>(
            &self,
            action: impl FnOnce(&mut JNIEnv, &JObject) -> jni::errors::Result<T>,
        ) -> Option<T> {
            let mut env = self.vm.attach_current_thread().ok()?;
            let result = catch_unwind(AssertUnwindSafe(|| {
                env.with_local_frame(16, |env| action(env, self.object.as_obj()))
            }));
            let pending = env.exception_check().unwrap_or(true);
            if pending {
                let _ = env.exception_clear();
            }
            match result {
                Ok(Ok(value)) if !pending => Some(value),
                _ => None,
            }
        }

        fn result(&self, bytes: &[u8]) {
            self.call(|env, handler| {
                let data = JObject::from(env.byte_array_from_slice(bytes)?);
                env.call_method(handler, "onResult", "([B)V", &[JValue::Object(&data)])?;
                Ok(())
            });
        }
    }

    struct Protector;
    impl meow_common::socket_protect::SocketProtector for Protector {
        fn protect(&self, fd: i32) -> io::Result<()> {
            let callback = TUN.read().clone();
            let Some(callback) = callback else {
                return Ok(());
            };
            if callback
                .call(|env, handler| {
                    env.call_method(handler, "protect", "(I)Z", &[JValue::Int(fd)])?
                        .z()
                })
                .unwrap_or(false)
            {
                Ok(())
            } else {
                Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "VPN socket protection was rejected",
                ))
            }
        }
    }

    #[async_trait]
    impl OwnerResolver for Callback {
        async fn resolve(
            &self,
            protocol: u8,
            source: SocketAddr,
            target: SocketAddr,
        ) -> Option<Owner> {
            let uid = self
                .call(|env, handler| {
                    let source = JObject::from(env.new_string(source.to_string())?);
                    let target = JObject::from(env.new_string(target.to_string())?);
                    env.call_method(
                        handler,
                        "resolveUid",
                        "(ILjava/lang/String;Ljava/lang/String;)I",
                        &[
                            JValue::Int(protocol as i32),
                            JValue::Object(&source),
                            JValue::Object(&target),
                        ],
                    )?
                    .i()
                })
                .unwrap_or(-1);
            let uid = if uid >= 0 {
                Some(uid)
            } else if SDK_LEVEL.load(Ordering::Acquire) < 29 {
                procfs::lookup_socket_uid(protocol, source, target)
                    .and_then(|uid| i32::try_from(uid).ok())
            } else {
                None
            }?;
            let package = self
                .call(|env, handler| {
                    let object = env
                        .call_method(
                            handler,
                            "resolvePackage",
                            "(I)Ljava/lang/String;",
                            &[JValue::Int(uid)],
                        )?
                        .l()?;
                    if object.is_null() {
                        Ok(String::new())
                    } else {
                        Ok(env.get_string(&JString::from(object))?.into())
                    }
                })
                .unwrap_or_default();
            Some(Owner {
                uid: uid as u32,
                package,
            })
        }
    }

    fn export<T>(
        env: &mut JNIEnv,
        fallback: T,
        action: impl FnOnce(&mut JNIEnv) -> jni::errors::Result<T>,
    ) -> T {
        let result = catch_unwind(AssertUnwindSafe(|| action(env)));
        let pending = env.exception_check().unwrap_or(true);
        if pending {
            let _ = env.exception_clear();
        }
        match result {
            Ok(Ok(value)) if !pending => value,
            _ => fallback,
        }
    }

    fn text(env: &mut JNIEnv, value: &JString) -> jni::errors::Result<String> {
        Ok(env.get_string(value)?.into())
    }

    #[no_mangle]
    pub extern "system" fn JNI_OnLoad(vm: JavaVM, _: *mut std::ffi::c_void) -> jint {
        let result = catch_unwind(|| {
            if let Ok(mut env) = vm.get_env() {
                let sdk = export(&mut env, 29, |env| {
                    env.get_static_field("android/os/Build$VERSION", "SDK_INT", "I")?
                        .i()
                });
                SDK_LEVEL.store(sdk, Ordering::Release);
            }
            prepare();
            meow_common::socket_protect::set_socket_protector(Arc::new(Protector));
        });
        if result.is_ok() {
            JNI_VERSION_1_6
        } else {
            -1
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_backupCodec(
        mut env: JNIEnv,
        _: JClass,
        request: JByteArray,
    ) -> jbyteArray {
        export(&mut env, std::ptr::null_mut(), |env| {
            let bytes = env.convert_byte_array(request)?;
            Ok(env
                .byte_array_from_slice(&crate::backup::handle(&bytes))?
                .into_raw())
        })
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_invokeMethod(
        mut env: JNIEnv,
        _: JClass,
        request: JString,
        callback: JObject,
    ) {
        export(&mut env, (), |env| {
            prepare();
            let request = text(env, &request)?;
            let callback = Callback::new(env, callback)?;
            let core = crate::shared_core();
            let sequence = core.next_sequence();
            crate::runtime().spawn(async move {
                let result = AssertUnwindSafe(core.invoke(request.as_bytes(), sequence)).catch_unwind().await;
                callback.result(&result.unwrap_or_else(|_| b"{\"error\":{\"code\":\"internal_error\",\"message\":\"Core method panicked\"}}".to_vec()));
            });
            Ok(())
        });
    }

    async fn set_events(callback: Option<Arc<Callback>>) {
        let mut current = EVENTS.lock().await;
        if let Some((cancel, task)) = current.take() {
            cancel.cancel();
            let _ = task.await;
        }
        let core = crate::shared_core();
        core.events
            .enabled
            .store(callback.is_some(), Ordering::Release);
        let Some(callback) = callback else {
            let _ = invoke_value("watchRoute", json!(false)).await;
            return;
        };
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let task = tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_millis(16));
            loop {
                tokio::select! {
                    _ = token.cancelled() => return,
                    _ = interval.tick() => if let Some(batch) = core.events.batch() { callback.result(&batch); }
                }
            }
        });
        *current = Some((cancel, task));
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_setEventListener(
        mut env: JNIEnv,
        _: JClass,
        callback: JObject,
    ) {
        export(&mut env, (), |env| {
            let callback = if callback.is_null() {
                None
            } else {
                Some(Callback::new(env, callback)?)
            };
            crate::runtime().block_on(set_events(callback));
            Ok(())
        });
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_quickSetup(
        mut env: JNIEnv,
        _: JClass,
        init: JString,
        setup: JString,
        callback: JObject,
    ) {
        export(&mut env, (), |env| {
            let init = text(env, &init)?;
            let setup = text(env, &setup)?;
            let callback = Callback::new(env, callback)?;
            crate::runtime().spawn(async move {
                let message = match AssertUnwindSafe(quick_setup(&init, &setup))
                    .catch_unwind()
                    .await
                {
                    Ok(Ok(())) => String::new(),
                    Ok(Err(error)) => error.to_string(),
                    Err(_) => "Core setup panicked".into(),
                };
                callback.result(message.as_bytes());
            });
            Ok(())
        });
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_startTun(
        mut env: JNIEnv,
        _: JClass,
        fd: jint,
        handler: JObject,
        stack: JString,
        address: JString,
        dns: JString,
        options: JString,
    ) -> jboolean {
        if fd < 0 {
            return JNI_FALSE;
        }
        let owned = unsafe { OwnedFd::from_raw_fd(fd) };
        export(&mut env, JNI_FALSE, |env| {
            let _ = text(env, &stack)?;
            let address = text(env, &address)?;
            let dns = text(env, &dns)?;
            let options = text(env, &options)?;
            let callback = Callback::new(env, handler)?;
            let result = crate::runtime().block_on(async {
                let options = TunOptions::parse(&address, &dns, &options)?;
                let core = crate::shared_core();
                let engine = core.active()?;
                *TUN.write() = Some(callback.clone());
                let result = crate::mobile_tun::start(
                    owned.as_raw_fd(),
                    engine.state.tunnel.clone(),
                    options,
                    callback,
                )
                .await;
                if result.is_ok() {
                    if let Err(error) = invoke_value("startListener", Value::Null).await {
                        let _ = crate::mobile_tun::stop().await;
                        *TUN.write() = None;
                        return Err(error);
                    }
                    let _ = invoke_value("resetConnections", Value::Null).await;
                    core.route_changed(false);
                } else {
                    *TUN.write() = None;
                }
                result
            });
            if let Err(error) = &result {
                tracing::error!("Mobile TUN start failed: {error}");
            }
            Ok(if result.is_ok() { JNI_TRUE } else { JNI_FALSE })
        })
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_stopTun(
        mut env: JNIEnv,
        _: JClass,
    ) {
        export(&mut env, (), |_| {
            crate::runtime().block_on(async {
                let _ = crate::mobile_tun::stop().await;
                let _ = invoke_value("stopListener", Value::Null).await;
                *TUN.write() = None;
            });
            Ok(())
        });
    }

    fn listener(env: &mut JNIEnv, running: bool) {
        export(env, (), |_| {
            let result = crate::runtime().block_on(invoke_value(
                if running {
                    "startListener"
                } else {
                    "stopListener"
                },
                Value::Null,
            ));
            if let Err(error) = result {
                tracing::error!("Mobile listener change failed: {error}");
            }
            Ok(())
        });
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_startListener(
        mut env: JNIEnv,
        _: JClass,
    ) {
        listener(&mut env, true);
    }
    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_stopListener(
        mut env: JNIEnv,
        _: JClass,
    ) {
        listener(&mut env, false);
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_updateDns(
        mut env: JNIEnv,
        _: JClass,
        value: JString,
    ) {
        export(&mut env, (), |env| {
            let value = text(env, &value)?;
            set_system_dns(&value);
            let revision = DNS_REVISION.load(Ordering::Acquire);
            crate::runtime().spawn(async move {
                if revision == DNS_REVISION.load(Ordering::Acquire) {
                    if let Err(error) = invoke_value("updateDns", Value::Null).await {
                        tracing::debug!("Mobile DNS update deferred: {error}");
                    }
                }
            });
            Ok(())
        });
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_resetNetwork(
        mut env: JNIEnv,
        _: JClass,
    ) {
        export(&mut env, (), |_| {
            crate::runtime().spawn(async {
                let _ = invoke_value("resetConnections", Value::Null).await;
                if let Ok(engine) = crate::shared_core().active() {
                    engine.state.tunnel.resolver().clear_cache();
                }
                crate::shared_core().route_changed(false);
            });
            Ok(())
        });
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_forceGC(
        mut env: JNIEnv,
        _: JClass,
    ) {
        export(&mut env, (), |_| {
            crate::runtime().spawn_blocking(trim_memory);
            Ok(())
        });
    }

    fn traffic(env: &mut JNIEnv, total: bool, only_proxy: jboolean) -> jstring {
        export(env, std::ptr::null_mut(), |env| {
            let data = crate::runtime()
                .block_on(invoke_value(
                    if total {
                        "getTotalTraffic"
                    } else {
                        "getTraffic"
                    },
                    json!(only_proxy != JNI_FALSE),
                ))
                .unwrap_or_else(|_| json!({"up":0,"down":0}));
            Ok(env.new_string(data.to_string())?.into_raw())
        })
    }

    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_getTraffic(
        mut env: JNIEnv,
        _: JClass,
        only_proxy: jboolean,
    ) -> jstring {
        traffic(&mut env, false, only_proxy)
    }
    #[no_mangle]
    pub extern "system" fn Java_com_follow_clash_core_mobile_Mobile_getTotalTraffic(
        mut env: JNIEnv,
        _: JClass,
        only_proxy: jboolean,
    ) -> jstring {
        traffic(&mut env, true, only_proxy)
    }
}
