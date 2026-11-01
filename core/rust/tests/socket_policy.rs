use flclash::{
    core::Core,
    engine::Engine,
    extras,
    socket_policy::{self, TcpKeepalivePolicy},
};
use meow_common::tcp_socket_policy::{self as hooks, TcpSocketPolicy};
use serde_json::{json, Value};
use socket2::{Domain, Protocol, SockRef, Socket, Type};
use std::{io, sync::Arc, time::Duration};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{broadcast, Mutex},
};

static LOCK: Mutex<()> = Mutex::const_new(());

fn home() -> &'static tempfile::TempDir {
    static DIRECTORY: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    DIRECTORY.get_or_init(|| tempfile::tempdir().unwrap())
}

fn policy(enabled: bool, idle: u64, interval: u64) -> TcpKeepalivePolicy {
    TcpKeepalivePolicy {
        enabled,
        idle: Duration::from_secs(idle),
        interval: Duration::from_secs(interval),
    }
}

fn options(stream: &TcpStream) -> TcpKeepalivePolicy {
    TcpKeepalivePolicy::read_socket(&SockRef::from(stream)).unwrap()
}

async fn connection(hostname: bool) -> TcpStream {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let client = if hostname {
        meow_common::connect_tcp_host("127.0.0.1", address.port()).await
    } else {
        meow_common::connect_tcp(address).await
    }
    .unwrap();
    let (incoming, _) = listener.accept().await.unwrap();
    assert!(!SockRef::from(&incoming).keepalive().unwrap());
    client
}

async fn assert_new_options(expected: TcpKeepalivePolicy) {
    assert_eq!(options(&connection(false).await), expected);
    assert_eq!(options(&connection(true).await), expected);
}

async fn call(core: &Core, method: &str, arguments: Value) -> Value {
    serde_json::from_slice(
        &core
            .invoke(
                &serde_json::to_vec(
                    &json!({"id":"socket-policy","method":method,"arguments":arguments}),
                )
                .unwrap(),
                core.next_sequence(),
            )
            .await,
    )
    .unwrap()
}

#[tokio::test]
async fn defaults_sixty_custom_and_disable_are_real_socket_options() {
    let _lock = LOCK.lock().await;
    assert!(hooks::tcp_socket_policy().is_none());
    assert!(!SockRef::from(&connection(false).await).keepalive().unwrap());
    for (document, expected) in [
        (json!({}), policy(true, 15, 30)),
        (json!({"keep-alive-interval":60}), policy(true, 15, 60)),
        (
            json!({"keep-alive-idle":83,"keep-alive-interval":17}),
            policy(true, 83, 17),
        ),
        (
            json!({"keep-alive-idle":29,"keep-alive-interval":61,"disable-keep-alive":true}),
            policy(false, 29, 61),
        ),
    ] {
        let _guard = socket_policy::install(&document).unwrap();
        assert_new_options(expected).await;
        let stream = connection(false).await;
        anytls_rs::util::configure_tcp_stream(&stream, "socket-policy-test");
        assert_eq!(options(&stream), expected, "AnyTLS overwrote {document}");
    }
    assert!(hooks::tcp_socket_policy().is_none());
}

#[tokio::test]
async fn anytls_native_defaults_remain_when_no_host_policy_is_installed() {
    let _lock = LOCK.lock().await;
    assert!(hooks::tcp_socket_policy().is_none());
    let stream = connection(false).await;
    anytls_rs::util::configure_tcp_stream(&stream, "native-default-test");
    assert_eq!(options(&stream), policy(true, 120, 30));
}

#[tokio::test]
async fn policy_guard_restores_predecessor_without_changing_existing_connections() {
    let _lock = LOCK.lock().await;
    let original = socket_policy::install(&json!({"keep-alive-interval":60})).unwrap();
    let existing = connection(false).await;
    {
        let _candidate = socket_policy::install(&json!({"disable-keep-alive":true})).unwrap();
        assert_new_options(policy(false, 15, 30)).await;
        assert_eq!(options(&existing), policy(true, 15, 60));
    }
    assert_new_options(policy(true, 15, 60)).await;
    let successor = socket_policy::install(&json!({"keep-alive-interval":17})).unwrap();
    drop(original);
    assert_new_options(policy(true, 15, 17)).await;
    drop(successor);
    assert!(hooks::tcp_socket_policy().is_none());
}

#[tokio::test]
async fn invalid_supplied_values_fail_validation_without_replacing_policy() {
    let _lock = LOCK.lock().await;
    let _guard = socket_policy::install(&json!({"keep-alive-interval":60})).unwrap();
    for key in ["keep-alive-idle", "keep-alive-interval"] {
        for value in [
            json!(0),
            json!(-1),
            json!(1.5),
            json!(false),
            json!("60"),
            Value::Null,
            json!([]),
            json!(u64::MAX),
        ] {
            let document = json!({(key):value});
            let error = extras::validate(&document).unwrap_err();
            assert_eq!(error.code, "unsupported_config");
            assert_eq!(error.details["path"], key, "{document}: {error}");
            assert!(socket_policy::install(&document).is_err());
        }
    }
    for value in [json!(0), json!("false"), Value::Null] {
        assert!(extras::validate(&json!({"disable-keep-alive":value})).is_err());
    }
    assert_new_options(policy(true, 15, 60)).await;
}

struct FailingPolicy;

impl TcpSocketPolicy for FailingPolicy {
    fn apply(&self, socket: &Socket) -> io::Result<()> {
        assert!(socket.peer_addr().is_err());
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "deliberately rejected socket policy",
        ))
    }
}

#[tokio::test]
async fn policy_errors_abort_dials_and_tcp_only_interface_hook_leaves_udp_untouched() {
    let _lock = LOCK.lock().await;
    let _guard = hooks::install_tcp_socket_policy(Arc::new(FailingPolicy));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let error = meow_common::connect_tcp(listener.local_addr().unwrap())
        .await
        .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::Unsupported);
    let listener = listener.into_std().unwrap();
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    let tcp = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).unwrap();
    assert!(meow_common::apply_outbound_interface(&tcp, Domain::IPV4).is_err());
    let udp = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP)).unwrap();
    meow_common::apply_outbound_interface(&udp, Domain::IPV4).unwrap();
}

#[tokio::test]
async fn engine_rejected_reload_restores_options_and_old_shutdown_cannot_clear_successor() {
    let _lock = LOCK.lock().await;
    let home = home();
    let (logs, _) = broadcast::channel(16);
    let document =
        json!({"keep-alive-interval":60,"dns":{"enable":false},"rules":["MATCH,DIRECT"]});
    let engine = Engine::create(&document, home.path(), logs.clone())
        .await
        .unwrap();
    assert_new_options(policy(true, 15, 60)).await;
    assert!(engine
        .reload(&json!({"strict":true,"keep-alive-interval":17,"proxies":[{"name":"bad","type":"unknown-protocol"}],"rules":["MATCH,bad"]}))
        .await
        .is_err());
    assert_new_options(policy(true, 15, 60)).await;
    assert!(engine.reload(&json!({"keep-alive-idle":0})).await.is_err());
    assert_new_options(policy(true, 15, 60)).await;
    let successor = Engine::create(
        &json!({"keep-alive-idle":43,"keep-alive-interval":19,"dns":{"enable":false},"rules":["MATCH,DIRECT"]}),
        home.path(),
        logs,
    )
    .await
    .unwrap();
    engine.shutdown().await;
    assert_new_options(policy(true, 43, 19)).await;
    successor.shutdown().await;
    assert!(hooks::tcp_socket_policy().is_none());
}

#[tokio::test]
async fn failed_full_config_apply_restores_policy_and_preserves_saved_values() {
    let _lock = LOCK.lock().await;
    let home = home();
    let core = Core::new();
    assert_eq!(
        call(
            &core,
            "initClash",
            json!({"home-dir":home.path(),"version":35})
        )
        .await["result"],
        true
    );
    let path = home.path().join("profile.yaml");
    let document = json!({"keep-alive-idle":83,"keep-alive-interval":60,"dns":{"enable":false},"tun":{"enable":false},"rules":["MATCH,DIRECT"]});
    let yaml = serde_saphyr::to_string(&document).unwrap();
    std::fs::write(&path, &yaml).unwrap();
    assert_eq!(
        call(
            &core,
            "setupConfig",
            json!({"base":{"path":path,"overlay":yaml}})
        )
        .await["result"],
        ""
    );
    assert_eq!(
        call(&core, "startListener", Value::Null).await["result"],
        true
    );
    assert_new_options(policy(true, 83, 60)).await;
    let before = std::fs::read(home.path().join("config.yaml")).unwrap();
    let occupied = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut candidate = document.clone();
    candidate["mixed-port"] = json!(occupied.local_addr().unwrap().port());
    candidate["keep-alive-interval"] = json!(17);
    candidate["disable-keep-alive"] = json!(true);
    let yaml = serde_saphyr::to_string(&candidate).unwrap();
    std::fs::write(&path, &yaml).unwrap();
    let failed = call(
        &core,
        "setupConfig",
        json!({"base":{"path":path,"overlay":yaml}}),
    )
    .await;
    assert!(
        failed["error"].is_object()
            || failed["result"]
                .as_str()
                .is_some_and(|message| !message.is_empty()),
        "{failed}"
    );
    assert_new_options(policy(true, 83, 60)).await;
    assert_eq!(
        std::fs::read(home.path().join("config.yaml")).unwrap(),
        before
    );
    assert_eq!(core.document().await["keep-alive-interval"], 60);
    assert_eq!(core.document().await["keep-alive-idle"], 83);
    core.shutdown().await;
    assert!(hooks::tcp_socket_policy().is_none());
}
