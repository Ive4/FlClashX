use serde_json::Value;

pub(crate) fn accepts(document: &Value, path: &str, value: &Value) -> bool {
    match path {
        "lan-allowed-ips" => unrestricted_lan(value),
        "external-controller-cors" => {
            value.is_object()
                && [
                    "external-controller",
                    "external-controller-tls",
                    "external-controller-unix",
                    "external-controller-pipe",
                ]
                .iter()
                .all(|key| inactive(&document[key]))
        }
        "etag-support" => value.as_bool() == Some(true) && !http_providers(document),
        "tuic-server" => value.is_object() && value["enable"].as_bool() == Some(false),
        "tls" | "clash-for-android" => inactive(value),
        "experimental" => value.as_object().is_some_and(|options| {
            options.iter().all(|(key, value)| match key.as_str() {
                "fingerprints" | "quic-go-disable-gso" | "dialer-ip4p-convert" => inactive(value),
                "quic-go-disable-ecn" => {
                    inactive(value) || value.as_bool() == Some(true) && !quic_transport(document)
                }
                _ => false,
            })
        }),
        // These syscall hints apply only to the old Darwin packet pump.
        "tun.recvmsgx" | "tun.sendmsgx" => !cfg!(target_os = "macos") && value.is_boolean(),
        "tun.processors-per-channel" => value.as_u64() == Some(1),
        _ => false,
    }
}

fn inactive(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::Bool(value) => !value,
        Value::Number(value) => value.as_u64() == Some(0),
        Value::String(value) => value.is_empty(),
        Value::Array(value) => value.is_empty(),
        Value::Object(value) => value.values().all(inactive),
    }
}

fn unrestricted_lan(value: &Value) -> bool {
    let Some(values) = value.as_array() else {
        return false;
    };
    let (mut v4, mut v6) = (false, false);
    for value in values {
        let Some(network) = value
            .as_str()
            .and_then(|value| value.parse::<ipnet::IpNet>().ok())
        else {
            return false;
        };
        match network {
            ipnet::IpNet::V4(network) => v4 |= network.prefix_len() == 0,
            ipnet::IpNet::V6(network) => v6 |= network.prefix_len() == 0,
        }
    }
    v4 && v6
}

fn http_providers(document: &Value) -> bool {
    ["proxy-providers", "rule-providers"].iter().any(|key| {
        document[key].as_object().is_some_and(|providers| {
            providers
                .values()
                .any(|provider| provider["type"].as_str() == Some("http"))
        })
    })
}

fn quic_transport(document: &Value) -> bool {
    if ["proxy-providers", "rule-providers"].iter().any(|key| {
        document[key]
            .as_object()
            .is_some_and(|value| !value.is_empty())
    }) {
        return true;
    }
    let proxies = document["proxies"].as_array().is_some_and(|proxies| {
        proxies.iter().any(|proxy| {
            !matches!(
                proxy["type"].as_str(),
                Some(
                    "direct"
                        | "reject"
                        | "ss"
                        | "socks5"
                        | "http"
                        | "vless"
                        | "vmess"
                        | "trojan"
                        | "anytls"
                        | "ssh"
                )
            ) || proxy["network"].as_str() == Some("quic")
        })
    });
    proxies
        || document["dns"]["prefer-h3"].as_bool() == Some(true)
        || contains_quic(&document["dns"])
}

fn contains_quic(value: &Value) -> bool {
    match value {
        Value::String(value) => value.starts_with("h3://") || value.starts_with("quic://"),
        Value::Array(value) => value.iter().any(contains_quic),
        Value::Object(value) => value.values().any(contains_quic),
        _ => false,
    }
}
