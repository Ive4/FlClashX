use crate::{
    engine::Engine,
    events::Events,
    extras, probe, profile,
    protocol::{self, Call, MethodError, Response},
};
use anyhow::Context;
use futures::FutureExt;
use meow_api::log_stream::{LogBroadcastLayer, LogMessage};
use parking_lot::{Mutex as SyncMutex, RwLock};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::{broadcast, Mutex};
use tracing_subscriber::prelude::*;

pub struct Core {
    pub events: Arc<Events>,
    pub engine: RwLock<Option<Arc<Engine>>>,
    pub home: RwLock<PathBuf>,
    pub logs: broadcast::Sender<LogMessage>,
    state: Mutex<State>,
    route: SyncMutex<Route>,
    sequence: AtomicU64,
    traffic: SyncMutex<Traffic>,
    pub updates: SyncMutex<HashSet<String>>,
    test_url: RwLock<String>,
    skip_certificates: std::sync::atomic::AtomicBool,
    geo_schedule: SyncMutex<GeoSchedule>,
}

struct GeoSchedule {
    enabled: bool,
    interval: Duration,
    deadline: std::time::Instant,
}

struct State {
    document: Value,
    listening: bool,
    initialized: bool,
}

#[derive(Default)]
struct Route {
    epoch: u64,
    version: u64,
    watching: bool,
    watch_sequence: u64,
    fingerprint: String,
    providers: HashMap<String, String>,
}

#[derive(Default)]
struct Traffic {
    prior: [(u64, u64); 2],
    speed: [(u64, u64); 2],
    offset: [(u64, u64); 2],
}

impl Core {
    pub fn new() -> Arc<Self> {
        let (logs, mut receiver) = broadcast::channel(256);
        let _ = tracing_subscriber::registry()
            .with(LogBroadcastLayer { tx: logs.clone() })
            .try_init();
        let core = Arc::new(Self {
            events: Arc::new(Events::default()),
            engine: RwLock::new(None),
            home: RwLock::new(PathBuf::new()),
            logs,
            state: Mutex::new(State {
                document: json!({}),
                listening: false,
                initialized: false,
            }),
            route: SyncMutex::new(Route::default()),
            sequence: AtomicU64::new(0),
            traffic: SyncMutex::new(Traffic::default()),
            updates: SyncMutex::new(HashSet::new()),
            test_url: RwLock::new("https://www.gstatic.com/generate_204".into()),
            skip_certificates: std::sync::atomic::AtomicBool::new(false),
            geo_schedule: SyncMutex::new(GeoSchedule {
                enabled: false,
                interval: Duration::from_secs(24 * 3600),
                deadline: std::time::Instant::now(),
            }),
        });
        let weak = Arc::downgrade(&core);
        tokio::spawn(async move {
            loop {
                match receiver.recv().await {
                    Ok(log) => {
                        let Some(core) = weak.upgrade() else {
                            break;
                        };
                        if core.events.logs.load(Ordering::Relaxed) {
                            core.events
                                .push("log", serde_json::to_value(log).unwrap_or(Value::Null));
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => break,
                }
            }
        });
        let weak = Arc::downgrade(&core);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            let mut announced = HashMap::<String, (u64, u64)>::new();
            let mut dns_seen = HashSet::new();
            loop {
                interval.tick().await;
                let Some(core) = weak.upgrade() else {
                    break;
                };
                let engine = core.engine.read().clone();
                let Some(engine) = engine else {
                    announced.clear();
                    dns_seen.clear();
                    continue;
                };
                let counts = traffic_counts(&engine);
                {
                    let mut traffic = core.traffic.lock();
                    for (index, now) in counts.into_iter().enumerate() {
                        traffic.speed[index] = (
                            now.0.saturating_sub(traffic.prior[index].0),
                            now.1.saturating_sub(traffic.prior[index].1),
                        );
                        traffic.prior[index] = now;
                    }
                }
                if core.events.enabled.load(Ordering::Acquire) || core.route.lock().watching {
                    core.refresh_route(&engine, false);
                }
                let geo_due = {
                    let mut schedule = core.geo_schedule.lock();
                    if schedule.enabled && std::time::Instant::now() >= schedule.deadline {
                        schedule.deadline = std::time::Instant::now() + schedule.interval;
                        true
                    } else {
                        false
                    }
                };
                if geo_due {
                    let weak = Arc::downgrade(&core);
                    tokio::spawn(async move {
                        let Some(core) = weak.upgrade() else {
                            return;
                        };
                        for kind in ["MMDB", "ASN", "GEOSITE"] {
                            if let Err(error) = extras::geo(&core, &json!(kind)).await {
                                tracing::warn!("Scheduled {kind} update failed: {error}");
                            }
                        }
                    });
                }
                if !core.events.enabled.load(Ordering::Acquire) {
                    announced.clear();
                    dns_seen.clear();
                    continue;
                }
                let mut connections = engine.state.tunnel.statistics().active_connections();
                connections.extend(
                    engine
                        .state
                        .tunnel
                        .statistics()
                        .recently_closed()
                        .into_iter()
                        .map(|detail| detail.info),
                );
                let mut present = HashSet::new();
                let mut traffic = Vec::new();
                for connection in connections {
                    let Ok(mut value) = serde_json::to_value(connection) else {
                        continue;
                    };
                    extras::normalize_tracker(&mut value);
                    let Some(id) = value["id"].as_str() else {
                        continue;
                    };
                    if !present.insert(id.to_owned()) {
                        continue;
                    }
                    let count = (
                        value["upload"].as_u64().unwrap_or(0),
                        value["download"].as_u64().unwrap_or(0),
                    );
                    match announced.insert(id.to_owned(), count) {
                        None => core.events.push("request", value),
                        Some(previous) if previous != count => {
                            traffic.push(json!({"id":id,"upload":count.0,"download":count.1}))
                        }
                        _ => {}
                    }
                }
                announced.retain(|id, _| present.contains(id));
                if !traffic.is_empty() {
                    core.events.push("requestTraffic", json!(traffic));
                }
                let mut current_dns = HashSet::new();
                for record in engine.state.tunnel.resolver().dns_results(None, 4096) {
                    let key = format!("{}:{:?}", record.name, record.ips);
                    if current_dns.insert(key.clone()) && !dns_seen.contains(&key) {
                        core.events.push("dns", json!({"domain":record.name,"type":if record.ips.first().is_some_and(|ip|ip.is_ipv6()) {"AAAA"} else {"A"},"initiator":null,"upstream":record.source,"answers":record.ips,"cached":true,"delay":0,"time":extras::now_rfc3339()}));
                    }
                }
                dns_seen = current_dns;
            }
        });
        core
    }

    pub fn stamp(&self) -> Value {
        let route = self.route.lock();
        json!({"core-epoch":route.epoch,"route-version":route.version})
    }

    pub fn route_changed(&self, reset: bool) {
        let mut route = self.route.lock();
        if reset {
            route.epoch += 1;
        }
        route.version += 1;
        if route.watching {
            self.events.push(
                "routeChanged",
                json!({"core-epoch":route.epoch,"route-version":route.version}),
            );
        }
    }

    fn refresh_route(&self, engine: &Engine, reset: bool) {
        let fingerprint = extras::route_fingerprint(engine);
        let providers = extras::provider_fingerprints(engine);
        let mut route = self.route.lock();
        for (name, fingerprint) in &providers {
            if route.providers.get(name) != Some(fingerprint) {
                self.events.push("loaded", json!(name));
            }
        }
        route.providers = providers;
        if !reset && route.fingerprint == fingerprint {
            return;
        }
        route.fingerprint = fingerprint;
        if reset {
            route.epoch += 1;
        }
        route.version += 1;
        if route.watching {
            self.events.push(
                "routeChanged",
                json!({"core-epoch":route.epoch,"route-version":route.version}),
            );
        }
    }

    pub fn active(&self) -> protocol::Result<Arc<Engine>> {
        self.engine
            .read()
            .clone()
            .ok_or_else(|| MethodError::new("not_initialized", "No configuration has been applied"))
    }

    pub async fn prepare_mobile_tunnel(&self) -> protocol::Result<Arc<Engine>> {
        let mut state = self.state.lock().await;
        if !state.initialized || !state.listening {
            return Err(MethodError::new(
                "not_initialized",
                "No active listener intent",
            ));
        }
        if let Some(engine) = self.engine.read().clone() {
            return Ok(engine);
        }
        // HarmonyOS attaches TUN before setupConfig; its initial policy must not pass traffic.
        let document = json!({"mode":"rule","rules":["MATCH,REJECT"],"dns":{"enable":true,"nameserver":["rcode://refused"]},"tun":{"enable":false}});
        let home = self.home.read().clone();
        let engine = Engine::create(&document, &home, self.logs.clone()).await?;
        state.document = document;
        *self.engine.write() = Some(Arc::clone(&engine));
        self.refresh_route(&engine, true);
        Ok(engine)
    }

    pub fn next_sequence(&self) -> u64 {
        self.sequence.fetch_add(1, Ordering::AcqRel) + 1
    }

    #[cfg(unix)]
    pub async fn attach_mobile_tunnel(
        &self,
        fd: std::os::fd::RawFd,
        options: crate::mobile_tun::TunOptions,
        owners: Arc<dyn crate::mobile_tun::OwnerResolver>,
    ) -> protocol::Result<()> {
        let state = self.state.lock().await;
        if !state.initialized || !state.listening {
            return Err(MethodError::new(
                "not_initialized",
                "No active listener intent",
            ));
        }
        crate::tun_routes::validate_mobile(&state.document, options.os_routes.as_ref())?;
        let engine = self.active()?;
        crate::mobile_tun::start(fd, engine.state.tunnel.clone(), options, owners).await?;
        Ok(())
    }

    pub async fn document(&self) -> Value {
        self.state.lock().await.document.clone()
    }

    pub async fn reload_current(&self) -> protocol::Result<()> {
        let mut state = self.state.lock().await;
        let document = state.document.clone();
        self.apply(&mut state, document).await
    }

    pub async fn reload_provider(&self, name: &str, rule: bool) -> protocol::Result<()> {
        let state = self.state.lock().await;
        let engine = self.active()?;
        let home = self.home.read().clone();
        let effective = self.effective(
            &state.document,
            state.listening,
            cfg!(any(target_os = "android", target_env = "ohos")),
        )?;
        let old = if !rule {
            let raw = meow_config::parse_raw_yaml(
                &serde_saphyr::to_string(&effective).map_err(anyhow::Error::from)?,
            )?;
            let definition = raw
                .proxy_providers
                .as_ref()
                .and_then(|providers| providers.get(name))
                .context("Provider definition is missing")?;
            let candidate = meow_config::proxy_provider::ProxyProvider::new(
                name,
                definition,
                Some(&home),
                meow_config::effective_ipv6(raw.ipv6),
                true,
                engine.state.provider_dialer_registry.clone(),
            )
            .map_err(anyhow::Error::msg)?;
            if definition.provider_type == "http" {
                let mut local = definition.clone();
                local.provider_type = "file".into();
                local.path = Some(
                    extras::provider_path(self, &state.document["proxy-providers"][name], name)?
                        .to_string_lossy()
                        .into(),
                );
                local.url = None;
                local.proxy = None;
                let source = meow_config::proxy_provider::ProxyProvider::new(
                    name,
                    &local,
                    Some(&home),
                    meow_config::effective_ipv6(raw.ipv6),
                    true,
                    engine.state.provider_dialer_registry.clone(),
                )
                .map_err(anyhow::Error::msg)?;
                source.acquire_initial().await?;
                *candidate.slot.write() = source.proxies();
            } else {
                candidate.acquire_initial().await?;
            }
            engine
                .state
                .proxy_providers
                .insert(name.to_owned(), Arc::new(candidate))
        } else {
            None
        };
        let result = async {
            engine.reload(&effective).await?;
            if state.listening {
                engine.stop_listeners().await;
                engine.start_listeners(&effective).await?;
            }
            Ok::<(), anyhow::Error>(())
        }
        .await;
        if let Err(error) = result {
            if !rule {
                if let Some(old) = old {
                    engine.state.proxy_providers.insert(name.to_owned(), old);
                } else {
                    engine.state.proxy_providers.remove(name);
                }
            }
            return Err(error.into());
        }
        self.refresh_route(&engine, true);
        Ok(())
    }

    pub async fn rebuild_current(&self) -> protocol::Result<()> {
        self.reload_current().await
    }

    pub async fn invoke(&self, input: &[u8], sequence: u64) -> Vec<u8> {
        self.sequence.fetch_max(sequence, Ordering::AcqRel);
        let call: Call = match serde_json::from_slice(input) {
            Ok(call) => call,
            Err(error) => {
                return protocol::encode(Response {
                    id: None,
                    result: Value::Null,
                    error: Some(MethodError::new("invalid_arguments", error)),
                    file: None,
                })
            }
        };
        let result = match std::panic::AssertUnwindSafe(self.dispatch(&call, sequence))
            .catch_unwind()
            .await
        {
            Ok(result) => result,
            Err(_) => Err(MethodError::new(
                "internal_error",
                format!("Internal panic in {}", call.method),
            )),
        };
        let (result, error) = match result {
            Ok(value) => (value, None),
            Err(error) if error.code == "core_error" && protocol::message_method(&call.method) => {
                (json!(error.message), None)
            }
            Err(error) => (Value::Null, Some(error)),
        };
        let response = Response {
            id: call.id.clone(),
            result,
            error,
            file: None,
        };
        let bytes = protocol::encode(response);
        if bytes.len() <= protocol::SPILL_THRESHOLD {
            return bytes;
        }
        let home = self.home.read().clone();
        let spill = profile::spill_path(&home, "json").and_then(|path| {
            profile::StagedFile::bytes(&path, &bytes)?.commit()?;
            Ok(path)
        });
        match spill {
            Ok(path) => protocol::encode(Response {
                id: call.id,
                result: Value::Null,
                error: None,
                file: Some(path.to_string_lossy().into()),
            }),
            Err(error) => protocol::encode(Response {
                id: call.id,
                result: Value::Null,
                error: Some(MethodError::new("response_spill_error", error)),
                file: None,
            }),
        }
    }

    async fn apply(&self, state: &mut State, document: Value) -> protocol::Result<()> {
        if !state.initialized {
            return Err(MethodError::new("core_error", "not initialized"));
        }
        extras::validate(&document)?;
        #[cfg(any(target_os = "android", target_env = "ohos"))]
        crate::mobile_tun::validate_routes(&document).await?;
        extras::preflight_providers(self, &document).await?;
        let home = self.home.read().clone();
        let mobile = cfg!(any(target_os = "android", target_env = "ohos"));
        let effective = self.effective(&document, state.listening, mobile)?;
        let staged = profile::StagedFile::document(&home.join("config.yaml"), &document)?;
        let current = self.engine.read().clone();
        let mut created = None;
        let result = async {
            let engine = if let Some(engine) = &current {
                engine.reload(&effective).await?;
                engine.stop_listeners().await;
                Arc::clone(engine)
            } else {
                let engine = Engine::create(&effective, &home, self.logs.clone()).await?;
                created = Some(Arc::clone(&engine));
                engine
            };
            if state.listening {
                engine.start_listeners(&effective).await?;
            }
            staged.commit()?;
            Ok::<Arc<Engine>, anyhow::Error>(engine)
        }
        .await;
        let engine = match result {
            Ok(engine) => engine,
            Err(error) => {
                if let Some(engine) = created {
                    engine.shutdown().await;
                }
                if let Some(engine) = &current {
                    let rollback = async {
                        engine.stop_listeners().await;
                        let prior = self.effective(&state.document, state.listening, mobile)?;
                        engine.reload(&prior).await?;
                        if state.listening {
                            engine.start_listeners(&prior).await?;
                        }
                        Ok::<(), anyhow::Error>(())
                    }
                    .await;
                    if let Err(rollback) = rollback {
                        let stale = self.engine.write().take();
                        if let Some(stale) = stale {
                            stale.shutdown().await;
                        }
                        state.listening = false;
                        self.route_changed(true);
                        return Err(MethodError::new(
                            "config_rollback_failed",
                            format!("Apply failed: {error:#}; rollback failed: {rollback:#}"),
                        ));
                    }
                    self.route_changed(true);
                }
                return Err(error.into());
            }
        };
        *self.engine.write() = Some(Arc::clone(&engine));
        state.document = document;
        {
            let enabled = state.document["geo-auto-update"]
                .as_bool()
                .or_else(|| state.document["geodata"]["auto-update"].as_bool())
                .unwrap_or(false);
            let hours = state.document["geo-update-interval"]
                .as_u64()
                .or_else(|| state.document["geodata"]["auto-update-interval"].as_u64())
                .unwrap_or(24)
                .clamp(1, 87600);
            let interval = Duration::from_secs(hours * 3600);
            let mut schedule = self.geo_schedule.lock();
            if schedule.enabled != enabled || schedule.interval != interval {
                schedule.deadline = std::time::Instant::now() + interval;
            }
            schedule.enabled = enabled;
            schedule.interval = interval;
        }
        crate::ownership::schedule(&home);
        self.refresh_route(&engine, true);
        self.events.push("loaded", Value::Null);
        Ok(())
    }

    fn effective(&self, document: &Value, listening: bool, mobile: bool) -> anyhow::Result<Value> {
        let mut effective = profile::runtime_document(document, listening, mobile)?;
        extras::runtime_options(&mut effective)?;
        if document["skip-cert-verify"]
            .as_bool()
            .unwrap_or_else(|| self.skip_certificates.load(Ordering::Acquire))
        {
            extras::skip_certificates(&mut effective);
        }
        #[cfg(any(target_os = "android", target_env = "ohos"))]
        crate::mobile::patch_system_dns(&mut effective);
        Ok(effective)
    }

    async fn dispatch(&self, call: &Call, sequence: u64) -> protocol::Result<Value> {
        let a = &call.arguments;
        match call.method.as_str() {
            "initClash" => {
                let home = PathBuf::from(protocol::field(a, "home-dir")?);
                if !home.is_absolute() {
                    return Err(MethodError::new(
                        "invalid_arguments",
                        "Core home must be absolute",
                    ));
                }
                let mut state = self.state.lock().await;
                if !self.home.read().as_os_str().is_empty() && *self.home.read() != home {
                    return Err(MethodError::new(
                        "invalid_arguments",
                        "Core is already initialized with a different home",
                    ));
                }
                if state.initialized {
                    return Ok(json!(true));
                }
                let responses = home.join("responses");
                if responses.is_dir() {
                    for entry in std::fs::read_dir(&responses)
                        .map_err(anyhow::Error::from)?
                        .flatten()
                    {
                        if entry.file_type().is_ok_and(|kind| kind.is_file()) {
                            let _ = std::fs::remove_file(entry.path());
                        }
                    }
                }
                std::fs::create_dir_all(home.join("responses")).map_err(anyhow::Error::from)?;
                crate::ownership::reclaim_path(&home, &home.join("responses"))
                    .map_err(anyhow::Error::from)?;
                *self.home.write() = home;
                state.initialized = true;
                Ok(json!(true))
            }
            "getIsInit" => Ok(json!(self.state.lock().await.initialized)),
            "forceGc" => {
                extras::trim_memory();
                Ok(json!(true))
            }
            "shutdown" => {
                self.shutdown().await;
                Ok(json!(true))
            }
            "getConfig" => Ok(profile::read(protocol::string(a)?)?),
            "getProfileBase" => Ok(profile::base(protocol::string(a)?)?),
            "getProfileOutbounds" => Ok(profile::outbounds(protocol::string(a)?)?),
            "validateConfig" => {
                let document = profile::read(protocol::string(a)?)?;
                extras::validate(&document)?;
                Ok(json!(""))
            }
            "validateProxies" => Ok(json!(protocol::list(a)?
                .iter()
                .map(extras::validate_proxy_message)
                .collect::<Vec<_>>())),
            "validateFilters" => Ok(json!(protocol::list(a)?
                .iter()
                .map(extras::validate_filter_message)
                .collect::<Vec<_>>())),
            "buildProfile" => {
                let home = self.home.read().clone();
                let document = profile::merge(a, &home)?;
                let path = profile::spill_path(&home, "yaml")?;
                profile::write(&path, &document)?;
                Ok(json!(path))
            }
            "setupConfig" => {
                let mut state = self.state.lock().await;
                if !state.initialized {
                    return Err(MethodError::new("core_error", "not initialized"));
                }
                let home = self.home.read().clone();
                let mut document = profile::merge(&a["base"], &home)?;
                let skip = a["skip-cert-verify"].as_bool().unwrap_or(false);
                let url = match a.get("test-url") {
                    None => "https://www.gstatic.com/generate_204",
                    Some(value) => protocol::string(value)?,
                };
                document["skip-cert-verify"] = json!(skip);
                self.apply(&mut state, document).await?;
                self.skip_certificates.store(skip, Ordering::Release);
                if !url.is_empty() {
                    *self.test_url.write() = url.to_owned();
                }
                if let Some(selected) = a["selected-map"].as_object() {
                    let engine = self.active()?;
                    for (group, name) in selected {
                        let Some(name) = name.as_str() else {
                            continue;
                        };
                        if let Ok(proxy) = engine.proxy(group) {
                            if let Some(selection) = proxy.selection() {
                                if let Err(error) = selection.set(name).await {
                                    tracing::warn!("Selection restore failed for {group}: {error}");
                                }
                            }
                        }
                    }
                    self.refresh_route(&engine, false);
                }
                Ok(json!(""))
            }
            "updateConfig" => {
                protocol::object(a)?;
                let mut state = self.state.lock().await;
                self.active()?;
                let mut document = state.document.clone();
                profile::patch(&mut document, a);
                self.apply(&mut state, document).await?;
                if let Some(skip) = a["skip-cert-verify"].as_bool() {
                    self.skip_certificates.store(skip, Ordering::Release);
                }
                Ok(json!(""))
            }
            "startListener" | "stopListener" => {
                let mut state = self.state.lock().await;
                if !state.initialized {
                    return Err(MethodError::new("not_initialized", "not initialized"));
                }
                let running = call.method == "startListener";
                if state.listening == running {
                    return Ok(json!(true));
                }
                let Some(engine) = self.engine.read().clone() else {
                    state.listening = running;
                    if running {
                        self.route_changed(true);
                    }
                    return Ok(json!(true));
                };
                let mobile = cfg!(any(target_os = "android", target_env = "ohos"));
                let effective = self.effective(&state.document, running, mobile)?;
                engine.stop_listeners().await;
                let result = async {
                    engine.reload(&effective).await?;
                    if running {
                        engine.start_listeners(&effective).await?;
                    }
                    Ok::<(), anyhow::Error>(())
                }
                .await;
                if let Err(error) = result {
                    engine.stop_listeners().await;
                    let prior = self.effective(&state.document, state.listening, mobile)?;
                    let restored = async {
                        engine.reload(&prior).await?;
                        if state.listening {
                            engine.start_listeners(&prior).await?;
                        }
                        Ok::<(), anyhow::Error>(())
                    }
                    .await;
                    if let Err(restore) = restored {
                        return Err(MethodError::new(
                            "listener_rollback_failed",
                            format!("{error:#}; rollback: {restore:#}"),
                        ));
                    }
                    return Err(error.into());
                }
                state.listening = running;
                engine.state.tunnel.resolver().reset_connections();
                self.refresh_route(&engine, running);
                Ok(json!(true))
            }
            "getProxies" => {
                if self.engine.read().is_none() {
                    return Ok(json!({"proxies":{},"all":[]}));
                }
                let engine = self.active()?;
                let mut data = engine.api("GET", "/proxies", Value::Null).await?;
                let document = self.document().await;
                let mut names = Vec::new();
                if data["proxies"]["GLOBAL"].is_object() {
                    names.push("GLOBAL".to_owned());
                    let configured = document["proxy-groups"]
                        .as_array()
                        .is_some_and(|groups| groups.iter().any(|group| group["name"] == "GLOBAL"));
                    if !configured {
                        data["proxies"]["GLOBAL"]["hidden"] = json!(true);
                    }
                }
                if let Some(groups) = document["proxy-groups"].as_array() {
                    for group in groups {
                        if let Some(name) = group["name"].as_str() {
                            if name != "GLOBAL" && data["proxies"][name].is_object() {
                                names.push(name.to_owned());
                            }
                        }
                    }
                }
                if let Some(proxies) = data["proxies"].as_object_mut() {
                    for provider in engine.state.proxy_providers.iter() {
                        for proxy in provider.proxies() {
                            proxies.entry(proxy.name().to_owned()).or_insert_with(|| json!({"name":proxy.name(),"type":proxy.adapter_type().to_string(),"provider-name":provider.name}));
                        }
                    }
                }
                data["all"] = json!(names);
                Ok(data)
            }
            "changeProxy" => {
                let _state = self.state.lock().await;
                let engine = self.active()?;
                let group = protocol::field(a, "group-name")?;
                let name = protocol::field(a, "proxy-name")?;
                let result = async {
                    let proxy = engine.proxy(group)?;
                    let before = proxy.current();
                    let selection = proxy.selection().context("Group is not selectable")?;
                    selection.set(name).await.map_err(anyhow::Error::from)?;
                    Ok::<bool, anyhow::Error>(before.as_deref() != Some(name))
                }
                .await;
                match result {
                    Ok(changed) => {
                        self.refresh_route(&engine, false);
                        Ok(json!({"message":"","changed":changed}))
                    }
                    Err(error) => Ok(json!({"message":error.to_string(),"changed":false})),
                }
            }
            "getTraffic" | "getTotalTraffic" => {
                let proxy_only = a.as_bool().ok_or_else(|| {
                    MethodError::new("invalid_arguments", "Expected statistics boolean")
                })?;
                let Some(engine) = self.engine.read().clone() else {
                    return Ok(json!({"up":0,"down":0}));
                };
                let index = usize::from(proxy_only);
                let traffic = self.traffic.lock();
                let (up, down) = if call.method == "getTraffic" {
                    traffic.speed[index]
                } else {
                    let now = traffic_counts(&engine)[index];
                    (
                        now.0.saturating_sub(traffic.offset[index].0),
                        now.1.saturating_sub(traffic.offset[index].1),
                    )
                };
                Ok(json!({"up":up,"down":down}))
            }
            "resetTraffic" => {
                let engine = self.active()?;
                let counts = traffic_counts(&engine);
                let mut traffic = self.traffic.lock();
                traffic.offset = counts;
                traffic.prior = counts;
                traffic.speed = [(0, 0); 2];
                Ok(json!(true))
            }
            "getConnections" => {
                let mut result = self
                    .active()?
                    .api("GET", "/connections", Value::Null)
                    .await?;
                if let Some(connections) = result["connections"].as_array_mut() {
                    for connection in connections {
                        extras::normalize_tracker(connection);
                    }
                }
                Ok(result)
            }
            "getConnectionCount" => Ok(json!(self
                .active()?
                .state
                .tunnel
                .statistics()
                .active_connection_count())),
            "closeConnections" => {
                let engine = self.active()?;
                engine.state.tunnel.statistics().close_all_connections();
                engine.state.tunnel.close_all_udp_sessions();
                Ok(json!(true))
            }
            "resetConnections" => {
                self.active()?.state.tunnel.resolver().reset_connections();
                Ok(json!(true))
            }
            "closeConnection" => {
                let engine = self.active()?;
                let id = protocol::string(a)?
                    .parse()
                    .map_err(|e| MethodError::new("invalid_arguments", e))?;
                let exists = engine
                    .state
                    .tunnel
                    .statistics()
                    .connection_detail(id)
                    .is_some();
                engine.state.tunnel.statistics().close_connection(id);
                Ok(json!(exists))
            }
            "clearDnsCache" => {
                self.active()?.state.tunnel.resolver().clear_cache();
                Ok(json!(true))
            }
            "startLog" | "stopLog" => {
                self.events
                    .logs
                    .store(call.method == "startLog", Ordering::Release);
                Ok(json!(true))
            }
            "getMemoryStats" => Ok(extras::memory_stats().await),
            "watchRoute" => {
                let watch = a.as_bool().ok_or_else(|| {
                    MethodError::new("invalid_arguments", "Expected watch boolean")
                })?;
                if watch {
                    if let Ok(engine) = self.active() {
                        self.refresh_route(&engine, false);
                    }
                }
                let mut route = self.route.lock();
                if sequence >= route.watch_sequence {
                    route.watch_sequence = sequence;
                    route.watching = watch;
                }
                Ok(json!({"core-epoch":route.epoch,"route-version":route.version}))
            }
            "checkRoutes" => {
                let engine = self.active()?;
                let mut result = self.stamp();
                let mut held = Vec::new();
                let mut exits = HashMap::new();
                for route in protocol::list(&a["routes"])? {
                    let route = protocol::list(route)?;
                    let mut valid = !route.is_empty();
                    for hit in route {
                        let host = protocol::field(hit, "host")?;
                        let proxy = hit["proxy"].as_str().unwrap_or("");
                        let expected = protocol::field(hit, "exit")?;
                        let key = (host.to_owned(), proxy.to_owned());
                        if !exits.contains_key(&key) {
                            exits.insert(
                                key.clone(),
                                probe::exit(&engine, host, proxy).await.unwrap_or_default(),
                            );
                        }
                        if exits[&key] != expected {
                            valid = false;
                            break;
                        }
                    }
                    held.push(valid);
                }
                result["held"] = json!(held);
                Ok(result)
            }
            "probe" => {
                let mut stamp = self.stamp();
                let arguments = self.probe_arguments(a);
                let result = match probe::run(self.active()?, &arguments).await {
                    Ok(result) => result,
                    Err(error) => {
                        json!({"status-code":0,"delay":0,"body":"","url":a["url"],"chains":[],"rule":"","rule-payload":"","error":probe::error_kind(&error),"message":format!("{error:#}")})
                    }
                };
                profile::patch(&mut stamp, &result);
                Ok(stamp)
            }
            "asyncTestDelay" => {
                let fallback = self.test_url.read().clone();
                let url = a["test-url"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .unwrap_or(&fallback);
                let name = protocol::field(a, "proxy-name")?;
                let arguments = self.probe_arguments(
                    &json!({"url":url,"proxy-name":name,"timeout":a["timeout"].as_u64().filter(|value|*value>0).unwrap_or(5000),"max-body":0}),
                );
                let result = probe::delay(self.active()?, &arguments).await;
                let value = match result {
                    Err(error) if error.to_string().contains("queue timed out") => {
                        return Ok(Value::Null)
                    }
                    Ok(result) => result["delay"].as_i64().unwrap_or(1).max(1).min(65_535),
                    Err(error) if probe::error_kind(&error) == "timeout" => -1,
                    Err(_) => -2,
                };
                Ok(json!({"url":url,"name":name,"value":value}))
            }
            "getExternalProviders"
            | "getExternalProvider"
            | "updateExternalProvider"
            | "sideLoadExternalProvider" => extras::providers(self, &call.method, a).await,
            "getProxyDefinition" => extras::proxy_definition(self, protocol::string(a)?).await,
            "clearEffect" => {
                extras::clear_effect(self, a).await?;
                Ok(json!(""))
            }
            "convertProxies" | "encodeShareLinks" | "decodeShareLinks" => {
                crate::links::invoke(&call.method, a)
            }
            "decryptConfig" => Ok(json!(extras::decrypt(a)?)),
            "outboundIp" | "serviceCheck" => {
                crate::service_checks::invoke(self, &call.method, a).await
            }
            "dumpRuleSet" | "compileRuleSet" => extras::rule_set(self, &call.method, a).await,
            "updateGeoData" => extras::geo(self, a).await,
            "updateDns" => {
                #[cfg(any(target_os = "android", target_env = "ohos"))]
                {
                    if let Some(value) = a.as_str() {
                        crate::mobile::set_system_dns(value);
                    }
                    if self.engine.read().is_some() {
                        self.reload_current().await?;
                    }
                }
                let Some(engine) = self.engine.read().clone() else {
                    return Ok(json!(true));
                };
                engine.state.tunnel.resolver().reset_connections();
                engine.state.tunnel.resolver().clear_cache();
                Ok(json!(true))
            }
            "crash" => {
                std::process::abort();
            }
            _ => Err(MethodError::new(
                "not_implemented",
                format!("Unknown method: {}", call.method),
            )),
        }
    }

    pub fn probe_arguments(&self, arguments: &Value) -> Value {
        let mut arguments = arguments.clone();
        if !arguments.is_object() {
            arguments = json!({});
        }
        arguments["skip-cert-verify"] = json!(self.skip_certificates.load(Ordering::Acquire));
        arguments
    }

    pub async fn shutdown(&self) {
        let mut state = self.state.lock().await;
        self.events.logs.store(false, Ordering::Release);
        {
            let mut route = self.route.lock();
            route.watch_sequence = self.next_sequence();
            route.watching = false;
        }
        let engine = self.engine.write().take();
        if let Some(engine) = engine {
            engine.shutdown().await;
        }
        state.initialized = false;
        self.geo_schedule.lock().enabled = false;
        state.listening = false;
        state.document = json!({});
        self.events.clear();
        *self.traffic.lock() = Traffic::default();
    }
}

fn traffic_counts(engine: &Engine) -> [(u64, u64); 2] {
    let (up, down) = engine.state.tunnel.statistics().snapshot();
    let mut proxied = (0u64, 0u64);
    for (name, (up, down)) in engine.state.tunnel.statistics().proxy_traffic() {
        if !matches!(name.as_ref(), "DIRECT" | "COMPATIBLE") {
            proxied.0 += up.max(0) as u64;
            proxied.1 += down.max(0) as u64;
        }
    }
    [(up.max(0) as u64, down.max(0) as u64), proxied]
}
