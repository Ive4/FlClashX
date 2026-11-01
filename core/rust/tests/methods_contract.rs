use flclash::{core::Core, events::Events, profile, protocol};
use serde_json::{json, Value};
use std::sync::atomic::Ordering;

async fn invoke(core: &Core, method: &str, arguments: Value, sequence: u64) -> Value {
    serde_json::from_slice(
        &core
            .invoke(
                &serde_json::to_vec(&json!({"id":"call-1","method":method,"arguments":arguments}))
                    .unwrap(),
                sequence,
            )
            .await,
    )
    .unwrap()
}

#[tokio::test]
async fn init_registers_home_without_touching_config_or_creating_an_engine() {
    let home = tempfile::tempdir().unwrap();
    let original = b"not: [valid YAML";
    std::fs::write(home.path().join("config.yaml"), original).unwrap();
    let core = Core::new();
    let result = invoke(
        &core,
        "initClash",
        json!({"home-dir":home.path(),"version":35}),
        1,
    )
    .await;
    assert_eq!(result, json!({"id":"call-1","result":true}));
    assert_eq!(
        std::fs::read(home.path().join("config.yaml")).unwrap(),
        original
    );
    assert!(core.engine.read().is_none());
    assert_eq!(
        invoke(&core, "getIsInit", Value::Null, 2).await["result"],
        true
    );
    assert_eq!(
        invoke(&core, "getTraffic", json!(true), 3).await["result"],
        json!({"up":0,"down":0})
    );
    assert_eq!(
        invoke(&core, "getProxies", Value::Null, 4).await["result"],
        json!({"proxies":{},"all":[]})
    );
    core.shutdown().await;
}

#[tokio::test]
async fn newest_watch_intent_survives_an_older_call_finishing_later() {
    let core = Core::new();
    core.events.enabled.store(true, Ordering::Release);
    assert!(invoke(&core, "watchRoute", json!(false), 20)
        .await
        .get("error")
        .is_none());
    assert!(invoke(&core, "watchRoute", json!(true), 19)
        .await
        .get("error")
        .is_none());
    core.route_changed(false);
    assert!(core.events.batch().is_none());
    invoke(&core, "watchRoute", json!(true), 21).await;
    core.route_changed(false);
    let event: Value = serde_json::from_slice(&core.events.batch().unwrap()).unwrap();
    assert_eq!(event["method"], "message");
    assert_eq!(event["arguments"][0]["type"], "routeChanged");
    core.shutdown().await;
}

#[tokio::test]
async fn errors_and_native_json_values_keep_the_go_envelope() {
    let core = Core::new();
    let response = invoke(&core, "watchRoute", json!("false"), 1).await;
    assert_eq!(response["error"]["code"], "invalid_arguments");
    assert_eq!(response["result"], Value::Null);
    assert_eq!(response["id"], "call-1");
    let response = invoke(&core, "unrecognized", json!({"nested":true}), 2).await;
    assert_eq!(response["error"]["code"], "not_implemented");
    let response = invoke(&core, "getConfig", json!(123), 3).await;
    assert_eq!(response["error"]["code"], "invalid_arguments");
    let broken: Value = serde_json::from_slice(&core.invoke(b"{", 4).await).unwrap();
    assert_eq!(broken["error"]["code"], "invalid_arguments");
}

#[test]
fn dns_and_traffic_bursts_cannot_evict_request_events() {
    let events = Events::default();
    events.enabled.store(true, Ordering::Relaxed);
    for index in 0..256 {
        events.push("request", json!({"id":index}));
    }
    for _ in 0..300 {
        events.push("dns", json!({}));
        events.push("requestTraffic", json!([]));
    }
    events.push("geoUpdate", json!({"type":"MMDB","updating":false}));
    let first: Value = serde_json::from_slice(&events.batch().unwrap()).unwrap();
    assert_eq!(first["arguments"][0]["type"], "geoUpdate");
    let mut requests = first["arguments"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|event| event["type"] == "request")
        .count();
    while let Some(bytes) = events.batch() {
        let batch: Value = serde_json::from_slice(&bytes).unwrap();
        requests += batch["arguments"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|event| event["type"] == "request")
            .count();
    }
    assert_eq!(requests, 256);
}

#[test]
fn profile_merge_keeps_outbounds_and_places_overlay_rules_first() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("profile.yaml");
    std::fs::write(&path,"mode: direct\nproxies:\n  - {name: custom, type: direct}\nproxy-groups: []\nrules:\n - MATCH,DIRECT\nsub-rules: {}\n").unwrap();
    let merged = profile::merge(
        &json!({"path":path,"overlay":"mode: rule\nrules:\n - DOMAIN,example.com,DIRECT\n"}),
        home.path(),
    )
    .unwrap();
    assert_eq!(merged["mode"], "rule");
    assert_eq!(merged["proxies"][0]["name"], "custom");
    assert_eq!(merged["rules"][0], "DOMAIN,example.com,DIRECT");
    assert_eq!(merged["rules"][1], "MATCH,DIRECT");
    let base = profile::base(path.to_str().unwrap()).unwrap();
    assert_eq!(base["digest"].as_str().unwrap().len(), 64);
    assert_eq!(base["proxies"], 1);
    assert!(base["config"].get("proxies").is_none());
}

#[test]
fn profile_parser_handles_aliases_order_and_duplicate_key_rejection() {
    let document=profile::parse("base: &base {type: direct}\nproxies:\n - <<: *base\n   name: node\nhosts:\n  b.example: 1.1.1.1\n  a.example: 8.8.8.8\n").unwrap();
    assert_eq!(document["proxies"][0]["type"], "direct");
    assert_eq!(
        document["hosts"]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>(),
        vec!["b.example", "a.example"]
    );
    assert!(profile::parse("mode: rule\nmode: direct").is_err());
    assert!(profile::parse("[1, 2, 3]").is_err());
}

#[test]
fn staged_file_drop_leaves_the_last_good_config_intact() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("config.yaml");
    std::fs::write(&path, b"old").unwrap();
    let staged = profile::StagedFile::bytes(&path, b"new").unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"old");
    drop(staged);
    assert_eq!(std::fs::read(&path).unwrap(), b"old");
    profile::StagedFile::bytes(&path, b"new")
        .unwrap()
        .commit()
        .unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"new");
}

#[test]
fn runtime_masks_network_listeners_without_mutating_the_saved_document() {
    let document = json!({"mixed-port":7890,"dns":{"enable":true,"listen":"127.0.0.1:5353"},"tun":{"enable":true,"stack":"gvisor"},"external-controller":"127.0.0.1:9090","proxies":[{"type":"direct","name":"n"}]});
    let runtime = profile::runtime_document(&document, false, false).unwrap();
    assert!(runtime.get("mixed-port").is_none());
    assert!(runtime.get("external-controller").is_none());
    assert!(runtime["dns"].get("listen").is_none());
    assert_eq!(runtime["tun"]["enable"], false);
    assert_eq!(document["tun"]["enable"], true);
    assert_eq!(runtime["strict"], true);
}

#[test]
fn response_has_no_double_encoded_result_or_empty_optional_fields() {
    let bytes = protocol::encode(protocol::Response {
        id: Some("1".into()),
        result: json!({"items":[true,1]}),
        error: None,
        file: None,
    });
    assert_eq!(
        serde_json::from_slice::<Value>(&bytes).unwrap(),
        json!({"id":"1","result":{"items":[true,1]}})
    );
}
