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

#[test]
fn desktop_access_lists_match_full_paths_and_scope_only_tun() {
    let blacklist = parse_rule(
        r"AND,((IN-TYPE,TUN),(OR,((PROCESS-PATH-REGEX,(?i)^C:\\Apps \x281\x29\x2cTest\\browser\.exe$),(PROCESS-PATH-REGEX,(?i)^D:\\Tools\\client\.exe$)))),DIRECT",
        &ParserContext::default(),
    )
    .unwrap();
    for (path, expected) in [
        (r"c:\APPS (1),Test\Browser.EXE", true),
        (r"D:\Tools\client.exe", true),
        (r"E:\Other\browser.exe", false),
        (r"C:\Apps (1),Test\browser.exe.other", false),
        ("", false),
    ] {
        for conn_type in [ConnType::Tun, ConnType::Http, ConnType::Socks5] {
            let metadata = Metadata {
                conn_type,
                process_path: path.into(),
                ..Default::default()
            };
            assert_eq!(
                blacklist.match_metadata(&metadata, &RuleMatchHelper),
                expected && conn_type == ConnType::Tun,
                "{path}: {conn_type}"
            );
        }
    }

    let whitelist = parse_rule(
        r"AND,((IN-TYPE,TUN),(NOT,((OR,((PROCESS-PATH-REGEX,^/Applications/Chat\.app/Contents/),(PROCESS-PATH-REGEX,^/usr/bin/curl$)))))),DIRECT",
        &ParserContext::default(),
    )
    .unwrap();
    for (path, excluded) in [
        ("/Applications/Chat.app/Contents/MacOS/Chat", false),
        (
            "/Applications/Chat.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
            false,
        ),
        ("/Applications/Chat.app.other/Contents/MacOS/Chat", true),
        ("/Applications/Other.app/Contents/MacOS/Chat", true),
        ("/usr/bin/curl", false),
        ("/usr/bin/curl-extra", true),
        ("", true),
    ] {
        for conn_type in [ConnType::Tun, ConnType::Http, ConnType::Socks5] {
            let metadata = Metadata {
                conn_type,
                process_path: path.into(),
                ..Default::default()
            };
            assert_eq!(
                whitelist.match_metadata(&metadata, &RuleMatchHelper),
                excluded && conn_type == ConnType::Tun,
                "{path}: {conn_type}"
            );
        }
    }
}

#[tokio::test]
async fn desktop_access_regex_survives_profile_compilation_and_reload() {
    let core = Core::new();
    assert_eq!(
        invoke(&core, "initClash", json!({"home-dir":home(),"version":35})).await["result"],
        true
    );
    for (rule, selected, other) in [
        (
            r"AND,((IN-TYPE,TUN),(PROCESS-PATH-REGEX,(?i)^C:\\Apps\\browser\.exe$)),DIRECT",
            "DIRECT",
            "REJECT",
        ),
        (
            r"AND,((IN-TYPE,TUN),(NOT,((PROCESS-PATH-REGEX,(?i)^C:\\Apps\\browser\.exe$)))),DIRECT",
            "REJECT",
            "DIRECT",
        ),
    ] {
        let response = setup(&core, &[rule, "MATCH,REJECT"]).await;
        assert_eq!(response["result"], "", "{response}");
        let engine = core.active().unwrap();
        for (conn_type, path, expected) in [
            (ConnType::Tun, r"C:\Apps\Browser.exe", selected),
            (ConnType::Tun, r"D:\Apps\browser.exe", other),
            (ConnType::Http, r"C:\Apps\Browser.exe", "REJECT"),
            (ConnType::Socks5, r"D:\Apps\browser.exe", "REJECT"),
        ] {
            let metadata = Metadata {
                conn_type,
                process: "browser.exe".into(),
                process_path: path.into(),
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
                expected,
                "{rule}: {conn_type}, {path}"
            );
        }
    }
    for kind in ["PROCESS-PATH-REGEX", "PROCESS-NAME-REGEX"] {
        assert!(parse_rule(&format!("{kind},[,DIRECT"), &ParserContext::default()).is_err());
    }
}
