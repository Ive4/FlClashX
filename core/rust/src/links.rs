use crate::{
    profile,
    protocol::{self, MethodError},
};
use anyhow::{bail, Context, Result};
use base64::{
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD},
    Engine,
};
use serde_json::{json, Value};
use std::{collections::HashMap, path::Path};
use url::Url;

pub fn invoke(method: &str, arguments: &Value) -> protocol::Result<Value> {
    match method {
        "encodeShareLinks" => Ok(json!(protocol::list(arguments)?
            .iter()
            .map(|value| encode(value).unwrap_or_default())
            .collect::<Vec<_>>())),
        "decodeShareLinks" => Ok(json!(protocol::list(arguments)?
            .iter()
            .map(|value| value
                .as_str()
                .and_then(|text| decode_many(text).ok())
                .unwrap_or_default())
            .collect::<Vec<_>>())),
        "convertProxies" => {
            let bytes = profile::read_bytes(Path::new(protocol::string(arguments)?))?;
            Ok(json!(decode_many(
                std::str::from_utf8(&bytes).map_err(anyhow::Error::from)?
            )?))
        }
        _ => Err(MethodError::new(
            "not_implemented",
            "Unknown share-link method",
        )),
    }
}

fn b64(text: &str) -> Result<Vec<u8>> {
    let text = text.trim();
    for engine in [STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD] {
        if let Ok(bytes) = engine.decode(text) {
            return Ok(bytes);
        }
    }
    bail!("Invalid base64 share link")
}

fn unescape(text: &str) -> String {
    let encoded = format!("v={}", text.replace('+', "%2B"));
    url::form_urlencoded::parse(encoded.as_bytes())
        .next()
        .map(|(_, value)| value.into_owned())
        .unwrap_or_default()
}

fn string(value: &Value, key: &str) -> String {
    match &value[key] {
        Value::String(value) => value.clone(),
        Value::Null => String::new(),
        value => value.to_string(),
    }
}

fn flag(value: &Value, key: &str) -> bool {
    value[key]
        .as_bool()
        .unwrap_or_else(|| value[key].as_str() == Some("true"))
}
fn strings(value: &Value, key: &str) -> Vec<String> {
    match &value[key] {
        Value::Array(values) => values
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect(),
        Value::String(value) if !value.is_empty() => vec![value.clone()],
        _ => Vec::new(),
    }
}

pub fn decode_many(text: &str) -> Result<Vec<Value>> {
    let text = text.trim_start_matches('\u{feff}').trim();
    let decoded;
    let text = if !text.contains("://") {
        decoded = String::from_utf8(b64(&text.lines().collect::<String>())?)?;
        decoded.as_str()
    } else {
        text
    };
    let mut proxies = Vec::new();
    let mut names = HashMap::<String, usize>::new();
    for line in text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
    {
        let mut proxy = decode(line)?;
        let name = string(&proxy, "name");
        let count = names.entry(name.clone()).or_default();
        *count += 1;
        if *count > 1 {
            proxy["name"] = json!(format!("{name} ({count})"));
        }
        proxies.push(proxy);
    }
    if proxies.is_empty() {
        bail!("No supported share links found");
    }
    Ok(proxies)
}

pub fn decode(text: &str) -> Result<Value> {
    let (scheme, rest) = text.split_once("://").context("Share link has no scheme")?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme == "ssr" {
        return decode_ssr(rest);
    }
    if scheme == "vmess" && !rest.contains('@') {
        return decode_vmess_json(rest);
    }
    let normalized;
    let text = if scheme == "ss" && !rest.split('#').next().unwrap_or("").contains('@') {
        let (encoded, fragment) = rest.split_once('#').unwrap_or((rest, ""));
        let decoded = String::from_utf8(b64(encoded.trim_end_matches('/'))?)?;
        normalized = format!("ss://{decoded}#{fragment}");
        normalized.as_str()
    } else {
        text
    };
    let range = regex::Regex::new(
        r"^((?:hysteria2|hy2)://(?:[^@/]*@)?(?:\[[^\]]+\]|[^:/?#]+):)([0-9]+(?:[-,][0-9]+)+)([/?#].*|$)",
    )?;
    let mut port_range = String::new();
    let ranged;
    let text = if let Some(captures) = range.captures(text) {
        port_range = captures[2].to_owned();
        let first = port_range.split(['-', ',']).next().unwrap_or("");
        ranged = format!("{}{first}{}", &captures[1], &captures[3]);
        ranged.as_str()
    } else {
        text
    };
    let url = Url::parse(text)?;
    let server = url
        .host_str()
        .context("Share link has no server")?
        .trim_matches(['[', ']']);
    let query = url.query_pairs().into_owned().collect::<HashMap<_, _>>();
    let get = |key: &str| query.get(key).map(String::as_str).unwrap_or("");
    let port = if matches!(scheme.as_str(), "mierus" | "mieru") {
        get("port")
            .split(['-', ','])
            .next()
            .unwrap_or("")
            .parse::<u16>()?
    } else {
        url.port()
            .or_else(|| {
                if matches!(scheme.as_str(), "http" | "https") {
                    url.port_or_known_default()
                } else {
                    None
                }
            })
            .context("Share link has no valid port")?
    };
    let name = url
        .fragment()
        .map(unescape)
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| format!("{server}:{port}"));
    let kind = match scheme.as_str() {
        "hy2" => "hysteria2",
        "socks" | "socks5" => "socks5",
        "https" => "http",
        "mierus" => "mieru",
        other => other,
    };
    let mut proxy = json!({"name":name,"type":kind,"server":server,"port":port,"udp":true});
    if !port_range.is_empty() {
        proxy["ports"] = json!(port_range);
    }
    let user = unescape(url.username());
    let password = url.password().map(unescape).unwrap_or_default();
    match kind {
        "ss" => {
            let credential = if url.password().is_some() {
                format!("{user}:{password}")
            } else {
                String::from_utf8(b64(&user)?)?
            };
            let (cipher, password) = credential
                .split_once(':')
                .context("Shadowsocks link has no cipher/password")?;
            proxy["cipher"] = json!(cipher);
            proxy["password"] = json!(password);
            if get("uot") == "1" {
                proxy["udp-over-tcp"] = json!(true);
            }
            if !get("plugin").is_empty() {
                let mut parts = get("plugin").split(';');
                let plugin = parts.next().unwrap_or("");
                let opts = parts
                    .map(|part| part.split_once('=').unwrap_or((part, "true")))
                    .collect::<HashMap<_, _>>();
                match plugin {
                    "obfs-local" | "simple-obfs" => {
                        proxy["plugin"] = json!("obfs");
                        proxy["plugin-opts"] = json!({"mode":opts.get("obfs").copied().unwrap_or("http"),"host":opts.get("obfs-host").copied().unwrap_or("")});
                    }
                    "v2ray-plugin" => {
                        proxy["plugin"] = json!(plugin);
                        proxy["plugin-opts"] = json!({"mode":opts.get("mode").copied().unwrap_or("websocket"),"host":opts.get("host").copied().unwrap_or(""),"path":opts.get("path").copied().unwrap_or("/"),"tls":opts.contains_key("tls")});
                    }
                    _ => bail!("Unsupported Shadowsocks share-link plugin {plugin}"),
                }
            }
        }
        "vmess" | "vless" => {
            proxy["uuid"] = json!(user);
            if kind == "vmess" {
                proxy["alterId"] = json!(0);
                proxy["cipher"] = json!(if get("encryption").is_empty() {
                    "auto"
                } else {
                    get("encryption")
                });
            } else if !get("encryption").is_empty() {
                proxy["encryption"] = json!(get("encryption"));
            }
            if !get("flow").is_empty() {
                proxy["flow"] = json!(get("flow"));
            }
            if matches!(get("security"), "tls" | "reality") {
                proxy["tls"] = json!(true);
            }
            if get("security") == "reality" {
                proxy["reality-opts"] = json!({"public-key":get("pbk"),"short-id":get("sid")});
            }
            if !get("sni").is_empty() {
                proxy["servername"] = json!(get("sni"));
            }
            if !get("fp").is_empty() {
                proxy["client-fingerprint"] = json!(get("fp"));
            }
            if !get("pcs").is_empty() {
                proxy["fingerprint"] = json!(get("pcs"));
            }
            if !get("alpn").is_empty() {
                proxy["alpn"] = json!(get("alpn").split(',').collect::<Vec<_>>());
            }
            proxy["xudp"] = json!(get("packetEncoding") != "none");
            if get("packetEncoding") == "packet" {
                proxy["packet-addr"] = json!(true);
            }
            decode_transport(&mut proxy, &query)?;
        }
        "trojan" | "anytls" | "hysteria2" => {
            proxy["password"] = json!(if password.is_empty() {
                user
            } else {
                format!("{user}:{password}")
            });
            if !get("sni").is_empty() {
                proxy["sni"] = json!(get("sni"));
            }
            if get("insecure") == "1" || get("allowInsecure") == "1" {
                proxy["skip-cert-verify"] = json!(true);
            }
            if !get("alpn").is_empty() {
                proxy["alpn"] = json!(get("alpn").split(',').collect::<Vec<_>>());
            }
            for (link, key) in [
                ("obfs", "obfs"),
                ("obfs-password", "obfs-password"),
                ("pinSHA256", "fingerprint"),
                ("fp", "client-fingerprint"),
                ("pcs", "fingerprint"),
                ("hpkp", "fingerprint"),
                ("up", "up"),
                ("down", "down"),
            ] {
                if !get(link).is_empty() {
                    proxy[key] = json!(get(link));
                }
            }
            if kind == "trojan" {
                decode_transport(&mut proxy, &query)?;
            }
        }
        "tuic" => {
            if password.is_empty() {
                proxy["token"] = json!(user);
            } else {
                proxy["uuid"] = json!(user);
                proxy["password"] = json!(password);
            }
            for (link, key) in [
                ("sni", "sni"),
                ("congestion_control", "congestion-controller"),
                ("udp_relay_mode", "udp-relay-mode"),
            ] {
                if !get(link).is_empty() {
                    proxy[key] = json!(get(link));
                }
            }
            if get("disable_sni") == "1" {
                proxy["disable-sni"] = json!(true);
            }
            if !get("alpn").is_empty() {
                proxy["alpn"] = json!(get("alpn").split(',').collect::<Vec<_>>());
            }
        }
        "socks5" | "http" => {
            if !user.is_empty() {
                proxy["username"] = json!(user);
            }
            if !password.is_empty() {
                proxy["password"] = json!(password);
            }
            if scheme == "https" {
                proxy["tls"] = json!(true);
            }
        }
        "mieru" => {
            proxy["username"] = json!(user);
            proxy["password"] = json!(password);
            proxy["transport"] = json!(if get("protocol").is_empty() {
                "TCP"
            } else {
                get("protocol")
            });
            if get("port").contains('-') {
                proxy["port-range"] = json!(get("port"));
            }
            for field in ["multiplexing", "handshake-mode", "traffic-pattern"] {
                if !get(field).is_empty() {
                    proxy[field] = json!(get(field));
                }
            }
        }
        "hysteria" => {
            for (link, key) in [
                ("peer", "sni"),
                ("auth", "auth-str"),
                ("obfs", "obfs"),
                ("protocol", "protocol"),
                ("up", "up"),
                ("down", "down"),
            ] {
                if !get(link).is_empty() {
                    proxy[key] = json!(get(link));
                }
            }
            if get("insecure") == "1" {
                proxy["skip-cert-verify"] = json!(true);
            }
            if !get("alpn").is_empty() {
                proxy["alpn"] = json!(get("alpn").split(',').collect::<Vec<_>>());
            }
        }
        _ => bail!("Unsupported share-link scheme {scheme}"),
    }
    Ok(proxy)
}

fn decode_transport(proxy: &mut Value, query: &HashMap<String, String>) -> Result<()> {
    let get = |key: &str| query.get(key).map(String::as_str).unwrap_or("");
    let network = match get("type") {
        "" | "tcp" if get("headerType") == "http" => "http",
        "" | "tcp" => "tcp",
        "http" => "h2",
        other => other,
    };
    match network {
        "tcp" => {}
        "ws" | "httpupgrade" => {
            proxy["network"] = json!(network);
            proxy["ws-opts"] = json!({"path":if get("path").is_empty(){"/"}else{get("path")}});
            if !get("host").is_empty() {
                proxy["ws-opts"]["headers"] = json!({"Host":get("host")});
            }
            if let Ok(early) = get("ed").parse::<u32>() {
                proxy["ws-opts"]["max-early-data"] = json!(early);
            }
            if !get("eh").is_empty() {
                proxy["ws-opts"]["early-data-header-name"] = json!(get("eh"));
            }
        }
        "grpc" => {
            proxy["network"] = json!("grpc");
            proxy["grpc-opts"] = json!({"grpc-service-name":get("serviceName")});
        }
        "h2" => {
            proxy["network"] = json!("h2");
            proxy["h2-opts"] = json!({"path":get("path"),"host":get("host").split(',').filter(|s|!s.is_empty()).collect::<Vec<_>>()});
        }
        "http" => {
            proxy["network"] = json!("http");
            proxy["http-opts"] = json!({"path":[get("path")],"headers":{"Host":[get("host")]},"method":if get("method").is_empty(){"GET"}else{get("method")}});
        }
        "xhttp" => {
            proxy["network"] = json!("xhttp");
            proxy["xhttp-opts"] = json!({"path":get("path"),"host":get("host"),"mode":get("mode")});
        }
        _ => bail!("Unsupported share-link transport {network}"),
    }
    Ok(())
}

fn decode_vmess_json(rest: &str) -> Result<Value> {
    let data: Value = serde_json::from_slice(&b64(rest)?)?;
    let port = string(&data, "port").parse::<u16>()?;
    let mut proxy = json!({"type":"vmess","name":string(&data,"ps"),"server":string(&data,"add"),"port":port,"uuid":string(&data,"id"),"alterId":string(&data,"aid").parse::<u16>().unwrap_or(0),"cipher":if string(&data,"scy").is_empty(){"auto".to_owned()}else{string(&data,"scy")},"udp":true});
    if proxy["name"] == "" {
        proxy["name"] = json!(format!("{}:{port}", string(&data, "add")));
    }
    if matches!(string(&data, "tls").as_str(), "tls" | "true") {
        proxy["tls"] = json!(true);
    }
    for (source, target) in [("sni", "servername"), ("fp", "client-fingerprint")] {
        if !string(&data, source).is_empty() {
            proxy[target] = json!(string(&data, source));
        }
    }
    if !string(&data, "alpn").is_empty() {
        proxy["alpn"] = json!(string(&data, "alpn").split(',').collect::<Vec<_>>());
    }
    let network = string(&data, "net");
    let mut query = HashMap::from([
        (
            "type".into(),
            if network == "h2" {
                "http".into()
            } else {
                network
            },
        ),
        ("path".into(), string(&data, "path")),
        ("host".into(), string(&data, "host")),
        ("serviceName".into(), string(&data, "path")),
    ]);
    if string(&data, "type") == "http" {
        query.insert("headerType".into(), "http".into());
        query.insert("type".into(), "tcp".into());
    }
    decode_transport(&mut proxy, &query)?;
    Ok(proxy)
}

fn decode_ssr(rest: &str) -> Result<Value> {
    let decoded = String::from_utf8(b64(rest)?)?;
    let (authority, query) = decoded.split_once("/?").unwrap_or((&decoded, ""));
    let fields = authority.split(':').collect::<Vec<_>>();
    if fields.len() != 6 {
        bail!("Invalid SSR server address");
    }
    let query = url::form_urlencoded::parse(query.as_bytes())
        .into_owned()
        .collect::<HashMap<_, _>>();
    let value = |key: &str| -> String {
        query
            .get(key)
            .and_then(|v| b64(v).ok())
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .unwrap_or_default()
    };
    Ok(
        json!({"type":"ssr","name":value("remarks"),"server":fields[0],"port":fields[1].parse::<u16>()?,"protocol":fields[2],"cipher":fields[3],"obfs":fields[4],"password":String::from_utf8(b64(fields[5])?)?,"obfs-param":value("obfsparam"),"protocol-param":value("protoparam"),"udp":true}),
    )
}

pub fn encode(proxy: &Value) -> Result<String> {
    let kind = string(proxy, "type");
    if kind == "mieru" {
        return encode_mieru(proxy);
    }
    let server = string(proxy, "server");
    if server.is_empty() {
        bail!("No server");
    }
    let port = string(proxy, "port").parse::<u16>()?;
    let host = if server.contains(':') {
        format!("[{server}]")
    } else {
        server
    };
    let name = string(proxy, "name");
    let mut query = Vec::<(String, String)>::new();
    let mut add = |key: &str, value: String| {
        if !value.is_empty() {
            query.push((key.into(), value));
        }
    };
    let scheme = match kind.as_str() {
        "http" if flag(proxy, "tls") => "https",
        other => other,
    };
    let (user, password) = match kind.as_str() {
        "ss" => {
            if flag(proxy, "udp-over-tcp") {
                add("uot", "1".into());
            }
            let opts = &proxy["plugin-opts"];
            match string(proxy, "plugin").as_str() {
                "" => {}
                "obfs" => add(
                    "plugin",
                    format!(
                        "obfs-local;obfs={};obfs-host={}",
                        string(opts, "mode"),
                        string(opts, "host")
                    ),
                ),
                "v2ray-plugin" => add(
                    "plugin",
                    format!(
                        "v2ray-plugin;mode={};host={};path={}{}",
                        string(opts, "mode"),
                        string(opts, "host"),
                        string(opts, "path"),
                        if flag(opts, "tls") { ";tls" } else { "" }
                    ),
                ),
                _ => bail!("Unsupported Shadowsocks plugin"),
            }
            (string(proxy, "cipher"), Some(string(proxy, "password")))
        }
        "ssr" => {
            if host.contains(':') {
                bail!("SSR does not support IPv6 share links");
            }
            let encode = |value: &str| URL_SAFE_NO_PAD.encode(value);
            let payload = format!(
                "{}:{}:{}:{}:{}:{}/?obfsparam={}&protoparam={}&remarks={}",
                host,
                port,
                string(proxy, "protocol"),
                string(proxy, "cipher"),
                string(proxy, "obfs"),
                encode(&string(proxy, "password")),
                encode(&string(proxy, "obfs-param")),
                encode(&string(proxy, "protocol-param")),
                encode(&name)
            );
            return Ok(format!("ssr://{}", encode(&payload)));
        }
        "vmess" | "vless" => {
            if kind == "vmess" && proxy["alterId"].as_u64().unwrap_or(0) > 0 {
                let network = string(proxy, "network");
                let opts = match network.as_str() {
                    "ws" | "httpupgrade" => &proxy["ws-opts"],
                    "grpc" => &proxy["grpc-opts"],
                    "h2" => &proxy["h2-opts"],
                    _ => &Value::Null,
                };
                let data = json!({"v":"2","ps":name,"add":host.trim_matches(['[',']']),"port":port.to_string(),"id":string(proxy,"uuid"),"aid":string(proxy,"alterId"),"scy":string(proxy,"cipher"),"net":if network.is_empty(){"tcp"}else{&network},"type":"none","path":if network=="grpc"{string(opts,"grpc-service-name")}else{string(opts,"path")},"host":string(&opts["headers"],"Host"),"tls":if flag(proxy,"tls"){"tls"}else{""},"sni":string(proxy,"servername"),"fp":string(proxy,"client-fingerprint"),"alpn":strings(proxy,"alpn").join(",")});
                return Ok(format!(
                    "vmess://{}",
                    STANDARD.encode(serde_json::to_vec(&data)?)
                ));
            }
            if flag(proxy, "tls") {
                let reality = &proxy["reality-opts"];
                if !string(reality, "public-key").is_empty() {
                    add("security", "reality".into());
                    add("pbk", string(reality, "public-key"));
                    add("sid", string(reality, "short-id"));
                } else {
                    add("security", "tls".into());
                }
            }
            for (field, key) in [
                ("servername", "sni"),
                ("client-fingerprint", "fp"),
                ("fingerprint", "pcs"),
                ("flow", "flow"),
                ("encryption", "encryption"),
            ] {
                add(key, string(proxy, field));
            }
            add("alpn", strings(proxy, "alpn").join(","));
            if flag(proxy, "packet-addr") {
                add("packetEncoding", "packet".into());
            } else if !flag(proxy, "xudp") {
                add("packetEncoding", "none".into());
            }
            transport_query(proxy, &mut query)?;
            (string(proxy, "uuid"), None)
        }
        "trojan" | "anytls" | "hysteria2" => {
            for (field, key) in [
                ("sni", "sni"),
                ("client-fingerprint", "fp"),
                ("obfs", "obfs"),
                ("obfs-password", "obfs-password"),
                ("up", "up"),
                ("down", "down"),
            ] {
                add(key, string(proxy, field));
            }
            if flag(proxy, "skip-cert-verify") {
                add(
                    if kind == "trojan" {
                        "allowInsecure"
                    } else {
                        "insecure"
                    },
                    "1".into(),
                );
            }
            add("alpn", strings(proxy, "alpn").join(","));
            add(
                if kind == "hysteria2" {
                    "pinSHA256"
                } else if kind == "anytls" {
                    "hpkp"
                } else {
                    "pcs"
                },
                string(proxy, "fingerprint"),
            );
            if kind == "hysteria2" && proxy["realm-opts"]["enable"] == true {
                bail!("Hysteria2 realm/port ranges cannot round-trip this share link");
            }
            if kind == "trojan" {
                transport_query(proxy, &mut query)?;
            }
            (string(proxy, "password"), None)
        }
        "tuic" => {
            for (field, key) in [
                ("sni", "sni"),
                ("congestion-controller", "congestion_control"),
                ("udp-relay-mode", "udp_relay_mode"),
            ] {
                add(key, string(proxy, field));
            }
            add("alpn", strings(proxy, "alpn").join(","));
            if flag(proxy, "disable-sni") {
                add("disable_sni", "1".into());
            }
            if !string(proxy, "uuid").is_empty() {
                (string(proxy, "uuid"), Some(string(proxy, "password")))
            } else {
                (string(proxy, "token"), None)
            }
        }
        "http" | "socks5" => (string(proxy, "username"), Some(string(proxy, "password"))),
        "hysteria" => {
            for (field, key) in [
                ("sni", "peer"),
                ("obfs", "obfs"),
                ("auth-str", "auth"),
                ("protocol", "protocol"),
                ("up", "up"),
                ("down", "down"),
            ] {
                add(key, string(proxy, field));
            }
            add("alpn", strings(proxy, "alpn").join(","));
            if flag(proxy, "skip-cert-verify") {
                add("insecure", "1".into());
            }
            (String::new(), None)
        }
        _ => bail!("No share-link encoding for {kind}"),
    };
    let mut url = Url::parse(&format!("{scheme}://{host}:{port}"))?;
    if !user.is_empty() || password.as_deref().is_some_and(|v| !v.is_empty()) {
        url.set_username(&user)
            .map_err(|_| anyhow::anyhow!("Invalid username"))?;
        url.set_password(password.as_deref())
            .map_err(|_| anyhow::anyhow!("Invalid password"))?;
    }
    if !query.is_empty() {
        url.query_pairs_mut().extend_pairs(query);
    }
    if !name.is_empty() {
        url.set_fragment(Some(&name));
    }
    let result = url.to_string();
    if kind == "hysteria2" && !string(proxy, "ports").is_empty() {
        if host.starts_with('[') {
            bail!("IPv6 port ranges cannot round-trip this share link");
        }
        return Ok(result.replacen(
            &format!("{host}:{port}"),
            &format!("{host}:{}", string(proxy, "ports")),
            1,
        ));
    }
    Ok(result)
}

fn encode_mieru(proxy: &Value) -> Result<String> {
    let server = string(proxy, "server");
    let host = if server.contains(':') {
        format!("[{server}]")
    } else {
        server
    };
    let mut url = Url::parse(&format!("mierus://{host}"))?;
    url.set_username(&string(proxy, "username"))
        .map_err(|_| anyhow::anyhow!("Invalid username"))?;
    url.set_password(Some(&string(proxy, "password")))
        .map_err(|_| anyhow::anyhow!("Invalid password"))?;
    let range = string(proxy, "port-range");
    let port = if range.is_empty() {
        string(proxy, "port")
    } else {
        range
    };
    if port.is_empty() {
        bail!("Mieru link has no port");
    }
    let transport = string(proxy, "transport");
    url.query_pairs_mut()
        .append_pair("port", &port)
        .append_pair(
            "protocol",
            if transport.is_empty() {
                "TCP"
            } else {
                &transport
            },
        );
    for field in ["multiplexing", "handshake-mode", "traffic-pattern"] {
        let value = string(proxy, field);
        if !value.is_empty() {
            url.query_pairs_mut().append_pair(field, &value);
        }
    }
    url.set_fragment(Some(&string(proxy, "name")));
    Ok(url.to_string())
}

fn transport_query(proxy: &Value, query: &mut Vec<(String, String)>) -> Result<()> {
    let network = string(proxy, "network");
    let mut add = |key: &str, value: String| {
        if !value.is_empty() {
            query.push((key.into(), value));
        }
    };
    match network.as_str() {
        "" | "tcp" => {}
        "ws" | "httpupgrade" => {
            let opts = &proxy["ws-opts"];
            add("type", network);
            add("path", string(opts, "path"));
            add("host", string(&opts["headers"], "Host"));
            if opts["max-early-data"].as_u64().unwrap_or(0) > 0 {
                add("ed", string(opts, "max-early-data"));
            }
            add("eh", string(opts, "early-data-header-name"));
        }
        "grpc" => {
            add("type", "grpc".into());
            add(
                "serviceName",
                string(&proxy["grpc-opts"], "grpc-service-name"),
            );
        }
        "h2" => {
            add("type", "http".into());
            add("path", string(&proxy["h2-opts"], "path"));
            add("host", strings(&proxy["h2-opts"], "host").join(","));
        }
        "http" => {
            add("type", "tcp".into());
            add("headerType", "http".into());
            add(
                "path",
                strings(&proxy["http-opts"], "path")
                    .first()
                    .cloned()
                    .unwrap_or_default(),
            );
            add(
                "host",
                strings(&proxy["http-opts"]["headers"], "Host")
                    .first()
                    .cloned()
                    .unwrap_or_default(),
            );
            add("method", string(&proxy["http-opts"], "method"));
        }
        "xhttp" => {
            add("type", "xhttp".into());
            for field in ["path", "host", "mode"] {
                add(field, string(&proxy["xhttp-opts"], field));
            }
        }
        _ => bail!("No share-link encoding for transport {network}"),
    }
    Ok(())
}
