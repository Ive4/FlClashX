use flclash::{core::Core, profile};
use meow_common::{ConnType, Metadata, RuleMatchHelper};
use meow_rules::{parse_rule, ParserContext};
use serde_json::{json, Value};
use std::{path::Path, sync::Arc};

fn home() -> &'static Path {
    static HOME: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    HOME.get_or_init(|| tempfile::tempdir().unwrap()).path()
}

async fn invoke(core: &Core, method: &str, arguments: Value) -> Value {
    serde_json::from_slice(
        &core
            .invoke(
                &serde_json::to_vec(
                    &json!({"id":"application-rule","method":method,"arguments":arguments}),
                )
                .unwrap(),
                core.next_sequence(),
            )
            .await,
    )
    .unwrap()
}

async fn setup(core: &Core, rules: &[&str]) -> Value {
    let document =
        json!({"mode":"rule","dns":{"enable":false},"tun":{"enable":false},"rules":rules});
    let path = home().join("application-profile.yaml");
    profile::write(&path, &document).unwrap();
    let mut overlay = document;
    overlay["rules"] = json!([]);
    invoke(
        core,
        "setupConfig",
        json!({"base":{"path":path,"overlay":serde_saphyr::to_string(&overlay).unwrap()}}),
    )
    .await
}

#[test]
fn in_type_tun_matches_tun_without_matching_other_inbounds_or_internal_tunnels() {
    for spelling in ["TUN", "Tun", "tun"] {
        let rule = parse_rule(
            &format!("IN-TYPE,{spelling},DIRECT"),
            &ParserContext::default(),
        )
        .unwrap();
        for conn_type in [
            ConnType::Tun,
            ConnType::Tunnel,
            ConnType::TProxy,
            ConnType::Http,
            ConnType::Https,
            ConnType::Socks4,
            ConnType::Socks5,
            ConnType::Inner,
        ] {
            let metadata = Metadata {
                conn_type,
                ..Default::default()
            };
            assert_eq!(
                rule.match_metadata(&metadata, &RuleMatchHelper),
                conn_type == ConnType::Tun,
                "{spelling}: {conn_type}"
            );
        }
    }
    assert!(parse_rule("IN-TYPE,UNKNOWN,DIRECT", &ParserContext::default()).is_err());
}

#[tokio::test]
async fn application_modes_reload_and_route_tun_separately_from_http_and_socks() {
    let core = Core::new();
    assert_eq!(
        invoke(&core, "initClash", json!({"home-dir":home(),"version":35})).await["result"],
        true
    );
    let cases: &[(&[&str], [&str; 4])] = &[
        (
            &["PROCESS-NAME,browser.exe,REJECT", "MATCH,DIRECT"],
            ["REJECT", "DIRECT", "REJECT", "REJECT"],
        ),
        (
            &[
                "AND,((PROCESS-NAME,browser.exe),(IN-TYPE,TUN)),DIRECT",
                "MATCH,REJECT",
            ],
            ["DIRECT", "REJECT", "REJECT", "REJECT"],
        ),
        (
            &["IN-TYPE,TUN,DIRECT", "MATCH,REJECT"],
            ["DIRECT", "DIRECT", "REJECT", "REJECT"],
        ),
        (
            &[
                "AND,((IN-TYPE,TUN),(NOT,((PROCESS-NAME,browser.exe)))),DIRECT",
                "AND,((PROCESS-NAME,browser.exe),(IN-TYPE,TUN)),PASS",
                "MATCH,REJECT",
            ],
            ["REJECT", "DIRECT", "REJECT", "REJECT"],
        ),
        (&["MATCH,DIRECT"], ["DIRECT", "DIRECT", "DIRECT", "DIRECT"]),
    ];
    for (rules, expected) in cases {
        let response = setup(&core, rules).await;
        assert_eq!(response["result"], "", "{response}");
        let engine = core.active().unwrap();
        for ((conn_type, process), expected) in [
            (ConnType::Tun, "browser.exe"),
            (ConnType::Tun, "other.exe"),
            (ConnType::Http, "browser.exe"),
            (ConnType::Socks5, "browser.exe"),
        ]
        .into_iter()
        .zip(expected)
        {
            let metadata = Metadata {
                conn_type,
                process: process.into(),
                dst_ip: Some("127.0.0.1".parse().unwrap()),
                dst_port: 80,
                ..Default::default()
            };
            let target = engine
                .state
                .tunnel
                .inner()
                .resolve_proxy(&metadata)
                .await
                .unwrap();
            assert_eq!(
                target.adapter.name(),
                *expected,
                "{rules:?}: {conn_type}, {process}"
            );
        }
        assert_eq!(core.document().await["rules"], json!(rules));
        assert_eq!(
            profile::read(&home().join("config.yaml").to_string_lossy()).unwrap()["rules"],
            json!(rules)
        );
    }
    let engine = core.active().unwrap();
    let previous = core.document().await;
    let saved = std::fs::read(home().join("config.yaml")).unwrap();
    let rejected = setup(&core, &["IN-TYPE,UNKNOWN,DIRECT", "MATCH,REJECT"]).await;
    assert_ne!(rejected["result"], "", "{rejected}");
    assert!(Arc::ptr_eq(&engine, &core.active().unwrap()));
    assert_eq!(core.document().await, previous);
    assert_eq!(std::fs::read(home().join("config.yaml")).unwrap(), saved);
    core.shutdown().await;
}
