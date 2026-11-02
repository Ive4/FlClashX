use flclash::{
    extras,
    mobile_tun::TunOptions,
    tun_routes::{self, OsRoutePlan, RouteLists},
};
use ipnet::IpNet;
use serde_json::json;

async fn call(
    core: &flclash::core::Core,
    method: &str,
    arguments: serde_json::Value,
) -> serde_json::Value {
    serde_json::from_slice(
        &core
            .invoke(
                &serde_json::to_vec(&json!({"id":"routes","method":method,"arguments":arguments}))
                    .unwrap(),
                core.next_sequence(),
            )
            .await,
    )
    .unwrap()
}

async fn setup(
    core: &flclash::core::Core,
    home: &std::path::Path,
    document: &serde_json::Value,
) -> serde_json::Value {
    let path = home.join("source.yaml");
    std::fs::write(&path, serde_saphyr::to_string(document).unwrap()).unwrap();
    call(
        core,
        "setupConfig",
        json!({"base":{"path":path,"overlay":serde_saphyr::to_string(document).unwrap()}}),
    )
    .await
}

fn nets(values: &[&str]) -> Vec<IpNet> {
    values.iter().map(|value| value.parse().unwrap()).collect()
}

fn strings(values: &[IpNet]) -> Vec<String> {
    values.iter().map(ToString::to_string).collect()
}

#[test]
fn include_minus_exclude_is_canonical_for_both_families() {
    for (include, exclude, expected) in [
        (
            vec!["10.0.0.7/24", "10.0.0.0/25", "10.0.0.0/24"],
            vec!["10.0.0.64/26", "10.0.0.80/28", "192.0.2.0/24"],
            vec!["10.0.0.0/26", "10.0.0.128/25"],
        ),
        (
            vec!["2001:db8::/124"],
            vec!["2001:db8::4/126", "2001:db8::f/128"],
            vec![
                "2001:db8::/126",
                "2001:db8::8/126",
                "2001:db8::c/127",
                "2001:db8::e/128",
            ],
        ),
        (
            vec!["0.0.0.0/0", "::/0"],
            vec!["0.0.0.0/1", "::/1"],
            vec!["128.0.0.0/1", "8000::/1"],
        ),
        (
            vec!["10.0.0.0/8", "fd00::/8"],
            vec!["0.0.0.0/0", "::/0"],
            vec![],
        ),
        (
            vec![
                "255.255.255.254/31",
                "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe/127",
            ],
            vec![
                "255.255.255.255/32",
                "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128",
            ],
            vec![
                "255.255.255.254/32",
                "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe/128",
            ],
        ),
    ] {
        assert_eq!(
            strings(&tun_routes::subtract(&nets(&include), &nets(&exclude))),
            expected
        );
    }
}

#[test]
fn cidr_failures_identify_the_exact_field_and_value() {
    for (tun, path, value) in [
        (
            json!({"route-address":"10.0.0.0/8"}),
            "tun.route-address",
            json!("10.0.0.0/8"),
        ),
        (
            json!({"route-address":[false]}),
            "tun.route-address[0]",
            json!(false),
        ),
        (
            json!({"route-exclude-address":["10.0.0.0/8", "fd00::/129"]}),
            "tun.route-exclude-address[1]",
            json!("fd00::/129"),
        ),
        (
            json!({"route-exclude-address":["1.2.3.4/33"]}),
            "tun.route-exclude-address[0]",
            json!("1.2.3.4/33"),
        ),
        (
            json!({"route-address":["10.0.0.1"]}),
            "tun.route-address[0]",
            json!("10.0.0.1"),
        ),
    ] {
        let error = extras::validate(&json!({"tun":tun})).unwrap_err();
        assert_eq!(error.code, "invalid_config");
        assert_eq!(error.details["path"], path);
        assert_eq!(error.details["value"], value);
        assert!(error.message.contains(path));
    }
}

#[test]
fn validated_lists_preserve_defaults_empty_selections_and_split_default_routes() {
    assert_eq!(
        RouteLists::parse(&json!({}))
            .unwrap()
            .desktop_plan(&nets(&["0.0.0.0/1", "128.0.0.0/1"]), false)
            .unwrap(),
        None
    );
    let lists = RouteLists::parse(&json!({"route-exclude-address":["10.0.0.0/8"]})).unwrap();
    let plan = lists
        .desktop_plan(&nets(&["0.0.0.0/1", "128.0.0.0/1"]), false)
        .unwrap()
        .unwrap();
    for address in ["10.0.0.0", "10.1.2.3", "10.255.255.255"] {
        let address: std::net::IpAddr = address.parse().unwrap();
        assert!(plan.iter().all(|route| !route.contains(&address)));
    }
    for address in [
        "9.255.255.255",
        "11.0.0.0",
        "192.168.1.1",
        "255.255.255.255",
    ] {
        let address: std::net::IpAddr = address.parse().unwrap();
        assert_eq!(
            plan.iter().filter(|route| route.contains(&address)).count(),
            1
        );
    }
    let all = RouteLists::parse(&json!({"route-address":["0.0.0.0/0", "::/0"]})).unwrap();
    assert_eq!(
        strings(&all.desktop_plan(&[], true).unwrap().unwrap()),
        ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"]
    );
    assert!(all.desktop_plan(&[], false).is_err());
    let empty = RouteLists::parse(&json!({"route-exclude-address":["0.0.0.0/0", "::/0"]})).unwrap();
    assert_eq!(
        empty
            .desktop_plan(&nets(&["0.0.0.0/0", "::/0"]), true)
            .unwrap(),
        Some(vec![])
    );
    let error = extras::validate(
        &json!({"tun":{"enable":true,"auto-route":false,"route-address":["10.0.0.0/8"]}}),
    )
    .unwrap_err();
    assert_eq!(error.details["path"], "tun.auto-route");
}

fn installed(routes: Vec<IpNet>, ipv6: bool) -> OsRoutePlan {
    let mut routes = routes;
    routes.push("172.19.0.2/32".parse().unwrap());
    OsRoutePlan { routes, ipv6 }
}

#[test]
fn mobile_accepts_only_the_route_selection_installed_by_the_native_owner() {
    let document = json!({"tun":{"route-exclude-address":["10.0.0.0/8", "172.16.0.0/12", "fc00::/7", "::1/128"]}});
    let lists = RouteLists::parse(&document["tun"]).unwrap();
    for ipv6 in [false, true] {
        let defaults = if ipv6 {
            nets(&["0.0.0.0/0", "::/0"])
        } else {
            nets(&["0.0.0.0/0"])
        };
        let native = installed(lists.routes(&defaults), ipv6);
        tun_routes::validate_mobile(&document, Some(&native)).unwrap();
        let mut wrong = native.clone();
        wrong.routes.push("10.0.0.0/8".parse().unwrap());
        let error = tun_routes::validate_mobile(&document, Some(&wrong)).unwrap_err();
        assert_eq!(error.code, "unsupported_config");
        assert!(!error.details["expected"].as_array().unwrap().is_empty());
    }
    assert!(tun_routes::validate_mobile(&document, None).is_err());
    tun_routes::validate_mobile(&json!({}), None).unwrap();
    let only_v6 = json!({"tun":{"route-address":["2001:db8::/32"]}});
    assert!(tun_routes::validate_mobile(&only_v6, Some(&installed(vec![], false))).is_err());
    let empty = json!({"tun":{"route-exclude-address":["0.0.0.0/0", "::/0"]}});
    tun_routes::validate_mobile(&empty, Some(&installed(vec![], true))).unwrap();
    assert!(tun_routes::validate_mobile(
        &empty,
        Some(&installed(nets(&["0.0.0.0/0", "::/0"]), true))
    )
    .is_err());
}

#[test]
fn installed_route_metadata_is_validated_with_the_vpn_addresses() {
    let options = json!({"routes":["0.0.0.0/1", "128.0.0.0/1", "172.19.0.2/32"],"ipv6":false});
    let parsed = TunOptions::parse("172.19.0.1/30", "172.19.0.2", &options.to_string()).unwrap();
    assert_eq!(parsed.os_routes.unwrap().routes, nets(&["0.0.0.0/0"]));
    for bad in [
        json!({"routes":[],"ipv6":"false"}),
        json!({"routes":["::/0"],"ipv6":false}),
        json!({"routes":["bad"],"ipv6":true}),
        json!({"ipv6":false}),
    ] {
        assert!(OsRoutePlan::parse(&bad).is_err(), "{bad}");
    }
    assert!(TunOptions::parse(
        "172.19.0.1/30,fdfe:dcba:9876::1/126",
        "",
        &options.to_string()
    )
    .is_err());
}

#[tokio::test]
async fn rejected_route_setup_preserves_the_saved_profile_and_running_engine() {
    let home = tempfile::tempdir().unwrap();
    let core = flclash::core::Core::new();
    assert_eq!(
        call(
            &core,
            "initClash",
            json!({"home-dir":home.path(),"version":35})
        )
        .await["result"],
        true
    );
    let document = json!({"mixed-port":0,"dns":{"enable":false},"rules":["MATCH,REJECT"],"tun":{"enable":false}});
    assert_eq!(setup(&core, home.path(), &document).await["result"], "");
    let original = std::fs::read(home.path().join("config.yaml")).unwrap();
    let engine = core.active().unwrap();
    let mut invalid = document.clone();
    invalid["tun"]["route-exclude-address"] = json!(["10.0.0.0/8", "fd00::/129"]);
    let error = setup(&core, home.path(), &invalid).await;
    assert_eq!(error["error"]["code"], "invalid_config", "{error}");
    assert_eq!(
        std::fs::read(home.path().join("config.yaml")).unwrap(),
        original
    );
    assert_eq!(core.document().await["tun"], document["tun"]);
    assert!(std::sync::Arc::ptr_eq(&engine, &core.active().unwrap()));
    core.shutdown().await;
}

#[cfg(unix)]
#[tokio::test]
async fn mismatched_native_attach_fails_before_touching_the_fd_or_saved_profile() {
    let home = tempfile::tempdir().unwrap();
    let core = flclash::core::Core::new();
    assert_eq!(
        call(
            &core,
            "initClash",
            json!({"home-dir":home.path(),"version":35})
        )
        .await["result"],
        true
    );
    let document = json!({"mixed-port":0,"dns":{"enable":false},"rules":["MATCH,REJECT"],"tun":{"enable":false,"route-exclude-address":["10.0.0.0/8"]}});
    assert_eq!(setup(&core, home.path(), &document).await["result"], "");
    assert_eq!(
        call(&core, "startListener", serde_json::Value::Null).await["result"],
        true
    );
    let original = std::fs::read(home.path().join("config.yaml")).unwrap();
    let engine = core.active().unwrap();
    let options = TunOptions::parse(
        "172.19.0.1/30",
        "172.19.0.2",
        r#"{"routes":["0.0.0.0/0"],"ipv6":false}"#,
    )
    .unwrap();
    let error = core
        .attach_mobile_tunnel(
            -1,
            options,
            std::sync::Arc::new(flclash::ohos::OwnerBroker::default()),
        )
        .await
        .unwrap_err();
    assert_eq!(error.code, "unsupported_config");
    assert!(error.message.contains("do not match"));
    assert_eq!(
        std::fs::read(home.path().join("config.yaml")).unwrap(),
        original
    );
    assert_eq!(core.document().await["tun"], document["tun"]);
    assert!(std::sync::Arc::ptr_eq(&engine, &core.active().unwrap()));
    core.shutdown().await;
}

#[cfg(not(any(target_os = "android", target_env = "ohos")))]
#[tokio::test]
async fn desktop_listener_consumes_the_exact_validated_route_plan_without_starting_a_device() {
    use flclash::engine::Engine;
    use meow_listener::{TunListener, TunListenerConfig, TunRouteScope};
    use std::time::Duration;
    let home = tempfile::tempdir().unwrap();
    let (logs, _) = tokio::sync::broadcast::channel(16);
    let engine = Engine::create(
        &json!({"rules":["MATCH,REJECT"],"dns":{"enable":false},"tun":{"enable":false}}),
        home.path(),
        logs,
    )
    .await
    .unwrap();
    let config = TunListenerConfig {
        device: None,
        mtu: 1500,
        inet4_address: "172.19.0.1/30".parse().unwrap(),
        inet6_address: Some("fdfe:dcba:9876::1/126".parse().unwrap()),
        auto_route: true,
        route_scope: TunRouteScope::Global,
        outbound_interface: None,
        dns_hijack: false,
        udp_timeout: Duration::from_secs(60),
        max_connections: 64,
    };
    let lists = RouteLists::parse(&json!({"route-address":["10.0.0.0/24","2001:db8::/124"],"route-exclude-address":["10.0.0.64/26","2001:db8::4/126"]})).unwrap();
    let expected = nets(&[
        "10.0.0.0/26",
        "10.0.0.128/25",
        "2001:db8::/126",
        "2001:db8::8/125",
    ]);
    let plan = lists
        .desktop_plan(&config.default_routes(None), true)
        .unwrap()
        .unwrap();
    let listener = TunListener::new(
        engine.state.tunnel.clone(),
        config.clone(),
        "route-test".into(),
    )
    .with_route_plan(plan)
    .unwrap();
    assert_eq!(listener.route_nets(false), expected);
    assert_eq!(listener.route_nets(true), expected);
    drop(listener);
    let defaults = TunListener::new(
        engine.state.tunnel.clone(),
        config.clone(),
        "scope-test".into(),
    );
    assert_eq!(defaults.route_nets(false), config.default_routes(None));
    assert_eq!(defaults.route_nets(true), vec![]);
    let mut fake = config.clone();
    fake.route_scope = TunRouteScope::FakeIp;
    assert_eq!(
        fake.default_routes(Some("198.18.0.0/16".parse().unwrap())),
        nets(&["198.18.0.0/16"])
    );
    let mut off = config;
    off.auto_route = false;
    assert!(
        TunListener::new(engine.state.tunnel.clone(), off, "off".into())
            .with_route_plan(expected)
            .is_err()
    );
    engine.shutdown().await;
}
