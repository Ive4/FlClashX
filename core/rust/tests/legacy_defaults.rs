use flclash::extras;
use serde_json::{json, Value};

fn desktop_defaults() -> Value {
    json!({
        "allow-lan":false,
        "lan-allowed-ips":["0.0.0.0/0","::/0"],
        "external-controller":"",
        "external-controller-cors":{"allow-origins":["*"],"allow-private-network":true},
        "etag-support":true,
        "tuic-server":{"enable":false,"listen":"","token":null,"certificate":"","private-key":"","max-idle-time":15000,"authentication-timeout":1000,"alpn":["h3"],"max-udp-relay-packet-size":1500},
        "experimental":{"fingerprints":null,"quic-go-disable-gso":false,"quic-go-disable-ecn":true,"dialer-ip4p-convert":false},
        "tls":{"certificate":"","private-key":"","client-auth-type":"","client-auth-cert":"","ech-key":"","custom-certifactes":null},
        "clash-for-android":{"append-system-dns":false,"ui-subtitle-pattern":""},
        "tun":{"enable":false,"recvmsgx":true,"processors-per-channel":1},
        "dns":{"enable":false},
        "proxy-providers":{},"rule-providers":{},
        "proxies":[],"proxy-groups":[],"rules":["MATCH,DIRECT"]
    })
}

#[test]
fn inactive_serialized_defaults_keep_the_original_document() {
    let document = desktop_defaults();
    let original = document.clone();
    let result = extras::validate(&document);
    if cfg!(target_os = "macos") {
        let error = result.unwrap_err();
        assert_eq!(error.details["unsupported-paths"], json!(["tun.recvmsgx"]));
    } else {
        assert!(result.is_ok(), "{result:?}");
    }
    assert_eq!(document, original);
}

#[test]
fn active_or_different_settings_are_still_explicit_failures() {
    let mut base = desktop_defaults();
    base["tun"]["recvmsgx"] = json!(false);
    for (path, patch) in [
        (
            "lan-allowed-ips",
            json!({"lan-allowed-ips":["192.0.2.0/24"]}),
        ),
        (
            "external-controller-cors",
            json!({"external-controller":"127.0.0.1:19090"}),
        ),
        (
            "etag-support",
            json!({"proxy-providers":{"remote":{"type":"http","url":"http://127.0.0.1:19091/nodes","path":"nodes.yaml"}}}),
        ),
        (
            "etag-support",
            json!({"rule-providers":{"remote":{"type":"http","url":"http://127.0.0.1:19091/rules","path":"rules.yaml","behavior":"domain"}}}),
        ),
        ("tuic-server", json!({"tuic-server":{"enable":true}})),
        (
            "experimental",
            json!({"dns":{"enable":true,"prefer-h3":true,"nameserver":["https://127.0.0.1/dns-query"]}}),
        ),
        (
            "experimental",
            json!({"experimental":{"dialer-ip4p-convert":true}}),
        ),
        ("tls", json!({"tls":{"certificate":"private-cert"}})),
        (
            "clash-for-android",
            json!({"clash-for-android":{"append-system-dns":true}}),
        ),
        (
            "tun.processors-per-channel",
            json!({"tun":{"processors-per-channel":2}}),
        ),
    ] {
        let mut document = base.clone();
        flclash::profile::patch(&mut document, &patch);
        let original = document.clone();
        let error = extras::validate(&document).unwrap_err();
        assert_eq!(error.code, "unsupported_config", "{path}: {error:?}");
        assert!(
            error.details["unsupported-paths"]
                .as_array()
                .unwrap()
                .contains(&json!(path)),
            "{path}: {error:?}"
        );
        assert_eq!(document, original);
    }
}
