use anyhow::{Context, Result};
use flclash::{core::Core, ipc};
use tokio_util::sync::CancellationToken;

fn main() {
    if let Err(error) = run() {
        eprintln!("FlClashCore: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let address = std::env::args()
        .nth(1)
        .context("Expected Core IPC address")?;
    if address == "--backup-codec" {
        flclash::backup::serve()?;
        return Ok(());
    }
    if matches!(address.as_str(), "--version" | "-V") {
        println!("{} {}", flclash::ENGINE, flclash::ENGINE_VERSION);
        return Ok(());
    }
    flclash::runtime().block_on(async {
        let core = Core::new();
        let connection = ipc::connect(&address).await?;
        let cancel = CancellationToken::new();
        let termination = cancel.clone();
        let signal = tokio::spawn(async move {
            #[cfg(unix)]
            {
                if let Ok(mut term) =
                    tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                {
                    tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = term.recv() => {} }
                } else {
                    let _ = tokio::signal::ctrl_c().await;
                }
            }
            #[cfg(not(unix))]
            let _ = tokio::signal::ctrl_c().await;
            termination.cancel();
        });
        let result = ipc::serve(core.clone(), connection, cancel).await;
        signal.abort();
        core.shutdown().await;
        match result {
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::UnexpectedEof) =>
            {
                Ok(())
            }
            result => result,
        }
    })
}
