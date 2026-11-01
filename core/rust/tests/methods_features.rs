use flclash::{extras, links, profile, service_checks};
use serde_json::{json, Value};

#[test]
fn unsupported_effectful_options_are_not_silently_discarded() {
    let error = extras::validate(&json!({"redir-port":7892})).unwrap_err();
    assert_eq!(error.code, "unsupported_config");
    assert_eq!(error.details["path"], "redir-port");
    let error = extras::validate(&json!({"dns":{"respect-rules":true}})).unwrap_err();
    assert_eq!(error.details["path"], "dns.respect-rules");
    let error =
        extras::validate(&json!({"tun":{"enable":true,"route-exclude-address":["10.0.0.0/8"]}}))
            .unwrap_err();
    assert_eq!(error.details["path"], "tun.route-exclude-address");
    for key in [
        "shadow-tls",
        "res-tls",
        "jls-config",
        "kcp-tun",
        "mux-option",
        "users",
        "authentication",
    ] {
        let mut listener = json!({"name":"encrypted-in","type":"shadowsocks","listen":"127.0.0.1","port":7890,"cipher":"aes-256-gcm","password":"test"});
        listener[key] = json!({"enabled":true});
        let error = extras::validate(&json!({"listeners":[listener]})).unwrap_err();
        assert_eq!(error.code, "unsupported_config");
        assert_eq!(error.details["path"], format!("listeners[0].{key}"));
    }
}

#[test]
fn static_unknown_proxy_is_a_real_validation_failure() {
    assert!(!extras::validate_proxy_message(&json!({"name":"n","type":"not-a-proxy"})).is_empty());
    assert!(extras::validate(&json!({"proxies":[{"name":"n","type":"not-a-proxy"}]})).is_err());
    assert!(extras::validate_proxy_message(&json!({"name":"DIRECT","type":"direct"})).is_empty());
    assert!(extras::validate_proxy_message(&json!({"name":"n","type":"direct"})).contains("alias"));
}

#[test]
fn request_metadata_matches_flutter_string_ports_and_dns_enum() {
    let mut request =
        json!({"metadata":{"sourcePort":1234,"destinationPort":443,"dnsMode":"FakeIp","uid":null}});
    extras::normalize_tracker(&mut request);
    assert_eq!(request["metadata"]["sourcePort"], "1234");
    assert_eq!(request["metadata"]["destinationPort"], "443");
    assert_eq!(request["metadata"]["dnsMode"], "fake-ip");
}

#[test]
fn filter_contract_supports_lookarounds_and_separated_patterns() {
    assert!(extras::validate_filter_message(&json!(r"(?i)(?<![a-z])hk(?![a-z])")).is_empty());
    assert!(!extras::validate_filter_message(&json!(format!("ok{}[", char::from(96)))).is_empty());
}

#[test]
fn mrs_compile_roundtrips_real_domain_and_binary_ipcidr_payloads() {
    for (text, behavior, expected) in [
        (
            "payload:\n - '+.example.com'\n - example.net\n",
            "domain",
            vec!["+.example.com", "example.net"],
        ),
        (
            "1.1.1.0/24\n2001:db8::/32\n",
            "ipcidr",
            vec!["1.1.1.0/24", "2001:db8::/32"],
        ),
    ] {
        let (info, mrs) = extras::compile_rule_set(text.as_bytes(), false).unwrap();
        assert_eq!(info["behavior"], behavior);
        let bytes = mrs.unwrap();
        let (decoded, entries) = extras::dump_mrs(&bytes).unwrap();
        assert_eq!(decoded, behavior);
        assert_eq!(entries, expected);
        let (info, encoded) = extras::compile_rule_set(&bytes, false).unwrap();
        assert_eq!(info["format"], "mrs");
        assert!(encoded.is_none());
    }
    assert_eq!(
        extras::compile_rule_set(b"1.1.1.0/24\nexample.com", false)
            .unwrap_err()
            .code,
        "rule_set_mixed"
    );
    assert_eq!(
        extras::compile_rule_set(b"# no rules", false)
            .unwrap_err()
            .code,
        "rule_set_empty"
    );
    assert_eq!(
        extras::dump_mrs(b"MRS!invalid").unwrap_err().code,
        "rule_set_invalid"
    );
}

#[test]
fn shares_preserve_credentials_ipv6_reality_and_websocket_transport() {
    let mappings = [
        json!({"name":"香港 + 1","type":"ss","server":"2001:db8::1","port":443,"cipher":"aes-256-gcm","password":"p@ss:word","plugin":"obfs","plugin-opts":{"mode":"tls","host":"cdn.example"}}),
        json!({"name":"reality","type":"vless","server":"example.net","port":443,"uuid":"u-1","tls":true,"servername":"cdn.example","flow":"xtls-rprx-vision","reality-opts":{"public-key":"pub","short-id":"001234"},"network":"ws","ws-opts":{"path":"/path","headers":{"Host":"cdn.example"},"max-early-data":2048}}),
        json!({"name":"anytls","type":"anytls","server":"example.net","port":443,"password":"pass:word","sni":"cdn.example","skip-cert-verify":true}),
    ];
    for mapping in mappings {
        let encoded = links::encode(&mapping).unwrap();
        let decoded = links::decode(&encoded).unwrap();
        for key in ["name", "type", "server", "port"] {
            assert_eq!(decoded[key], mapping[key], "{key}: {encoded}");
        }
        if mapping.get("password").is_some() {
            assert_eq!(decoded["password"], mapping["password"]);
        }
        if mapping.get("reality-opts").is_some() {
            assert_eq!(decoded["reality-opts"], mapping["reality-opts"]);
            assert_eq!(decoded["ws-opts"], mapping["ws-opts"]);
        }
    }
}

#[test]
fn encoded_subscriptions_and_per_line_errors_keep_array_contract() {
    use base64::Engine;
    let link = "ss://YWVzLTI1Ni1nY206c2VjcmV0@example.com:8388#first";
    let subscription = base64::engine::general_purpose::STANDARD.encode(format!("{link}\n{link}"));
    assert_eq!(links::decode_many(&subscription).unwrap().len(), 2);
    let result = links::invoke("decodeShareLinks", &json!([link, "invalid"])).unwrap();
    assert_eq!(result[0][0]["password"], "secret");
    assert_eq!(result[1], json!([]));
    assert_eq!(
        links::invoke("encodeShareLinks", &json!([{"type":"direct","name":"n"}])).unwrap(),
        json!([""])
    );
}

#[test]
fn mieru_and_hysteria_port_range_links_roundtrip() {
    for mapping in [
        json!({"type":"mieru","name":"m","server":"example.com","port-range":"1000-2000","username":"user","password":"pass","transport":"TCP","multiplexing":"MULTIPLEXING_HIGH"}),
        json!({"type":"hysteria2","name":"h","server":"example.com","port":443,"ports":"443-449,8443","password":"pass"}),
    ] {
        let link = links::encode(&mapping).unwrap();
        let decoded = links::decode(&link).unwrap();
        assert_eq!(decoded["type"], mapping["type"]);
        assert_eq!(decoded["name"], mapping["name"]);
        assert_eq!(decoded["password"], mapping["password"]);
        for field in ["port-range", "ports"] {
            if mapping.get(field).is_some() {
                assert_eq!(decoded[field], mapping[field]);
            }
        }
    }
}

#[test]
fn service_results_follow_go_region_and_unlock_rules() {
    let youtube = service_checks::evaluate(
        "youtube",
        &json!({"status-code":200,"body":"YouTube Premium ad-free \"GL\":\"US\""}),
    );
    assert_eq!(youtube["status"], "available");
    assert_eq!(youtube["region"], "US");
    let youtube = service_checks::evaluate(
        "youtube",
        &json!({"status-code":200,"body":"YouTube Premium is not available in your country"}),
    );
    assert_eq!(youtube["status"], "unsupported-region");
    assert_eq!(
        service_checks::evaluate("claude", &json!({"status-code":200,"body":"loc=CN\n"}))["status"],
        "unsupported-region"
    );
    assert_eq!(
        service_checks::evaluate(
            "prime-video",
            &json!({"status-code":200,"body":"unknown page"})
        )["status"],
        "failed"
    );
    assert_eq!(
        service_checks::evaluate(
            "bilibili",
            &json!({"status-code":200,"body":"{\"code\":-10403}"})
        )["status"],
        "unsupported-region"
    );
    assert_eq!(service_checks::normalize_region("JPN"), "JP");
    assert_eq!(service_checks::normalize_region("unknown"), "");
}

#[test]
fn ip_race_rejects_captcha_private_and_shared_addresses() {
    for body in [
        "captcha",
        "192.168.0.1",
        "127.0.0.1",
        "100.64.0.1",
        "fc00::1",
        "fe80::1",
    ] {
        assert!(!service_checks::mentions_ip(body), "{body}");
    }
    for body in ["{\"ip\":\"8.8.8.8\"}", "address=2606:4700:4700::1111"] {
        assert!(service_checks::mentions_ip(body), "{body}");
    }
}

#[test]
fn profile_age_passthrough_is_exact_for_unencrypted_content() {
    let plain = b"proxies: []\nrules: []\n";
    assert_eq!(
        profile::decrypt_bytes(plain, "not an age key").unwrap(),
        plain
    );
    assert!(profile::decrypt_bytes(b"-----BEGIN AGE ENCRYPTED FILE-----\n", "").is_err());
}

#[test]
fn numeric_short_ids_fail_without_silently_changing_the_literal() {
    assert!(
        profile::parse("proxies: [{reality-opts: {short-id: 001234}}]")
            .unwrap_err()
            .to_string()
            .contains("quote")
    );
    let profile = profile::parse("proxies: [{reality-opts: {short-id: '001234'}}]").unwrap();
    assert_eq!(profile["proxies"][0]["reality-opts"]["short-id"], "001234");
}

#[test]
fn backup_codec_preserves_compression_and_authenticated_encryption_contract() {
    use base64::{engine::general_purpose::STANDARD, Engine};
    let call = |operation: &str, data: &[u8], password: &str| -> Value {
        serde_json::from_slice(&flclash::backup::handle(&serde_json::to_vec(&json!({"version":1,"operation":operation,"data":STANDARD.encode(data),"password":password})).unwrap())).unwrap()
    };
    let data = b"configuration backup contents";
    let compressed = call("compress", data, "");
    let expanded = call(
        "decompress",
        &STANDARD
            .decode(compressed["data"].as_str().unwrap())
            .unwrap(),
        "",
    );
    assert_eq!(
        STANDARD.decode(expanded["data"].as_str().unwrap()).unwrap(),
        data
    );
    let encrypted = call("encrypt", data, "correct horse battery");
    let envelope = STANDARD
        .decode(encrypted["data"].as_str().unwrap())
        .unwrap();
    let decrypted = call("decrypt", &envelope, "correct horse battery");
    assert_eq!(
        STANDARD
            .decode(decrypted["data"].as_str().unwrap())
            .unwrap(),
        data
    );
    assert_eq!(
        call("decrypt", &envelope, "wrong password")["error"],
        "decryption"
    );
}
