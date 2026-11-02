use crate::protocol::{self, MethodError};
use meow_dns::upstream::NameServerEntry;
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Debug, Default)]
pub struct ValidatedDirectDns {
    pub nameservers: Vec<NameServerEntry>,
    pub follow_policy: bool,
}

pub fn supported_field(key: &str) -> bool {
    matches!(key, "direct-nameserver" | "direct-nameserver-follow-policy")
}

pub fn validate(document: &Value) -> protocol::Result<ValidatedDirectDns> {
    validate_for_platform(
        document,
        cfg!(any(target_os = "android", target_env = "ohos")),
    )
}

fn validate_for_platform(document: &Value, mobile: bool) -> protocol::Result<ValidatedDirectDns> {
    let mut effective;
    let document = if mobile {
        effective = document.clone();
        crate::mobile::patch_system_dns(&mut effective);
        &effective
    } else {
        document
    };
    let dns = &document["dns"];
    let follow_policy = match dns.get("direct-nameserver-follow-policy") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(value)) => *value,
        _ => {
            return Err(invalid(
                "dns.direct-nameserver-follow-policy",
                "expected a boolean",
            ))
        }
    };
    let values = match dns.get("direct-nameserver") {
        None | Some(Value::Null) => {
            return Ok(ValidatedDirectDns {
                follow_policy,
                ..Default::default()
            })
        }
        Some(Value::Array(values)) => values,
        _ => {
            return Err(invalid(
                "dns.direct-nameserver",
                "expected a resolver URL list",
            ))
        }
    };
    let proxy_names: HashSet<&str> = ["proxies", "proxy-groups"]
        .iter()
        .filter_map(|key| document[key].as_array())
        .flatten()
        .filter_map(|entry| entry["name"].as_str())
        .collect();
    let nameservers = values
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let path = format!("dns.direct-nameserver[{index}]");
            let value = value
                .as_str()
                .ok_or_else(|| invalid(&path, "expected a resolver URL string"))?;
            let entry = meow_config::dns_parser::parse_direct_nameserver_entry(value, |name| {
                matches!(
                    name,
                    "DIRECT"
                        | "COMPATIBLE"
                        | "GLOBAL"
                        | "REJECT"
                        | "REJECT-DROP"
                        | "PASS"
                        | "PASS-RULE"
                ) || proxy_names.contains(name)
            })
            .map_err(|_| invalid(&path, "unsupported or invalid resolver URL"))?;
            Ok(entry)
        })
        .collect::<protocol::Result<Vec<_>>>()?;
    Ok(ValidatedDirectDns {
        nameservers,
        follow_policy,
    })
}

fn invalid(path: &str, reason: &str) -> MethodError {
    MethodError::new("unsupported_config", format!("{path}: {reason}"))
        .details(json!({"path":path}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_typed_resolver_urls_and_follow_policy_without_io() {
        let parsed = validate(&json!({"dns":{
            "direct-nameserver":["1.1.1.1", "[::1]:5353", "tcp://resolver.example:5353", "https://resolver.example/dns-query#tls.example", "tls://[::1]:853", "tcp://127.0.0.1:5353#upstream", "https://resolver.example/dns-query?proxy=upstream"],
            "direct-nameserver-follow-policy":true,
        }})).unwrap();
        assert_eq!(parsed.nameservers.len(), 7);
        assert!(parsed.follow_policy);
        assert!(supported_field("direct-nameserver"));
        assert!(supported_field("direct-nameserver-follow-policy"));
        assert!(!supported_field("nameserver"));
        let empty = validate(&json!({"dns":{"direct-nameserver":[]}})).unwrap();
        assert!(empty.nameservers.is_empty());
        assert!(!empty.follow_policy);
    }

    #[test]
    fn rejects_invalid_direct_dns_at_its_path_without_endpoint_values() {
        for (dns, path) in [
            (
                json!({"direct-nameserver":"private.invalid"}),
                "dns.direct-nameserver",
            ),
            (json!({"direct-nameserver":[2]}), "dns.direct-nameserver[0]"),
            (
                json!({"direct-nameserver":["quic://private.invalid"]}),
                "dns.direct-nameserver[0]",
            ),
            (
                json!({"direct-nameserver":["system"]}),
                "dns.direct-nameserver[0]",
            ),
            (
                json!({"direct-nameserver":["https://private.invalid/dns-query#absent-route"]}),
                "dns.direct-nameserver[0]",
            ),
            (
                json!({"direct-nameserver-follow-policy":"true"}),
                "dns.direct-nameserver-follow-policy",
            ),
        ] {
            let error = validate_for_platform(&json!({"dns":dns}), false).unwrap_err();
            assert_eq!(error.code, "unsupported_config");
            assert_eq!(error.details["path"], path);
            assert!(!serde_json::to_string(&error)
                .unwrap()
                .contains("private.invalid"));
        }
    }

    #[test]
    fn encrypted_proxy_fragments_preserve_the_raw_url_and_default_sni() {
        let mut document = json!({"proxy-groups":[{"name":"dns-route.example"}],"dns":{"direct-nameserver":["https://private.invalid/dns-query#dns-route.example"]}});
        let original = document.clone();
        let parsed = validate(&document).unwrap();
        assert_eq!(
            parsed.nameservers[0].proxy.as_deref(),
            Some("dns-route.example")
        );
        let meow_dns::NameServerUrl::Https { sni, .. } = &parsed.nameservers[0].url else {
            panic!("expected DoH");
        };
        assert_eq!(sni, "private.invalid");
        assert_eq!(document, original);
        document["dns"]["direct-nameserver"][0] =
            json!("https://private.invalid/dns-query#dns-route.example?proxy=other-route");
        assert_eq!(
            validate(&document).unwrap().nameservers[0].proxy.as_deref(),
            Some("other-route")
        );
    }

    #[test]
    fn mobile_system_dns_validation_rewrites_only_a_copy_and_empty_network_fails_closed() {
        let document =
            json!({"dns":{"direct-nameserver":["system"],"direct-nameserver-follow-policy":true}});
        let original = document.clone();
        crate::mobile::set_system_dns("192.0.2.53,2001:db8::53");
        let parsed = validate_for_platform(&document, true).unwrap();
        assert_eq!(parsed.nameservers.len(), 2);
        assert!(parsed.follow_policy);
        assert!(
            matches!(&parsed.nameservers[0].url, meow_dns::NameServerUrl::Udp { addr:meow_dns::HostOrIp::Ip(ip), .. } if ip.is_ipv4())
        );
        assert!(
            matches!(&parsed.nameservers[1].url, meow_dns::NameServerUrl::Udp { addr:meow_dns::HostOrIp::Ip(ip), .. } if ip.is_ipv6())
        );
        crate::mobile::set_system_dns("");
        let empty = validate_for_platform(&document, true).unwrap();
        assert!(matches!(
            empty.nameservers[0].url,
            meow_dns::NameServerUrl::RCode { .. }
        ));
        assert!(validate_for_platform(&document, false).is_err());
        assert_eq!(document, original);
    }
}
