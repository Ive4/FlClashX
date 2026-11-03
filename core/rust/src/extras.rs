use crate::{
    core::Core,
    engine::Engine,
    profile,
    protocol::{self, MethodError},
};
use anyhow::{bail, Context, Result};
use meow_config::raw;
use meow_rules::{mrs_parser, ParserContext};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    io::Cursor,
    path::{Component, Path, PathBuf},
};

pub fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}

pub fn normalize_tracker(tracker: &mut Value) {
    let metadata = &mut tracker["metadata"];
    if !metadata.is_object() {
        return;
    }
    for field in ["sourcePort", "destinationPort"] {
        if let Some(port) = metadata[field].as_u64() {
            metadata[field] = json!(port.to_string());
        }
    }
    if let Some(mode) = metadata["dnsMode"].as_str() {
        let mode = match mode.to_ascii_lowercase().as_str() {
            "fakeip" | "fake-ip" => "fake-ip",
            "redirhost" | "redir-host" => "redir-host",
            "hosts" => "hosts",
            _ => "normal",
        };
        metadata["dnsMode"] = json!(mode);
    }
}

pub fn validate_proxy_message(value: &Value) -> String {
    let result = (|| -> Result<()> {
        if let Some((path, _)) = unsupported_proxy_option(value) {
            bail!("Unsupported proxy option {path}");
        }
        let map: HashMap<String, Value> = serde_json::from_value(value.clone())?;
        let parsed =
            meow_config::proxy_parser::parse_proxy(&map, false).map_err(anyhow::Error::msg)?;
        if let Some(name) = value["name"].as_str() {
            if parsed.name() != name {
                bail!(
                    "Unsupported outbound alias {name:?}: this backend exposes {:?}",
                    parsed.name()
                );
            }
        }
        Ok(())
    })();
    result
        .err()
        .map(|error| format!("{error:#}"))
        .unwrap_or_default()
}

fn unsupported_proxy_option(value: &Value) -> Option<(String, Value)> {
    unsupported_proxy_options(value).into_iter().next()
}

fn unsupported_proxy_options(value: &Value) -> Vec<(String, Value)> {
    let mut options = Vec::new();
    if value["reality-opts"]["short-id"].is_number() {
        options.push((
            "reality-opts.short-id (quote its original literal)".into(),
            value["reality-opts"]["short-id"].clone(),
        ));
    }
    for key in ["tfo", "mptcp", "interface-name", "routing-mark"] {
        if value.get(key).is_some_and(|value| !inert(value)) {
            options.push((key.into(), value[key].clone()));
        }
    }
    if value["type"] == "vmess" && value["alterId"].as_u64().unwrap_or(0) > 0 {
        options.push(("alterId".into(), value["alterId"].clone()));
    }
    for block in ["smux", "mux"] {
        for key in ["statistic", "brutal-opts"] {
            if value[block].get(key).is_some_and(|value| !inert(value)) {
                options.push((format!("{block}.{key}"), value[block][key].clone()));
            }
        }
    }
    if value["type"] != "ss" && value.get("plugin").is_some_and(|value| !inert(value)) {
        options.push(("plugin".into(), value["plugin"].clone()));
    }
    options
}

pub fn validate_filter_message(value: &Value) -> String {
    let Some(filter) = value.as_str() else {
        return "Expected a string filter".into();
    };
    filter
        .split(char::from(96))
        .find_map(|part| {
            fancy_regex::Regex::new(part)
                .err()
                .map(|error| error.to_string())
        })
        .unwrap_or_default()
}

fn inert(value: &Value) -> bool {
    value.is_null()
        || value == &json!(false)
        || value == &json!(0)
        || value == &json!("")
        || value.as_array().is_some_and(Vec::is_empty)
        || value.as_object().is_some_and(serde_json::Map::is_empty)
}

fn unsupported(path: &str, value: &Value) -> MethodError {
    MethodError::new(
        "unsupported_config",
        format!("meow-rs 0.28.0 does not implement {path}"),
    )
    .details(json!({"path":path,"value":value}))
}

#[derive(Default)]
struct UnsupportedOptions {
    first: Option<MethodError>,
    paths: Vec<String>,
    count: usize,
}

impl UnsupportedOptions {
    fn record(&mut self, path: &str, value: &Value) {
        if self.first.is_none() {
            self.first = Some(unsupported(path, value));
        }
        self.count += 1;
        if self.paths.len() < 128 {
            self.paths.push(path.to_owned());
        }
    }

    fn finish(self) -> protocol::Result<()> {
        let Some(mut error) = self.first else {
            return Ok(());
        };
        error.details["unsupported-paths"] = json!(self.paths);
        error.details["unsupported-path-count"] = json!(self.count);
        error.details["unsupported-paths-truncated"] = json!(self.count > 128);
        Err(error)
    }
}

pub fn validate(document: &Value) -> protocol::Result<()> {
    protocol::object(document)?;
    crate::socket_policy::validate(document)?;
    crate::dns_http3::validate(document)?;
    crate::direct_dns::validate(document)?;
    let effective = profile::runtime_document(
        document,
        false,
        cfg!(any(target_os = "android", target_env = "ohos")),
    )?;
    let raw = meow_config::parse_raw_yaml(
        &serde_saphyr::to_string(&effective).map_err(anyhow::Error::from)?,
    )?;
    let schema = serde_json::to_value(raw::RawConfig::default()).map_err(anyhow::Error::from)?;
    let mut unsupported_options = UnsupportedOptions::default();
    for (key, value) in document.as_object().unwrap() {
        if schema.get(key).is_some()
            || key.starts_with("x-")
            || key.ends_with("-anchor")
            || inert(value)
            || crate::legacy_defaults::accepts(document, key, value)
        {
            continue;
        }
        let accepted = match key.as_str() {
            "geo-auto-update"
            | "geo-update-interval"
            | "geox-url"
            | "global-ua"
            | "skip-cert-verify"
            | "test-url"
            | "profile"
            | "interface-name" => true,
            "find-process-mode" => matches!(value.as_str(), Some("off" | "strict" | "always")),
            "unified-delay" | "tcp-concurrent" => value.as_bool() == Some(true),
            "keep-alive-interval" | "keep-alive-idle" | "disable-keep-alive" => true,
            "geodata-loader" => matches!(value.as_str(), Some("memconservative" | "standard")),
            "geodata-mode" => value.as_bool() == Some(false),
            "ntp" | "iptables" => value["enable"].as_bool() != Some(true),
            _ => false,
        };
        if !accepted {
            unsupported_options.record(key, value);
        }
    }
    if let Some(dns) = document["dns"].as_object() {
        let empty: raw::RawDns = serde_json::from_value(json!({})).map_err(anyhow::Error::from)?;
        let supported = serde_json::to_value(empty).map_err(anyhow::Error::from)?;
        for (key, value) in dns {
            if supported.get(key).is_some()
                || crate::direct_dns::supported_field(key)
                || inert(value)
            {
                continue;
            }
            let equivalent = matches!(
                (key.as_str(), value.as_str()),
                ("cache-algorithm", Some("lru"))
            ) || key == "cache-max-size" && value.as_u64() == Some(4096)
                || key == "fake-ip-ttl" && value.as_u64() == Some(1)
                || key == "ipv6-timeout" && value.as_u64() == Some(100)
                || key == "prefer-h3"
                || key == "ipv6";
            if !equivalent {
                unsupported_options.record(&format!("dns.{key}"), value);
            }
        }
        if let Some(filter) = dns.get("fallback-filter").and_then(Value::as_object) {
            for (key, value) in filter {
                if !["geoip", "geoip-code", "ipcidr", "domain"].contains(&key.as_str())
                    && !inert(value)
                {
                    unsupported_options.record(&format!("dns.fallback-filter.{key}"), value);
                }
            }
        }
    }
    if let Some(tun) = document["tun"].as_object() {
        crate::tun_routes::validate(document)?;
        let schema = serde_json::to_value(raw::RawTun::default()).map_err(anyhow::Error::from)?;
        for (key, value) in tun {
            if schema.get(key).is_none()
                && !inert(value)
                && !crate::legacy_defaults::accepts(document, &format!("tun.{key}"), value)
            {
                unsupported_options.record(&format!("tun.{key}"), value);
            }
            if [
                "strict-route",
                "auto-redirect",
                "endpoint-independent-nat",
                "mtu-v6",
                "include-uid",
                "exclude-uid",
            ]
            .contains(&key.as_str())
                && !inert(value)
            {
                unsupported_options.record(&format!("tun.{key}"), value);
            }
        }
    }
    if cfg!(any(target_os = "android", target_env = "ohos"))
        && document["interface-name"]
            .as_str()
            .is_some_and(|name| !name.is_empty())
    {
        unsupported_options.record("interface-name", &document["interface-name"]);
    }
    if let Some(providers) = document["proxy-providers"].as_object() {
        for (name, provider) in providers {
            if let Some(overrides) = provider["override"].as_object() {
                for (key, value) in overrides {
                    if key != "dialer-proxy" && !value.is_null() {
                        unsupported_options
                            .record(&format!("proxy-providers.{name}.override.{key}"), value);
                    }
                }
            }
        }
    }
    if let Some(listeners) = document["listeners"].as_array() {
        for (index, listener) in listeners.iter().enumerate() {
            for key in [
                "shadow-tls",
                "res-tls",
                "jls-config",
                "kcp-tun",
                "mux-option",
                "users",
                "authentication",
            ] {
                if let Some(value) = listener.get(key).filter(|value| !inert(value)) {
                    unsupported_options.record(&format!("listeners[{index}].{key}"), value);
                }
            }
            if !matches!(
                listener["type"].as_str(),
                Some("http" | "socks" | "socks5" | "mixed" | "tproxy" | "shadowsocks")
            ) {
                unsupported_options.record(&format!("listeners[{index}].type"), &listener["type"]);
            }
        }
    }
    if let Some(proxies) = &raw.proxies {
        for proxy in proxies {
            let name = proxy.get("name").and_then(Value::as_str).unwrap_or("");
            let value = serde_json::to_value(proxy).map_err(anyhow::Error::from)?;
            for (path, value) in unsupported_proxy_options(&value) {
                unsupported_options.record(&format!("proxies.{name}.{path}"), &value);
            }
        }
    }
    unsupported_options.finish()?;
    let mut names = HashSet::new();
    if let Some(proxies) = &raw.proxies {
        for proxy in proxies {
            let name = proxy.get("name").and_then(Value::as_str).unwrap_or("");
            if !names.insert(name) {
                return Err(MethodError::new(
                    "core_error",
                    format!("Duplicate proxy name: {name}"),
                ));
            }
            let error =
                validate_proxy_message(&serde_json::to_value(proxy).map_err(anyhow::Error::from)?);
            if !error.is_empty() {
                return Err(MethodError::new(
                    "core_error",
                    format!("Proxy {name:?}: {error}"),
                ));
            }
        }
    }
    meow_config::validate_named_listeners(&raw)?;
    Ok(())
}

pub fn runtime_options(document: &mut Value) -> Result<()> {
    if document["tun"].get("stack").is_some() {
        tracing::warn!("meow-rs uses the lwIP TUN stack; the saved Mihomo stack name does not select a different implementation");
    }
    if document.get("find-process-mode").is_some() {
        tracing::warn!("meow-rs resolves process metadata on rule demand; the saved Mihomo process lookup policy is retained");
    }
    if let Some(name) = document["interface-name"]
        .as_str()
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
    {
        if document["tun"].is_object() {
            document["tun"]["outbound-interface"] = json!(name);
        }
    }
    if let Some(stored) = document["profile"]["store-fake-ip"].as_bool() {
        if !document["dns"].is_object() {
            document["dns"] = json!({});
        }
        document["dns"]["store-fake-ip"] = json!(stored);
    }
    if let Some(ipv6) = document["dns"]["ipv6"].as_bool() {
        document["ipv6"] = json!(ipv6);
    }
    if let Some(ua) = document["global-ua"].as_str().map(str::to_owned) {
        for kind in ["proxy-providers", "rule-providers"] {
            if let Some(providers) = document[kind].as_object_mut() {
                for provider in providers.values_mut() {
                    if !provider["header"].is_object() {
                        provider["header"] = json!({});
                    }
                    if !provider["header"]
                        .as_object()
                        .unwrap()
                        .keys()
                        .any(|key| key.eq_ignore_ascii_case("user-agent"))
                    {
                        provider["header"]["User-Agent"] = json!([ua]);
                    }
                }
            }
        }
    }
    Ok(())
}

pub fn skip_certificates(document: &mut Value) {
    if let Some(proxies) = document["proxies"].as_array_mut() {
        for proxy in proxies {
            if proxy.is_object() {
                proxy["skip-cert-verify"] = json!(true);
            }
        }
    }
}

pub fn route_fingerprint(engine: &Engine) -> String {
    let mut state = Vec::new();
    for (name, proxy) in engine.state.tunnel.route_snapshot().proxies.iter() {
        state.push(format!(
            "{name}|{}|{}|{:?}",
            proxy.adapter_type(),
            proxy.addr(),
            proxy.current()
        ));
    }
    for provider in engine.state.proxy_providers.iter() {
        for proxy in provider.proxies() {
            state.push(format!(
                "p:{}|{}|{}|{}",
                provider.name,
                proxy.name(),
                proxy.adapter_type(),
                proxy.addr()
            ));
        }
    }
    for (name, provider) in engine.state.rule_providers.read().iter() {
        state.push(format!(
            "r:{name}|{:p}|{}",
            std::sync::Arc::as_ptr(&provider.snapshot()),
            provider.rule_count()
        ));
    }
    state.sort_unstable();
    hex::encode(Sha256::digest(state.join("\0").as_bytes()))
}

pub fn provider_fingerprints(engine: &Engine) -> HashMap<String, String> {
    let mut result = HashMap::new();
    for provider in engine.state.proxy_providers.iter() {
        let mut entries = provider
            .proxies()
            .iter()
            .map(|proxy| format!("{}|{}|{}", proxy.name(), proxy.adapter_type(), proxy.addr()))
            .collect::<Vec<_>>();
        entries.sort_unstable();
        result.insert(
            provider.name.clone(),
            format!(
                "{}:{}",
                provider.updated_at_secs(),
                hex::encode(Sha256::digest(entries.join("\0").as_bytes()))
            ),
        );
    }
    for (name, provider) in engine.state.rule_providers.read().iter() {
        result.insert(
            name.clone(),
            format!(
                "{}:{:p}",
                provider.updated_at_secs(),
                std::sync::Arc::as_ptr(&provider.snapshot())
            ),
        );
    }
    result
}

pub async fn memory_stats() -> Value {
    tokio::task::spawn_blocking(|| {
        let mut system = sysinfo::System::new();
        let pid = sysinfo::get_current_pid().ok();
        if let Some(pid) = pid {
            system.refresh_processes(sysinfo::ProcessesToUpdate::Some(&[pid]), true);
        }
        let rss = pid
            .and_then(|pid| system.process(pid))
            .map_or(0, |process| process.memory());
        json!({"rss":rss,"heapInuse":0,"heapIdle":0,"stackInuse":0,"runtimeOther":0})
    })
    .await
    .unwrap_or_else(|_| json!({"rss":0,"heapInuse":0,"heapIdle":0,"stackInuse":0,"runtimeOther":0}))
}

pub fn trim_memory() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    unsafe {
        libc::malloc_trim(0);
    }
}

pub fn decrypt(arguments: &Value) -> protocol::Result<String> {
    let bytes = profile::read_bytes(Path::new(protocol::field(arguments, "path")?))?;
    let plain = profile::decrypt_bytes(&bytes, protocol::field(arguments, "age-secret-key")?)?;
    String::from_utf8(plain).map_err(|error| MethodError::new("core_error", error))
}

pub async fn proxy_definition(core: &Core, name: &str) -> protocol::Result<Value> {
    let document = core.document().await;
    if let Some(proxy) = document["proxies"].as_array().and_then(|proxies| {
        proxies
            .iter()
            .find(|proxy| proxy["name"].as_str() == Some(name))
    }) {
        return Ok(proxy.clone());
    }
    let engine = core.active()?;
    for provider in engine.state.proxy_providers.iter() {
        if !provider.proxies().iter().any(|proxy| proxy.name() == name) {
            continue;
        }
        let mapping = &document["proxy-providers"][&provider.name];
        let payload =
            profile::read(&provider_path(core, mapping, &provider.name)?.to_string_lossy())?;
        if let Some(proxy) = payload["proxies"].as_array().and_then(|proxies| {
            proxies
                .iter()
                .find(|proxy| proxy["name"].as_str() == Some(name))
        }) {
            let mut proxy = proxy.clone();
            if let Some(overrides) = mapping["override"].as_object() {
                for (key, value) in overrides {
                    proxy[key] = value.clone();
                }
            }
            return Ok(proxy);
        }
    }
    Ok(Value::Null)
}

pub fn provider_path(core: &Core, mapping: &Value, name: &str) -> protocol::Result<PathBuf> {
    let home = core.home.read().clone();
    let fallback = format!("provider_{name}.yaml");
    let path = PathBuf::from(mapping["path"].as_str().unwrap_or(&fallback));
    let path = if path.is_absolute() {
        path
    } else {
        home.join(path)
    };
    contained(&home, &path)?;
    Ok(path)
}

fn contained(root: &Path, path: &Path) -> protocol::Result<()> {
    let mut resolved = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                resolved.pop();
            }
            Component::CurDir => {}
            other => resolved.push(other.as_os_str()),
        }
    }
    if !resolved.starts_with(root) {
        return Err(MethodError::new(
            "invalid_arguments",
            "Path is outside Core home",
        ));
    }
    let mut existing = resolved.as_path();
    while !existing.exists() {
        existing = existing
            .parent()
            .ok_or_else(|| MethodError::new("invalid_arguments", "Invalid provider path"))?;
    }
    let root = root.canonicalize().map_err(anyhow::Error::from)?;
    if !existing
        .canonicalize()
        .map_err(anyhow::Error::from)?
        .starts_with(root)
    {
        return Err(MethodError::new(
            "invalid_arguments",
            "Provider path escapes Core home through a link",
        ));
    }
    Ok(())
}

fn provider_error(code: &str, name: &str, error: impl ToString) -> MethodError {
    MethodError::new(code, error).details(json!({"providerName":name}))
}

fn update_error(name: &str, error: impl ToString) -> MethodError {
    let message = error.to_string();
    let lower = message.to_ascii_lowercase();
    let reason = if lower.contains("tls") || lower.contains("certificate") {
        "tls"
    } else if lower.contains("dns") || lower.contains("resolve") {
        "dns"
    } else if lower.contains("timeout") || lower.contains("timed out") {
        "timeout"
    } else if lower.contains("connect") || lower.contains("eof") {
        "connection"
    } else {
        ""
    };
    let mut result = provider_error(
        if reason.is_empty() {
            "provider_update_error"
        } else {
            "request_error"
        },
        name,
        message.clone(),
    );
    if !reason.is_empty() {
        result.details["reason"] = json!(reason);
    }
    if let Ok(pattern) = regex::Regex::new(r"(?:HTTP[/0-9.]*\s+|status[: ]+)([1-5][0-9]{2})") {
        if let Some(status) = pattern
            .captures(&message)
            .and_then(|cap| cap[1].parse::<u16>().ok())
        {
            result.code = "request_bad_response".into();
            result.details["statusCode"] = json!(status);
        }
    }
    result
}

pub async fn providers(core: &Core, method: &str, arguments: &Value) -> protocol::Result<Value> {
    let engine = core.active()?;
    let document = core.document().await;
    if matches!(method, "getExternalProviders" | "getExternalProvider") {
        let proxies = engine.api("GET", "/providers/proxies", Value::Null).await?;
        let rules = engine.api("GET", "/providers/rules", Value::Null).await?;
        let mut list = Vec::new();
        for (kind, data, key) in [
            ("Proxy", proxies, "proxy-providers"),
            ("Rule", rules, "rule-providers"),
        ] {
            if let Some(providers) = data["providers"].as_object() {
                for (name, provider) in providers {
                    let mapping = &document[key][name];
                    if !matches!(mapping["type"].as_str(), Some("file" | "http")) {
                        continue;
                    }
                    let count = provider["proxies"]
                        .as_array()
                        .map(Vec::len)
                        .or_else(|| provider["ruleCount"].as_u64().map(|v| v as usize))
                        .unwrap_or(0);
                    list.push(json!({"name":name,"type":kind,"vehicle-type":if mapping["type"]=="http"{"HTTP"}else{"File"},"count":count,"path":provider_path(core,mapping,name)?,"update-at":provider["updatedAt"].as_str().unwrap_or("0001-01-01T00:00:00Z"),"subscription-info":provider["subscriptionInfo"]}));
                }
            }
        }
        list.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
        return if method == "getExternalProvider" {
            let name = protocol::string(arguments)?;
            Ok(list
                .into_iter()
                .find(|p| p["name"] == name)
                .unwrap_or(Value::Null))
        } else {
            Ok(json!(list))
        };
    }
    let name = if method == "sideLoadExternalProvider" {
        protocol::field(arguments, "providerName")?
    } else {
        protocol::string(arguments)?
    };
    let rule = document["rule-providers"].get(name).is_some();
    let mapping = if rule {
        &document["rule-providers"][name]
    } else {
        &document["proxy-providers"][name]
    };
    if !matches!(mapping["type"].as_str(), Some("file" | "http")) {
        return Err(provider_error(
            "provider_not_found",
            name,
            "external provider does not exist",
        ));
    }
    let _claim = UpdateClaim::new(core, format!("provider:{name}")).ok_or_else(|| {
        provider_error("provider_updating", name, "external provider is updating")
    })?;
    if method == "updateExternalProvider" {
        if rule {
            let provider = engine
                .state
                .rule_providers
                .read()
                .get(name)
                .cloned()
                .ok_or_else(|| {
                    provider_error("provider_not_found", name, "rule provider does not exist")
                })?;
            provider
                .refresh()
                .await
                .map_err(|e| update_error(name, e))?;
        } else {
            let provider = engine
                .state
                .proxy_providers
                .get(name)
                .map(|entry| entry.value().clone())
                .ok_or_else(|| {
                    provider_error("provider_not_found", name, "proxy provider does not exist")
                })?;
            provider
                .refresh()
                .await
                .map_err(|e| update_error(name, e))?;
        }
    } else {
        let text = protocol::field(arguments, "data")?;
        validate_provider_payload(mapping, text.as_bytes(), rule)
            .map_err(|e| provider_error("provider_update_error", name, e))?;
        let path = provider_path(core, mapping, name)?;
        let old = std::fs::read(&path).ok();
        profile::StagedFile::bytes(&path, text.as_bytes())?.commit()?;
        if let Err(error) = core.reload_provider(name, rule).await {
            if let Some(old) = old {
                let _ =
                    profile::StagedFile::bytes(&path, &old).and_then(profile::StagedFile::commit);
            } else {
                let _ = std::fs::remove_file(&path);
            }
            if let Err(rollback) = core.reload_current().await {
                return Err(provider_error(
                    "provider_rollback_failed",
                    name,
                    format!("{error}; rollback: {rollback}"),
                ));
            }
            return Err(provider_error("provider_update_error", name, error));
        }
    }
    core.route_changed(false);
    crate::ownership::schedule(&core.home.read());
    Ok(json!(""))
}

pub fn validate_provider_payload(mapping: &Value, bytes: &[u8], rule: bool) -> Result<()> {
    if rule {
        let behavior = match mapping["behavior"].as_str() {
            Some("domain") => meow_rules::RuleSetBehavior::Domain,
            Some("ipcidr") => meow_rules::RuleSetBehavior::IpCidr,
            Some("classical") => meow_rules::RuleSetBehavior::Classical,
            _ => bail!("Unknown rule provider behavior"),
        };
        if meow_rules::is_mrs_bytes(bytes) {
            meow_rules::build_rule_set_from_mrs_with_behavior(
                bytes,
                &ParserContext::empty(),
                Some(behavior),
                true,
            )
            .map_err(anyhow::Error::msg)?;
        } else {
            let text = std::str::from_utf8(bytes)?;
            let (format, entries) = rule_entries(text)?;
            let _ = format;
            if behavior == meow_rules::RuleSetBehavior::Domain
                && entries.iter().any(|entry| entry.contains('/'))
            {
                bail!("Domain rule provider entries cannot contain a slash");
            }
            meow_rules::build_rule_set_checked(behavior, &entries, &ParserContext::empty())
                .map_err(anyhow::Error::msg)?;
        }
    } else {
        let payload = profile::parse(std::str::from_utf8(bytes)?)?;
        for proxy in payload["proxies"]
            .as_array()
            .context("Provider payload has no proxies list")?
        {
            let error = validate_proxy_message(proxy);
            if !error.is_empty() {
                bail!("{}: {error}", proxy["name"]);
            }
        }
    }
    Ok(())
}

pub async fn preflight_providers(core: &Core, document: &Value) -> protocol::Result<()> {
    for (section, rule) in [("proxy-providers", false), ("rule-providers", true)] {
        let Some(providers) = document[section].as_object() else {
            continue;
        };
        for (name, mapping) in providers {
            if mapping["type"] == "inline" && rule {
                continue;
            }
            let path = provider_path(core, mapping, name)?;
            let bytes = match std::fs::read(&path) {
                Ok(bytes) => bytes,
                Err(error) if mapping["type"] == "file" => {
                    return Err(provider_error("provider_update_error", name, error))
                }
                Err(_) => {
                    let url = protocol::field(mapping, "url")?;
                    let bytes = download(core, url, mapping["proxy"].as_str()).await?;
                    validate_provider_payload(mapping, &bytes, rule)
                        .map_err(|e| provider_error("provider_update_error", name, e))?;
                    profile::StagedFile::bytes(&path, &bytes)?.commit()?;
                    bytes
                }
            };
            validate_provider_payload(mapping, &bytes, rule)
                .map_err(|e| provider_error("provider_update_error", name, e))?;
        }
    }
    Ok(())
}

pub async fn clear_effect(core: &Core, arguments: &Value) -> protocol::Result<()> {
    let id = arguments
        .as_i64()
        .filter(|id| *id > 0)
        .ok_or_else(|| MethodError::new("invalid_arguments", "invalid profile id"))?;
    let home = core.home.read().clone();
    if home.as_os_str().is_empty() {
        return Err(MethodError::new("not_initialized", "not initialized"));
    }
    let target = home.join("profiles").join("providers").join(id.to_string());
    contained(&home, &target)?;
    if target.exists() {
        std::fs::remove_dir_all(&target).map_err(anyhow::Error::from)?;
    }
    Ok(())
}

pub fn rule_entries(text: &str) -> Result<(&'static str, Vec<String>)> {
    if let Ok(value) = profile::parse(text) {
        if value.get("payload").is_some() || value.get("rules").is_some() {
            let mut entries = Vec::new();
            for key in ["payload", "rules"] {
                for entry in profile::array(&value, key)? {
                    let entry = entry
                        .as_str()
                        .context("Rule set entries must be strings")?
                        .trim();
                    if !entry.is_empty() {
                        entries.push(entry.to_owned());
                    }
                }
            }
            return Ok(("yaml", entries));
        }
    }
    Ok((
        "text",
        text.lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#') && !line.starts_with("//"))
            .map(str::to_owned)
            .collect(),
    ))
}

fn cidr(value: &str) -> Option<String> {
    value
        .parse::<ipnet::IpNet>()
        .map(|net| net.to_string())
        .ok()
        .or_else(|| {
            value
                .parse::<std::net::IpAddr>()
                .ok()
                .map(|ip| format!("{ip}/{}", if ip.is_ipv4() { 32 } else { 128 }))
        })
}

pub fn compile_rule_set(
    bytes: &[u8],
    allow_empty: bool,
) -> protocol::Result<(Value, Option<Vec<u8>>)> {
    if meow_rules::is_mrs_bytes(bytes) {
        let (behavior, _) = dump_mrs(bytes)?;
        return Ok((json!({"behavior":behavior,"format":"mrs"}), None));
    }
    let (format, entries) = rule_entries(
        std::str::from_utf8(bytes).map_err(|e| MethodError::new("rule_set_invalid", e))?,
    )?;
    if entries.is_empty() {
        if allow_empty {
            return Ok((json!({"behavior":"classical","format":format}), None));
        }
        return Err(MethodError::new(
            "rule_set_empty",
            "rule set has no usable entries",
        ));
    }
    let mut keys = Vec::new();
    let mut domains = 0;
    let mut cidrs = 0;
    let mut classical = false;
    for entry in &entries {
        if entry.contains(',') {
            let parts = entry.split(',').map(str::trim).collect::<Vec<_>>();
            if parts.len() != 2 {
                classical = true;
                break;
            }
            match parts[0].to_ascii_uppercase().as_str() {
                "DOMAIN"
                    if !parts[1].is_empty()
                        && !parts[1].contains(['+', '*', '/'])
                        && !parts[1].starts_with('.') =>
                {
                    domains += 1;
                    keys.push(parts[1].to_owned());
                }
                "DOMAIN-SUFFIX"
                    if !parts[1].is_empty()
                        && !parts[1].contains(['+', '*', '/'])
                        && !parts[1].starts_with('.') =>
                {
                    domains += 1;
                    keys.push(format!("+.{}", parts[1]));
                }
                "IP-CIDR" | "IP-CIDR6" => {
                    if let Some(cidr) = cidr(parts[1]) {
                        cidrs += 1;
                        keys.push(cidr);
                    } else {
                        classical = true;
                        break;
                    }
                }
                _ => {
                    classical = true;
                    break;
                }
            }
        } else if let Some(cidr) = cidr(entry) {
            cidrs += 1;
            keys.push(cidr);
        } else {
            domains += 1;
            keys.push(entry.clone());
        }
    }
    if domains > 0 && cidrs > 0 && !entries.iter().any(|entry| entry.contains(',')) {
        return Err(MethodError::new(
            "rule_set_mixed",
            "rule set mixes domains and IP ranges",
        ));
    }
    if classical || domains > 0 && cidrs > 0 {
        return Ok((json!({"behavior":"classical","format":format}), None));
    }
    let behavior = if cidrs > 0 { "ipcidr" } else { "domain" };
    if behavior == "domain" && keys.iter().any(|entry| entry.contains('/')) {
        return Err(MethodError::new(
            "rule_set_invalid",
            "Domain rule entries cannot contain a slash",
        ));
    }
    let mrs = encode_mrs(behavior, &keys)?;
    meow_rules::build_rule_set_from_mrs(&mrs, &ParserContext::empty())
        .map_err(|e| MethodError::new("rule_set_invalid", e))?;
    Ok((json!({"behavior":behavior,"format":format}), Some(mrs)))
}

fn encode_mrs(behavior: &str, entries: &[String]) -> Result<Vec<u8>> {
    let mut payload = Vec::new();
    for entry in entries {
        if behavior == "ipcidr" {
            match entry.parse::<ipnet::IpNet>()? {
                ipnet::IpNet::V4(net) => {
                    payload.push(4);
                    payload.extend(net.addr().octets());
                    payload.push(net.prefix_len());
                }
                ipnet::IpNet::V6(net) => {
                    payload.push(16);
                    payload.extend(net.addr().octets());
                    payload.push(net.prefix_len());
                }
            }
        } else {
            payload.extend(
                u16::try_from(entry.len())
                    .context("Domain rule exceeds MRS length limit")?
                    .to_be_bytes(),
            );
            payload.extend(entry.as_bytes());
        }
    }
    let mut result = b"MRS!".to_vec();
    result.push(1);
    result.push(if behavior == "ipcidr" { 1 } else { 0 });
    result.extend(u32::try_from(entries.len())?.to_be_bytes());
    result.extend(zstd::encode_all(Cursor::new(payload), 3)?);
    Ok(result)
}

pub fn dump_mrs(bytes: &[u8]) -> protocol::Result<(&'static str, Vec<String>)> {
    let result = (|| -> Result<_> {
        if bytes.starts_with(&mrs_parser::ZSTD_MAGIC) {
            let payload = mrs_parser::parse_upstream_ruleset_mrs(bytes)?;
            return Ok((
                if payload.behavior == 1 {
                    "ipcidr"
                } else {
                    "domain"
                },
                payload.entries,
            ));
        }
        let (header, compressed) = mrs_parser::parse_header(bytes)?;
        let payload = mrs_parser::decompress_payload(compressed)?;
        let mut entries = Vec::new();
        let behavior = match header.type_tag {
            0 => {
                mrs_parser::stream_string_list(Cursor::new(payload), |entry| {
                    entries.push(entry.to_owned())
                })?;
                "domain"
            }
            1 => {
                mrs_parser::stream_ipcidr_list(Cursor::new(payload), |net| {
                    entries.push(net.to_string())
                })?;
                "ipcidr"
            }
            _ => bail!("Unsupported MRS behavior"),
        };
        Ok((behavior, entries))
    })();
    result.map_err(|e| MethodError::new("rule_set_invalid", e))
}

pub async fn rule_set(core: &Core, method: &str, arguments: &Value) -> protocol::Result<Value> {
    if method == "dumpRuleSet" {
        return Ok(json!(dump_mrs(&profile::read_bytes(Path::new(
            protocol::string(arguments)?
        ))?)?
        .1
        .join("\n")));
    }
    let name = protocol::field(arguments, "name")?;
    if name.is_empty()
        || name.starts_with('.')
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-' | b'_'))
    {
        return Err(MethodError::new(
            "invalid_arguments",
            "invalid rule set name",
        ));
    }
    let home = core.home.read().clone();
    if home.as_os_str().is_empty() {
        return Err(MethodError::new("not_initialized", "not initialized"));
    }
    let source = home.join("providers").join("rules").join(name);
    contained(&home, &source)?;
    let url = arguments["url"].as_str().unwrap_or("");
    let bytes = if url.is_empty() {
        profile::read_bytes(&source)?
    } else {
        download(core, url, None).await?
    };
    let (info, mrs) = compile_rule_set(&bytes, url.is_empty())?;
    if !url.is_empty() {
        profile::StagedFile::bytes(&source, &bytes)?.commit()?;
    }
    if let Some(mrs) = mrs {
        profile::StagedFile::bytes(&PathBuf::from(format!("{}.mrs", source.display())), &mrs)?
            .commit()?;
    }
    crate::ownership::schedule(&home);
    Ok(info)
}

pub async fn download(core: &Core, url: &str, name: Option<&str>) -> protocol::Result<Vec<u8>> {
    let engine = core.active().ok();
    let proxy = match (name, engine.as_ref()) {
        (Some(name), Some(engine)) if !name.is_empty() && name != "DIRECT" => {
            Some(engine.proxy(name)?)
        }
        (Some(name), None) if !name.is_empty() && name != "DIRECT" => {
            return Err(MethodError::new(
                "not_initialized",
                "Download proxy is not available",
            ))
        }
        _ => None,
    };
    meow_config::internal_http::fetch(url, proxy.as_ref(), &[])
        .await
        .map_err(|e| update_error("", e))
}

pub async fn geo(core: &Core, arguments: &Value) -> protocol::Result<Value> {
    let kind = protocol::string(arguments)?;
    if !matches!(kind, "MMDB" | "ASN" | "GEOIP" | "GEOSITE") {
        return Err(MethodError::new(
            "invalid_arguments",
            format!("unknown geo resource: {kind}"),
        ));
    }
    if kind == "GEOIP" {
        return Err(MethodError::new("unsupported_geo","meow-rs uses Country.mmdb for GeoIP rules and cannot consume geoip.dat; update MMDB instead"));
    }
    let _claim = UpdateClaim::new(core, format!("geo:{kind}")).ok_or_else(|| {
        MethodError::new(
            "core_error",
            format!("geo update already in progress: {kind}"),
        )
    })?;
    core.events
        .push("geoUpdate", json!({"type":kind,"updating":true}));
    let result = async {
        let document = core.document().await;
        let raw = meow_config::parse_raw_yaml(
            &serde_saphyr::to_string(&document).map_err(anyhow::Error::from)?,
        )?;
        let config =
            meow_config::geodata::parse_geodata(raw.geodata.as_ref(), raw.geox_url.as_ref())?;
        let home = core.home.read().clone();
        let (url, path) = match kind {
            "MMDB" => (
                config.mmdb_url,
                config
                    .mmdb_path
                    .unwrap_or_else(|| home.join("Country.mmdb")),
            ),
            "ASN" => (
                config.asn_url,
                config.asn_path.unwrap_or_else(|| home.join("ASN.mmdb")),
            ),
            _ => (
                config.geosite_url,
                config
                    .geosite_path
                    .unwrap_or_else(|| home.join("geosite.dat")),
            ),
        };
        let path = if path.is_absolute() {
            path
        } else {
            home.join(path)
        };
        contained(&home, &path)?;
        let bytes = download(core, &url, config.proxy.as_deref()).await?;
        if kind == "GEOSITE" {
            meow_rules::geosite::GeositeDB::from_bytes(&bytes, None)
                .map_err(anyhow::Error::from)?;
        } else {
            maxminddb::Reader::from_source(bytes.clone()).map_err(anyhow::Error::from)?;
        }
        let old = std::fs::read(&path).ok();
        profile::StagedFile::bytes(&path, &bytes)?.commit()?;
        if let Err(error) = core.rebuild_current().await {
            if let Some(old) = old {
                let _ =
                    profile::StagedFile::bytes(&path, &old).and_then(profile::StagedFile::commit);
            } else {
                let _ = std::fs::remove_file(&path);
            }
            return Err(error);
        }
        crate::ownership::schedule(&home);
        Ok::<(), MethodError>(())
    }
    .await;
    let mut status = json!({"type":kind,"updating":false});
    if let Err(error) = &result {
        status["error"] = json!(error.message);
    }
    core.events.push("geoUpdate", status);
    result?;
    Ok(json!(""))
}

struct UpdateClaim<'a> {
    core: &'a Core,
    key: String,
}
impl<'a> UpdateClaim<'a> {
    fn new(core: &'a Core, key: String) -> Option<Self> {
        if !core.updates.lock().insert(key.clone()) {
            return None;
        }
        Some(Self { core, key })
    }
}
impl Drop for UpdateClaim<'_> {
    fn drop(&mut self) {
        self.core.updates.lock().remove(&self.key);
    }
}
