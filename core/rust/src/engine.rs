use anyhow::{anyhow, bail, Context, Result};
use axum::{
    body::{to_bytes, Body},
    extract::State,
    http::{header, Method, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    Json, Router,
};
use dashmap::DashMap;
use meow_api::{
    log_stream::LogMessage,
    routes::{AppState, DnsServerHandle},
};
use meow_common::Proxy;
use meow_config::{ListenerSpec, NamedListener};
use meow_listener::{ListenerTasks, ShadowsocksListener, SnifferRuntime, SsObfsMode};
#[cfg(not(any(target_os = "android", target_env = "ohos")))]
use meow_listener::{TunListener, TunReady};
use meow_tunnel::{ProcessLookupMode, Tunnel};
use parking_lot::RwLock;
use serde_json::{json, Value};
use std::{collections::HashMap, path::Path, sync::Arc};
use subtle::ConstantTimeEq;
use tokio::{
    net::TcpListener,
    sync::{broadcast, Mutex},
    task::JoinHandle,
};
use tower::ServiceExt;

pub struct Engine {
    pub state: Arc<AppState>,
    pub router: Router,
    tasks: Mutex<Tasks>,
    interface_binding: RwLock<Option<meow_common::OutboundIfaceGuard>>,
    socket_policy: RwLock<Option<crate::socket_policy::PolicyGuard>>,
    dns_http3: RwLock<Option<crate::dns_http3::PolicyGuard>>,
}

#[derive(Default)]
struct Tasks(Vec<JoinHandle<()>>, ListenerTasks);

impl Tasks {
    async fn stop(mut self) {
        for task in &self.0 {
            task.abort();
        }
        for task in std::mem::take(&mut self.0) {
            let _ = task.await;
        }
        self.1.shutdown().await;
    }
}

impl Drop for Tasks {
    fn drop(&mut self) {
        self.1.cancel();
        for task in &self.0 {
            task.abort();
        }
    }
}

fn process_lookup_mode(document: &Value) -> Result<ProcessLookupMode> {
    match document.get("find-process-mode").and_then(Value::as_str) {
        None | Some("strict") => Ok(ProcessLookupMode::Strict),
        Some("off") => Ok(ProcessLookupMode::Off),
        Some("always") => Ok(ProcessLookupMode::Always),
        Some(value) => bail!("Invalid find-process-mode: {value}"),
    }
}

impl Engine {
    pub async fn create(
        document: &Value,
        home: &Path,
        logs: broadcast::Sender<LogMessage>,
    ) -> Result<Arc<Self>> {
        let process_lookup = process_lookup_mode(document)?;
        crate::direct_dns::validate(document)?;
        meow_common::home_dir::set_home_dir(home.to_owned());
        meow_config::set_external_plugins_allowed(false);
        crate::ownership::schedule(home);
        let socket_policy = crate::socket_policy::install(document)?;
        let dns_http3 = crate::dns_http3::install(document)?;
        let interface_binding = outbound_binding(document)?;
        let raw = meow_config::parse_raw_yaml(&serde_saphyr::to_string(document)?)?;
        let config = meow_config::build_config(raw, Some(home)).await?;
        let tunnel = Tunnel::new_with_slot(Arc::clone(&config.dns.resolver_slot));
        tunnel.set_dialer_registry(config.provider_dialer_registry.clone());
        tunnel.set_mode(config.general.mode);
        tunnel.set_connection_notes(config.general.connection_notes);
        tunnel.set_process_lookup_mode(process_lookup);
        tunnel.update_routing(config.proxies, config.rules, config.dialer_registry);
        tunnel.spawn_background_tasks();
        if config.dns.enabled || cfg!(any(target_os = "android", target_env = "ohos")) {
            meow_common::set_host_resolver(Arc::new(
                meow_dns::ResolverHostHook::new_with_proxy_resolver(
                    Arc::clone(&config.dns.resolver),
                    config.dns.proxy_resolver.clone(),
                ),
            ));
        }
        let proxy_providers = Arc::new(
            config
                .proxy_providers
                .into_iter()
                .collect::<DashMap<_, _>>(),
        );
        meow_config::proxy_provider::spawn_deferred_initial_fetches(&proxy_providers);
        let rule_providers = Arc::new(RwLock::new(config.rule_providers));
        let rule_refresh =
            Arc::new(meow_config::rule_provider_refresh::RefreshSupervisor::default());
        let proxy_refresh = Arc::new(
            meow_config::proxy_provider_refresh::ProxyProviderRefreshSupervisor::default(),
        );
        rule_refresh.reconcile(&rule_providers);
        proxy_refresh.reconcile(&proxy_providers, config.raw.proxy_providers.as_ref());
        tunnel.reconcile_health_checks(&meow_config::extract_health_check_specs(
            config.raw.proxy_groups.as_deref().unwrap_or(&[]),
        ));
        let state = Arc::new(AppState {
            tunnel,
            secret: None,
            config_path: Some(home.join("config.yaml").to_string_lossy().into()),
            raw_config: Arc::new(RwLock::new(config.raw)),
            log_tx: logs,
            proxy_providers,
            rule_providers,
            rule_provider_refresh: rule_refresh,
            proxy_provider_refresh: proxy_refresh,
            listeners: config.listeners.named,
            external_ui: config.api.external_ui,
            traffic_feed: Default::default(),
            dns_server: Arc::new(RwLock::new(None)),
            provider_dialer_registry: config.provider_dialer_registry,
        });
        if let Some(binding) = &interface_binding {
            binding.commit();
        }
        Ok(Arc::new(Self {
            router: meow_api::routes::create_router(Arc::clone(&state)),
            state,
            tasks: Mutex::new(Tasks::default()),
            interface_binding: RwLock::new(interface_binding),
            socket_policy: RwLock::new(Some(socket_policy)),
            dns_http3: RwLock::new(Some(dns_http3)),
        }))
    }

    pub async fn api(&self, method: &str, path: &str, body: Value) -> Result<Value> {
        let mut request = Request::builder()
            .method(method)
            .uri(path)
            .header("content-type", "application/json");
        if let Some(secret) = &self.state.secret {
            request = request.header("authorization", format!("Bearer {secret}"));
        }
        let bytes = if body.is_null() {
            Vec::new()
        } else {
            serde_json::to_vec(&body)?
        };
        let response = self
            .router
            .clone()
            .oneshot(request.body(Body::from(bytes))?)
            .await?;
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 64 * 1024 * 1024).await?;
        if !status.is_success() {
            bail!(
                "meow-rs {method} {path}: {}",
                String::from_utf8_lossy(&bytes)
            );
        }
        if bytes.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&bytes).context("Decode meow-rs response")
    }

    pub async fn reload(&self, document: &Value) -> Result<()> {
        use base64::Engine as _;
        let process_lookup = process_lookup_mode(document)?;
        crate::direct_dns::validate(document)?;
        let socket_policy = crate::socket_policy::install(document)?;
        let dns_http3 = crate::dns_http3::install(document)?;
        let interface_binding = outbound_binding(document)?;
        let mut routing = document.clone();
        routing["tun"] = json!({"enable": false});
        let yaml = serde_saphyr::to_string(&routing)?;
        self.api(
            "PUT",
            "/configs",
            json!({"payload": base64::engine::general_purpose::STANDARD.encode(yaml)}),
        )
        .await?;
        self.state.tunnel.set_process_lookup_mode(process_lookup);
        if let Some(home) = meow_common::meow_home_dir() {
            crate::ownership::schedule(&home);
        }
        if let Some(binding) = &interface_binding {
            binding.commit();
        }
        *self.interface_binding.write() = interface_binding;
        *self.socket_policy.write() = Some(socket_policy);
        *self.dns_http3.write() = Some(dns_http3);
        Ok(())
    }

    pub async fn start_listeners(&self, document: &Value) -> Result<()> {
        let raw = meow_config::parse_raw_yaml(&serde_saphyr::to_string(document)?)?;
        let named = meow_config::resolve_named_listeners(&raw)?;
        let auth = listener_auth(&raw)?;
        let sniffer_config = meow_config::load_config_from_str(&serde_saphyr::to_string(&json!({
            "sniffer": document["sniffer"], "tproxy-sni": document["tproxy-sni"], "strict": true,
        }))?)
        .await?
        .sniffer;
        let mut staged = Tasks::default();
        let result = async {
            let sniffer = Arc::new(SnifferRuntime::new(sniffer_config));
            for listener in named {
                match Self::bind_listener(
                    &self.state.tunnel,
                    listener,
                    Arc::clone(&sniffer),
                    Arc::clone(&auth),
                    raw.routing_mark,
                    staged.1.clone(),
                )
                .await
                {
                    Ok(task) => staged.0.push(task),
                    Err(error) => return Err(error),
                }
            }
            if let Some(address) = raw
                .dns
                .as_ref()
                .filter(|dns| dns.enable == Some(true))
                .and_then(|dns| dns.listen.as_deref())
                .filter(|s| !s.is_empty())
            {
                let address = address.parse()?;
                if self.state.dns_server.read().is_none() {
                    let server = meow_dns::DnsServer::new(self.state.tunnel.resolver(), address);
                    let resolver_slot = server.resolver_slot();
                    let bound = server.bind().await?;
                    let task = tokio::spawn(async move {
                        if let Err(error) = bound.run().await {
                            tracing::error!("DNS listener failed: {error}");
                        }
                    });
                    *self.state.dns_server.write() = Some(DnsServerHandle {
                        listen: address,
                        task,
                        resolver_slot,
                    });
                }
            }
            if let Some(address) = raw.external_controller.as_deref().filter(|s| !s.is_empty()) {
                anyhow::ensure!(
                    raw.secret.as_ref().is_some_and(|secret| !secret.is_empty()),
                    "External controller requires a secret"
                );
                let socket = TcpListener::bind(address).await?;
                let state = &self.state;
                let external = Arc::new(AppState {
                    tunnel: state.tunnel.clone(),
                    secret: raw.secret.clone(),
                    config_path: state.config_path.clone(),
                    raw_config: Arc::clone(&state.raw_config),
                    log_tx: state.log_tx.clone(),
                    proxy_providers: Arc::clone(&state.proxy_providers),
                    rule_providers: Arc::clone(&state.rule_providers),
                    provider_dialer_registry: state.provider_dialer_registry.clone(),
                    rule_provider_refresh: Arc::clone(&state.rule_provider_refresh),
                    proxy_provider_refresh: Arc::clone(&state.proxy_provider_refresh),
                    listeners: state.listeners.clone(),
                    external_ui: state.external_ui.clone(),
                    traffic_feed: Default::default(),
                    dns_server: Arc::clone(&state.dns_server),
                });
                let secret = external.secret.clone().unwrap_or_default();
                let router = meow_api::routes::create_router(external).layer(
                    middleware::from_fn_with_state(secret, reject_controller_config_mutation),
                );
                staged.0.push(tokio::spawn(async move {
                    if let Err(error) = axum::serve(socket, router).await {
                        tracing::error!("Controller failed: {error}");
                    }
                }));
            }
            #[cfg(not(any(target_os = "android", target_env = "ohos")))]
            {
                self.start_tun(&raw).await?;
            }
            Ok::<(), anyhow::Error>(())
        }
        .await;
        if let Err(error) = result {
            staged.stop().await;
            self.stop_listeners().await;
            return Err(error);
        }
        *self.tasks.lock().await = staged;
        *self.state.raw_config.write() = raw;
        Ok(())
    }

    async fn bind_listener(
        tunnel: &Tunnel,
        listener: NamedListener,
        sniffer: Arc<SnifferRuntime>,
        auth: Arc<meow_common::AuthConfig>,
        mark: Option<u32>,
        scope: ListenerTasks,
    ) -> Result<JoinHandle<()>> {
        let address = std::net::SocketAddr::new(listener.listen.parse()?, listener.port);
        if let ListenerSpec::TProxy {
            sni,
            firewall,
            udp,
            udp_timeout,
        } = listener.spec
        {
            let proxy = meow_listener::TProxyListener::new(
                tunnel.clone(),
                address,
                sni,
                mark,
                listener.name,
            )
            .with_sniffer(sniffer)
            .with_max_connections(listener.max_connections)
            .with_firewall(firewall)
            .with_udp(udp, std::time::Duration::from_secs(udp_timeout));
            let socket = TcpListener::bind(address).await?;
            let proxy = proxy
                .prepare(socket.local_addr()?)
                .await
                .map_err(|e| anyhow!("{e}"))?;
            return Ok(scope.spawn(async move {
                if let Err(error) = proxy.run_on(socket).await {
                    tracing::error!("Transparent listener failed: {error}");
                }
            }));
        }
        let socket = TcpListener::bind(address).await?;
        let tunnel = tunnel.clone();
        match listener.spec {
            ListenerSpec::Shadowsocks(ref spec) => {
                let obfs = spec.simple_obfs.as_ref().map(|obfs| match obfs.mode {
                    meow_config::ObfsMode::Http => SsObfsMode::Http,
                    meow_config::ObfsMode::Tls => SsObfsMode::Tls,
                });
                let proxy = ShadowsocksListener::new(
                    tunnel,
                    address,
                    listener.name.clone(),
                    &spec.cipher,
                    &spec.password,
                    spec.udp,
                    obfs,
                )
                .map_err(|e| anyhow!("{e}"))?
                .with_max_connections(listener.max_connections);
                let udp = proxy
                    .bind_udp(socket.local_addr()?)
                    .await
                    .map_err(|e| anyhow!("{e}"))?;
                Ok(scope.spawn(async move {
                    if let Err(error) = proxy.run_on_udp(socket, udp).await {
                        tracing::error!("Shadowsocks listener failed: {error}");
                    }
                }))
            }
            ListenerSpec::Mixed | ListenerSpec::Http | ListenerSpec::Socks5 => {
                let clients = scope.clone();
                Ok(scope.spawn(async move {
                    let slots = Arc::new(tokio::sync::Semaphore::new(
                        if listener.max_connections == 0 {
                            tokio::sync::Semaphore::MAX_PERMITS
                        } else {
                            listener
                                .max_connections
                                .min(tokio::sync::Semaphore::MAX_PERMITS)
                        },
                    ));
                    let mut backoff = meow_common::ErrorBackoff::new();
                    loop {
                        let Ok(permit) = Arc::clone(&slots).acquire_owned().await else {
                            break;
                        };
                        let (stream, source) = match socket.accept().await {
                            Ok(connection) => {
                                backoff.succeeded();
                                connection
                            }
                            Err(error) => {
                                drop(permit);
                                if backoff.failed(&error).await {
                                    tracing::error!("Proxy listener accept failed: {error}");
                                }
                                continue;
                            }
                        };
                        let tunnel = tunnel.clone();
                        let sniffer = Arc::clone(&sniffer);
                        let auth = Arc::clone(&auth);
                        let listener = listener.clone();
                        clients.spawn(async move {
                            let _permit = permit;
                            let socks = if matches!(listener.spec, ListenerSpec::Mixed) {
                                let mut peek = [0; 1];
                                match tokio::time::timeout(
                                    meow_listener::DEFAULT_HANDSHAKE_TIMEOUT,
                                    stream.peek(&mut peek),
                                )
                                .await
                                {
                                    Ok(Ok(size)) if size > 0 => peek[0] == 5,
                                    _ => return,
                                }
                            } else {
                                matches!(listener.spec, ListenerSpec::Socks5)
                            };
                            if !socks {
                                meow_listener::http_proxy::handle_http(
                                    &tunnel,
                                    stream,
                                    source,
                                    Some(&sniffer),
                                    Some(&auth),
                                    &listener.name,
                                    listener.port,
                                )
                                .await;
                            } else {
                                meow_listener::socks5::handle_socks5(
                                    &tunnel,
                                    stream,
                                    source,
                                    Some(&sniffer),
                                    Some(&auth),
                                    &listener.name,
                                    listener.port,
                                )
                                .await;
                            }
                        });
                    }
                }))
            }
            ListenerSpec::TProxy { .. } => unreachable!(),
        }
    }

    #[cfg(not(any(target_os = "android", target_env = "ohos")))]
    async fn start_tun(&self, raw: &meow_config::raw::RawConfig) -> Result<()> {
        let tun = meow_config::parse_tun_config(
            raw.tun.as_ref(),
            raw.max_connections,
            raw.fake_ip_range(),
        )?;
        if !tun.enable {
            return Ok(());
        }
        let config = meow_api::tun_config_to_listener_config(&tun);
        let lists = crate::tun_routes::RouteLists::parse(
            &serde_json::to_value(raw.tun.as_ref()).context("TUN route configuration")?,
        )?;
        let route_plan = lists.desktop_plan(
            &config.default_routes(self.state.tunnel.resolver().fake_ip_v4_net()),
            config.inet6_address.is_some(),
        )?;
        let (ready, receiver) = tokio::sync::oneshot::channel();
        let mut listener = TunListener::new(self.state.tunnel.clone(), config, "FlClash".into())
            .with_readiness_signal(ready);
        if let Some(routes) = route_plan {
            listener = listener.with_route_plan(routes)?;
        }
        let task = tokio::spawn(async move {
            if let Err(error) = listener.run().await {
                tracing::error!("TUN listener failed: {error}");
            }
        });
        let response = tokio::time::timeout(meow_api::TUN_STARTUP_TIMEOUT, receiver).await;
        match response {
            Ok(Ok(TunReady::Ready {
                core_done,
                udp_flows,
            })) => {
                self.state
                    .tunnel
                    .set_tun_handle(meow_tunnel::TunHandle {
                        task,
                        core_done: Some(core_done),
                        udp_flows,
                    })
                    .await;
                Ok(())
            }
            other => {
                task.abort();
                let _ = task.await;
                let message = match other {
                    Ok(Ok(TunReady::Failed(message))) => message,
                    Ok(Err(error)) => error.to_string(),
                    Err(error) => error.to_string(),
                    Ok(Ok(TunReady::Ready { .. })) => unreachable!(),
                };
                bail!("TUN did not start: {message}")
            }
        }
    }

    pub async fn stop_listeners(&self) {
        let tasks = std::mem::take(&mut *self.tasks.lock().await);
        tasks.stop().await;
        let dns = self.state.dns_server.write().take();
        if let Some(dns) = dns {
            dns.task.abort();
            let _ = dns.task.await;
        }
        if !cfg!(any(target_os = "android", target_env = "ohos")) {
            self.state.tunnel.stop_tun().await;
        }
    }

    pub fn proxy(&self, name: &str) -> Result<Arc<dyn Proxy>> {
        if let Some(proxy) = self.state.tunnel.proxy(name) {
            return Ok(proxy);
        }
        for provider in self.state.proxy_providers.iter() {
            if let Some(proxy) = provider
                .proxies()
                .into_iter()
                .find(|proxy| proxy.name() == name)
            {
                return Ok(proxy);
            }
        }
        bail!("Proxy {name:?} is not part of the applied configuration")
    }

    pub fn selections(&self) -> HashMap<String, String> {
        self.state
            .tunnel
            .route_snapshot()
            .proxies
            .iter()
            .filter_map(|(name, proxy)| proxy.current().map(|p| (name.to_string(), p)))
            .collect()
    }

    pub async fn shutdown(&self) {
        self.stop_listeners().await;
        self.state.tunnel.stop_tun().await;
        self.state.tunnel.statistics().close_all_connections();
        self.state.tunnel.close_all_udp_sessions();
        self.state.tunnel.reconcile_health_checks(&[]);
        self.state.proxy_providers.clear();
        self.state.rule_providers.write().clear();
        self.state
            .rule_provider_refresh
            .reconcile(&self.state.rule_providers);
        self.state
            .proxy_provider_refresh
            .reconcile(&self.state.proxy_providers, None);
        self.interface_binding.write().take();
        self.socket_policy.write().take();
        self.dns_http3.write().take();
    }
}

async fn reject_controller_config_mutation(
    State(secret): State<String>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if request.uri().path() != "/configs"
        || !matches!(*request.method(), Method::PUT | Method::PATCH)
    {
        return next.run(request).await;
    }
    let token = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    if !token.is_some_and(|token| {
        token.len() == secret.len() && bool::from(token.as_bytes().ct_eq(secret.as_bytes()))
    }) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"message":"Unauthorized"})),
        )
            .into_response();
    }
    (
        StatusCode::METHOD_NOT_ALLOWED,
        [(header::ALLOW, "GET")],
        Json(json!({
            "code":"unsupported_config_mutation",
            "message":"Apply configuration through FlClash; external-controller configuration writes are not supported.",
        })),
    )
        .into_response()
}

fn outbound_binding(document: &Value) -> Result<Option<meow_common::OutboundIfaceGuard>> {
    if cfg!(any(target_os = "android", target_env = "ohos")) {
        return Ok(None);
    }
    document["interface-name"]
        .as_str()
        .filter(|name| !name.is_empty())
        .map(meow_common::install_outbound_interface)
        .transpose()
        .context("Bind outbound interface")
}

pub fn listener_auth(raw: &meow_config::raw::RawConfig) -> Result<Arc<meow_common::AuthConfig>> {
    let parsed = meow_config::auth::parse_auth_config(
        raw.authentication.as_deref(),
        raw.skip_auth_prefixes.as_deref(),
    )
    .map_err(|error| anyhow!(error))?;
    let prefixes = raw
        .skip_auth_prefixes
        .as_deref()
        .unwrap_or(&[])
        .iter()
        .map(|prefix| prefix.parse())
        .collect::<std::result::Result<_, _>>()?;
    Ok(Arc::new(meow_common::AuthConfig::new(
        parsed.credentials,
        prefixes,
    )))
}
