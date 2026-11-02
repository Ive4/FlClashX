use async_trait::async_trait;
use flclash::{
    mobile,
    mobile_tun::{self, Owner, OwnerResolver, TunOptions},
    ohos::{token_matches, OwnerBroker, RunSettings},
};
use meow_common::Network;
use serde_json::json;
use std::{net::SocketAddr, sync::Arc, time::Duration};

#[test]
fn tun_settings_validate_real_device_inputs() {
    let options = TunOptions::parse(
        "10.0.0.1/30,fd00::1/126",
        "10.0.0.2,fd00::2",
        r#"{"mtu":1500}"#,
    )
    .unwrap();
    assert_eq!(options.mtu, 1500);
    assert!(options.hijacks_dns("10.0.0.2:53".parse().unwrap()));
    assert!(options.hijacks_dns("[fd00::2]:53".parse().unwrap()));
    assert!(!options.hijacks_dns("8.8.8.8:53".parse().unwrap()));
    assert!(!options.hijacks_dns("10.0.0.2:443".parse().unwrap()));
    let wildcard = TunOptions::parse("10.0.0.1/30", "0.0.0.0,::", "{}").unwrap();
    assert!(wildcard.hijacks_dns("8.8.8.8:53".parse().unwrap()));
    assert!(wildcard.hijacks_dns("[2001:4860:4860::8888]:53".parse().unwrap()));
    for address in ["", "10.0.0.1", "10.0.0.1/33", "fd00::1/129"] {
        assert!(TunOptions::parse(address, "", "{}").is_err());
    }
    assert!(TunOptions::parse("10.0.0.1/30", "invalid", "{}").is_err());
    assert!(TunOptions::parse("10.0.0.1/30", "", r#"{"mtu":0}"#).is_err());
}

#[test]
fn network_dns_updates_replace_only_dns_sentinels() {
    mobile::set_system_dns("192.0.2.53,2001:db8::53,192.0.2.53");
    let document = json!({"proxies":[{"name":"system"}], "dns":{
        "nameserver":["https://resolver.example/dns-query","system"],
        "direct-nameserver":["system://"],
        "nameserver-policy":{"example.test":["system://"]}
    }});
    let mut first = document.clone();
    mobile::patch_system_dns(&mut first);
    assert_eq!(first["proxies"], document["proxies"]);
    assert_eq!(
        first["dns"]["direct-nameserver"],
        json!(["udp://192.0.2.53:53", "udp://[2001:db8::53]:53"])
    );
    assert!(flclash::direct_dns::validate(&first).is_ok());
    assert_eq!(
        first["dns"]["nameserver"],
        json!([
            "https://resolver.example/dns-query",
            "udp://192.0.2.53:53",
            "udp://[2001:db8::53]:53"
        ])
    );
    mobile::set_system_dns("198.51.100.53");
    let mut moved = document.clone();
    mobile::patch_system_dns(&mut moved);
    assert_eq!(
        moved["dns"]["direct-nameserver"],
        json!(["udp://198.51.100.53:53"])
    );
    assert_eq!(
        moved["dns"]["nameserver-policy"]["example.test"],
        json!(["udp://198.51.100.53:53"])
    );
    mobile::set_system_dns("");
    let mut offline = document;
    mobile::patch_system_dns(&mut offline);
    assert_eq!(offline["dns"]["nameserver"][1], "rcode://refused");
    assert_eq!(
        offline["dns"]["direct-nameserver"],
        json!(["rcode://refused"])
    );
    assert!(flclash::direct_dns::validate(&offline).is_ok());
}

#[test]
fn embedded_control_requires_loopback_and_fixed_token() {
    let token = "01".repeat(32);
    assert!(RunSettings {
        address: "127.0.0.1:1234".into(),
        token: token.clone(),
        control: String::new()
    }
    .validate()
    .is_ok());
    for address in [
        "0.0.0.0:1234",
        "192.0.2.1:1234",
        "127.0.0.1:0",
        "localhost:1234",
    ] {
        assert!(RunSettings {
            address: address.into(),
            token: token.clone(),
            control: String::new()
        }
        .validate()
        .is_err());
    }
    assert!(token_matches(token.as_bytes(), token.as_bytes()));
    let mut changed = token.clone().into_bytes();
    changed[63] ^= 1;
    assert!(!token_matches(token.as_bytes(), &changed));
    assert!(!token_matches(token.as_bytes(), &changed[..63]));
}

struct KnownOwner;
#[async_trait]
impl OwnerResolver for KnownOwner {
    async fn resolve(&self, protocol: u8, source: SocketAddr, target: SocketAddr) -> Option<Owner> {
        assert_eq!(protocol, 17);
        assert_eq!(source, "10.0.0.2:12345".parse().unwrap());
        assert_eq!(target, "198.18.0.9:443".parse().unwrap());
        Some(Owner {
            uid: 12345,
            package: "org.example.browser".into(),
        })
    }
}

#[tokio::test]
async fn process_metadata_keeps_original_tuple_and_uid_before_fake_ip_rewrite() {
    mobile::prepare();
    let value = mobile_tun::metadata(
        Network::Udp,
        "10.0.0.2:12345".parse().unwrap(),
        "198.18.0.9:443".parse().unwrap(),
        &KnownOwner,
    )
    .await;
    assert_eq!(value.uid, Some(12345));
    assert_eq!(value.process, "org.example.browser");
    assert_eq!(value.process_path, "org.example.browser");
    assert!(meow_common::process_lookup::uid_info_available());
}

#[tokio::test]
async fn owner_broker_bounds_pending_work_and_ignores_stale_answers() {
    let broker = Arc::new(OwnerBroker::default());
    let source = "10.0.0.2:12345".parse().unwrap();
    let target = "198.18.0.9:443".parse().unwrap();
    let mut jobs = Vec::new();
    for _ in 0..64 {
        let broker = broker.clone();
        jobs.push(tokio::spawn(async move {
            broker.lookup(6, source, target).await
        }));
    }
    let mut requests = Vec::new();
    tokio::time::timeout(Duration::from_millis(200), async {
        while requests.len() < 64 {
            requests.extend(broker.take());
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert!(broker.lookup(6, source, target).await.is_none());
    for request in &requests {
        broker.answer(request.id, 12345, "org.example.browser".into());
    }
    for job in jobs {
        assert_eq!(job.await.unwrap().unwrap().uid, 12345);
    }
    assert!(broker.take().is_empty());
    broker.answer(requests[0].id, 999, "late.answer".into());
    let broker_clone = broker.clone();
    let cancelled = tokio::spawn(async move { broker_clone.lookup(17, source, target).await });
    tokio::task::yield_now().await;
    cancelled.abort();
    let _ = cancelled.await;
    assert!(broker.take().is_empty());
}

#[test]
fn android_java_abi_matches_rust_jni_exports() {
    let native = include_str!("../src/mobile.rs");
    let java = include_str!(
        "../../../android/core/src/main/java/com/follow/clash/core/mobile/Mobile.java"
    );
    for method in [
        "backupCodec",
        "invokeMethod",
        "quickSetup",
        "setEventListener",
        "startTun",
        "stopTun",
        "startListener",
        "stopListener",
        "forceGC",
        "updateDns",
        "resetNetwork",
        "getTraffic",
        "getTotalTraffic",
    ] {
        assert!(
            native.contains(&format!(
                "Java_com_follow_clash_core_mobile_Mobile_{method}("
            )),
            "Missing JNI {method}"
        );
        assert!(
            java.contains(&format!(" {method}(")),
            "Missing Java {method}"
        );
    }
}

#[tokio::test]
async fn preconfig_tun_keeps_reject_policy_and_disk_until_real_setup_commits() {
    use flclash::{core::Core, probe};
    use serde_json::Value;
    use tokio::net::TcpListener;
    async fn call(core: &Core, method: &str, arguments: Value) -> Value {
        serde_json::from_slice(
            &core
                .invoke(
                    &serde_json::to_vec(
                        &json!({"id":"bootstrap","method":method,"arguments":arguments}),
                    )
                    .unwrap(),
                    core.next_sequence(),
                )
                .await,
        )
        .unwrap()
    }
    let home = tempfile::tempdir().unwrap();
    let original = b"not: [valid YAML";
    let config = home.path().join("config.yaml");
    std::fs::write(&config, original).unwrap();
    let core = Core::new();
    assert!(core.prepare_mobile_tunnel().await.is_err());
    assert_eq!(
        call(
            &core,
            "initClash",
            json!({"home-dir":home.path(),"version":35})
        )
        .await["result"],
        true
    );
    assert!(core.prepare_mobile_tunnel().await.is_err());
    assert_eq!(
        call(&core, "startListener", Value::Null).await["result"],
        true
    );
    let engine = core.prepare_mobile_tunnel().await.unwrap();
    assert_eq!(std::fs::read(&config).unwrap(), original);
    assert!(probe::exit(&engine, "bootstrap.invalid:443", "")
        .await
        .unwrap()
        .contains("REJECT"));
    let occupied = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let profile = home.path().join("profile.yaml");
    let candidate = json!({"mode":"direct","mixed-port":occupied.local_addr().unwrap().port(),"dns":{"enable":false},"rules":["MATCH,DIRECT"]});
    let yaml = serde_saphyr::to_string(&candidate).unwrap();
    std::fs::write(&profile, &yaml).unwrap();
    let failed = call(
        &core,
        "setupConfig",
        json!({"base":{"path":profile,"overlay":yaml}}),
    )
    .await;
    assert!(
        failed["error"].is_object()
            || failed["result"]
                .as_str()
                .is_some_and(|value| !value.is_empty()),
        "{failed}"
    );
    assert_eq!(std::fs::read(&config).unwrap(), original);
    assert!(probe::exit(&engine, "bootstrap.invalid:443", "")
        .await
        .unwrap()
        .contains("REJECT"));
    let mut candidate = candidate;
    candidate["mixed-port"] = json!(0);
    let yaml = serde_saphyr::to_string(&candidate).unwrap();
    std::fs::write(&profile, &yaml).unwrap();
    let setup = call(
        &core,
        "setupConfig",
        json!({"base":{"path":profile,"overlay":yaml}}),
    )
    .await;
    assert_eq!(setup["result"], "", "{setup}");
    assert!(Arc::ptr_eq(&engine, &core.active().unwrap()));
    assert!(probe::exit(&engine, "bootstrap.invalid:443", "")
        .await
        .unwrap()
        .contains("DIRECT"));
    core.shutdown().await;
}
