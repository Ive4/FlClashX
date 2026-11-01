use crate::engine::Engine;
use anyhow::{anyhow, bail, Context, Result};
use http_body_util::{BodyExt, Full};
use hyper::{body::Bytes, Request};
use hyper_util::rt::TokioIo;
use meow_common::{AdapterType, Metadata, ProxyAdapter};
use meow_transport::tls::{TlsConfig, TlsLayer};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, OnceLock},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::Semaphore,
};
use url::Url;

pub const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

pub fn budget(arguments: &Value) -> Duration {
    Duration::from_millis(
        arguments["timeout"]
            .as_u64()
            .filter(|value| *value > 0)
            .unwrap_or(10_000)
            .min(180_000),
    )
}

pub struct Answer {
    pub value: Value,
    pub headers: HashMap<String, String>,
    pub bytes: Vec<u8>,
}

pub async fn run(engine: Arc<Engine>, arguments: &Value) -> Result<Value> {
    Ok(request(engine, arguments).await?.value)
}

pub async fn request(engine: Arc<Engine>, arguments: &Value) -> Result<Answer> {
    request_using(engine, arguments, false).await
}

pub async fn delay(engine: Arc<Engine>, arguments: &Value) -> Result<Value> {
    Ok(request_using(engine, arguments, true).await?.value)
}

async fn request_using(engine: Arc<Engine>, arguments: &Value, delay: bool) -> Result<Answer> {
    static SLOTS: OnceLock<Semaphore> = OnceLock::new();
    static DELAYS: OnceLock<Semaphore> = OnceLock::new();
    let timeout = budget(arguments);
    let slots = if delay {
        DELAYS.get_or_init(|| Semaphore::new(50))
    } else {
        SLOTS.get_or_init(|| Semaphore::new(8))
    };
    let _slot = tokio::time::timeout(timeout, slots.acquire())
        .await
        .context("Probe queue timed out")??;
    let start = Instant::now();
    let operation = async {
        let mut url = Url::parse(arguments["url"].as_str().context("Missing probe URL")?)?;
        let name = arguments["proxy-name"].as_str().unwrap_or("");
        let limit = arguments["max-body"]
            .as_u64()
            .unwrap_or(32 * 1024)
            .min(8 * 1024 * 1024) as usize;
        let mut hits = Vec::new();
        let mut method = arguments["method"].as_str().unwrap_or("GET").to_owned();
        let mut body = arguments["body"].as_str().unwrap_or("").to_owned();
        let mut headers = arguments["headers"].clone();
        for redirect in 0..=10 {
            if !matches!(url.scheme(), "http" | "https") {
                bail!("Probe URL must use HTTP or HTTPS");
            }
            let host = url
                .host_str()
                .context("Probe URL has no host")?
                .trim_matches(['[', ']']);
            let port = url
                .port_or_known_default()
                .context("Probe URL has no port")?;
            let mut metadata = Metadata {
                host: host.into(),
                dst_port: port,
                internal: true,
                ..Default::default()
            };
            metadata.dst_ip = host.parse().ok();
            let (adapter, rule, payload) = if name.is_empty() {
                let target = engine
                    .state
                    .tunnel
                    .inner()
                    .resolve_proxy_lazy(&mut metadata)
                    .await
                    .context("No route for probe")?;
                (
                    target.adapter,
                    target.rule_name.to_string(),
                    target.rule_payload.to_string(),
                )
            } else {
                let adapter: Arc<dyn ProxyAdapter> = engine.proxy(name)?;
                (adapter, String::new(), String::new())
            };
            let route_exit = exit_adapter(&adapter, &metadata);
            let (dialer, mut chains) = pick(adapter, &metadata);
            chains.reverse();
            let address = if host.contains(':') {
                format!("[{host}]:{port}")
            } else {
                format!("{host}:{port}")
            };
            let hit = json!({"host":address,"proxy":name,"exit":route_exit});
            if !hits.iter().any(|old| old == &hit) {
                hits.push(hit);
            }
            let stream = dialer.dial_tcp(&metadata).await?;
            let response = if url.scheme() == "https" {
                let mut config = TlsConfig::new(host);
                config.skip_cert_verify = arguments["skip-cert-verify"].as_bool().unwrap_or(false);
                let tls = TlsLayer::new(&config)?;
                let stream = tls
                    .connect_typed(stream)
                    .await
                    .map_err(|e| anyhow!("TLS handshake failed: {}", e.into_transport()))?;
                exchange(stream, &url, &method, &body, &headers, limit).await?
            } else {
                exchange(stream, &url, &method, &body, &headers, limit).await?
            };
            if matches!(response.status, 301 | 302 | 303 | 307 | 308)
                && arguments["no-redirect"].as_bool() != Some(true)
            {
                if let Some(location) = response.headers.get("location") {
                    if redirect == 10 {
                        bail!("Too many redirects");
                    }
                    let next = url.join(location)?;
                    if next.host_str() != url.host_str()
                        || next.port_or_known_default() != url.port_or_known_default()
                        || next.scheme() != url.scheme()
                    {
                        if let Some(headers) = headers.as_object_mut() {
                            headers.retain(|key, _| {
                                !matches!(
                                    key.to_ascii_lowercase().as_str(),
                                    "authorization" | "cookie" | "proxy-authorization"
                                )
                            });
                        }
                    }
                    if response.status == 303
                        || matches!(response.status, 301 | 302) && method == "POST"
                    {
                        method = "GET".into();
                        body.clear();
                    }
                    url = next;
                    continue;
                }
            }
            let value = json!({
                "status-code":response.status,"delay":start.elapsed().as_millis() as u64,
                "body":String::from_utf8_lossy(&response.bytes),"url":url.as_str(),
                "chains":chains,"rule":rule,"rule-payload":payload,"hits":hits,
            });
            return Ok(Answer {
                value,
                bytes: response.bytes,
                headers: response.headers,
            });
        }
        bail!("Too many redirects")
    };
    tokio::time::timeout(timeout, operation)
        .await
        .context("Probe timed out")?
}

struct HttpResponse {
    status: u16,
    headers: HashMap<String, String>,
    bytes: Vec<u8>,
}

async fn exchange<S>(
    stream: S,
    url: &Url,
    method: &str,
    body: &str,
    headers: &Value,
    limit: usize,
) -> Result<HttpResponse>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut sender, connection) =
        hyper::client::conn::http1::handshake(TokioIo::new(stream)).await?;
    struct Abort(tokio::task::JoinHandle<()>);
    impl Drop for Abort {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    let _connection = Abort(tokio::spawn(async move {
        let _ = connection.await;
    }));
    let path = &url[url::Position::BeforePath..url::Position::AfterQuery];
    let host = &url[url::Position::BeforeHost..url::Position::AfterPort];
    let mut request = Request::builder()
        .method(method)
        .uri(if path.is_empty() { "/" } else { path })
        .header("host", host)
        .header("accept-encoding", "identity");
    let mut supplied_ua = false;
    if let Some(headers) = headers.as_object() {
        for (key, value) in headers {
            if matches!(
                key.to_ascii_lowercase().as_str(),
                "connection" | "content-length" | "transfer-encoding" | "accept-encoding" | "host"
            ) {
                continue;
            }
            supplied_ua |= key.eq_ignore_ascii_case("user-agent");
            request = request.header(
                key,
                value.as_str().context("Probe header must be a string")?,
            );
        }
    }
    if !supplied_ua {
        request = request.header("user-agent", USER_AGENT);
    }
    let response = sender
        .send_request(request.body(Full::new(Bytes::copy_from_slice(body.as_bytes())))?)
        .await?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|value| (name.as_str().into(), value.into()))
        })
        .collect();
    let mut body = response.into_body();
    let mut bytes = Vec::new();
    if limit > 0 {
        while let Some(frame) = body.frame().await {
            if let Ok(data) = frame?.into_data() {
                let left = limit - bytes.len();
                bytes.extend_from_slice(&data[..left.min(data.len())]);
                if bytes.len() == limit {
                    break;
                }
            }
        }
    }
    Ok(HttpResponse {
        status,
        headers,
        bytes,
    })
}

fn pick(
    mut adapter: Arc<dyn ProxyAdapter>,
    metadata: &Metadata,
) -> (Arc<dyn ProxyAdapter>, Vec<String>) {
    let mut names = Vec::new();
    for _ in 0..32 {
        names.push(adapter.name().to_owned());
        if !matches!(
            adapter.adapter_type(),
            AdapterType::Selector
                | AdapterType::Fallback
                | AdapterType::UrlTest
                | AdapterType::LoadBalance
        ) {
            break;
        }
        let Some(next) = adapter.unwrap_proxy(metadata, true) else {
            break;
        };
        if names.iter().any(|name| name == next.name()) {
            break;
        }
        adapter = next;
    }
    (adapter, names)
}

pub fn chain(first: &Arc<dyn ProxyAdapter>, metadata: &Metadata) -> Vec<String> {
    let mut names = vec![first.name().to_owned()];
    let mut next = first.unwrap_proxy(metadata, false);
    while let Some(proxy) = next {
        if names.len() == 32 || names.iter().any(|name| name == proxy.name()) {
            break;
        }
        names.push(proxy.name().to_owned());
        next = proxy.unwrap_proxy(metadata, false);
    }
    names.reverse();
    names
}

fn exit_adapter(first: &Arc<dyn ProxyAdapter>, metadata: &Metadata) -> String {
    let mut adapter = Arc::clone(first);
    let mut seen = Vec::new();
    loop {
        seen.push(adapter.name().to_owned());
        if adapter.adapter_type() == AdapterType::LoadBalance || seen.len() >= 32 {
            break;
        }
        let Some(next) = adapter.unwrap_proxy(metadata, false) else {
            break;
        };
        if seen.iter().any(|name| name == next.name()) {
            break;
        }
        adapter = next;
    }
    format!(
        "{:?} {} {}",
        adapter.name(),
        adapter.adapter_type(),
        adapter.addr()
    )
}

pub fn metadata(address: &str) -> Result<Metadata> {
    let url = Url::parse(&format!("https://{address}"))?;
    let host = url
        .host_str()
        .context("Route has no host")?
        .trim_matches(['[', ']']);
    let mut metadata = Metadata {
        host: host.into(),
        dst_port: url.port_or_known_default().unwrap_or(443),
        internal: true,
        ..Default::default()
    };
    metadata.dst_ip = host.parse().ok();
    Ok(metadata)
}

pub async fn exit(engine: &Engine, host: &str, name: &str) -> Result<String> {
    let mut metadata = metadata(host)?;
    let adapter: Arc<dyn ProxyAdapter> = if name.is_empty() {
        engine
            .state
            .tunnel
            .inner()
            .resolve_proxy_lazy(&mut metadata)
            .await
            .context("No route")?
            .adapter
    } else {
        engine.proxy(name)?
    };
    Ok(exit_adapter(&adapter, &metadata))
}

pub fn error_kind(error: &anyhow::Error) -> &'static str {
    if error.chain().any(|e| {
        e.to_string().to_ascii_lowercase().contains("timed out")
            || e.to_string().to_ascii_lowercase().contains("timeout")
    }) {
        "timeout"
    } else {
        "failed"
    }
}
