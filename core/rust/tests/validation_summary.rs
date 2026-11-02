use flclash::extras;
use serde_json::json;
use std::collections::BTreeSet;

#[test]
fn all_effectful_field_gaps_are_reported_without_altering_config_or_exposing_later_values() {
    let document = json!({
        "unimplemented-feature":true,
        "dns":{"unsupported-dns-feature":"private-resolver-url","fallback-filter":{"unsupported-filter":"private-domain"}},
        "tun":{"unsupported-tun-feature":true,"strict-route":true},
        "proxy-providers":{"nodes":{"type":"file","path":"nodes.yaml","override":{"udp":true}}},
        "listeners":[{"name":"local","type":"http","port":7890,"users":["private-listener-secret"]}],
        "proxies":[{"name":"node","type":"ss","server":"127.0.0.1","port":1234,"cipher":"aes-128-gcm","password":"private-node-secret","tfo":true,"mptcp":true,"smux":{"statistic":true,"brutal-opts":{"secret":"private-mux-secret"}}}]
    });
    let original = document.clone();
    let error = extras::validate(&document).unwrap_err();
    assert_eq!(document, original);
    assert_eq!(error.code, "unsupported_config");
    assert_eq!(error.details["path"], "unimplemented-feature");
    assert_eq!(error.details["value"], true);
    let paths: BTreeSet<_> = error.details["unsupported-paths"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    assert_eq!(
        paths,
        BTreeSet::from([
            "unimplemented-feature",
            "dns.unsupported-dns-feature",
            "dns.fallback-filter.unsupported-filter",
            "tun.unsupported-tun-feature",
            "tun.strict-route",
            "proxy-providers.nodes.override.udp",
            "listeners[0].users",
            "proxies.node.tfo",
            "proxies.node.mptcp",
            "proxies.node.smux.statistic",
            "proxies.node.smux.brutal-opts",
        ])
    );
    assert_eq!(error.details["unsupported-path-count"], 11);
    assert_eq!(error.details["unsupported-paths-truncated"], false);
    let encoded = serde_json::to_string(&error).unwrap();
    for private in [
        "private-resolver-url",
        "private-domain",
        "private-listener-secret",
        "private-node-secret",
        "private-mux-secret",
    ] {
        assert!(!encoded.contains(private));
    }
}

#[test]
fn unsupported_path_summary_is_bounded_and_inert_values_remain_inert() {
    let mut document =
        json!({"dns":{"unsupported-empty":[],"unsupported-off":false},"tun":{"unknown-empty":[]}});
    assert!(extras::validate(&document).is_ok());
    for index in 0..200 {
        document[format!("unsupported-{index}")] = json!(true);
    }
    let error = extras::validate(&document).unwrap_err();
    assert_eq!(error.details["unsupported-path-count"], 200);
    assert_eq!(
        error.details["unsupported-paths"].as_array().unwrap().len(),
        128
    );
    assert_eq!(error.details["unsupported-paths-truncated"], true);
}
