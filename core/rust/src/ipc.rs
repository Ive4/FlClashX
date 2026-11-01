use crate::{core::Core, protocol::MAX_FRAME};
use anyhow::{bail, Context, Result};
use std::{
    sync::{atomic::Ordering, Arc},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{mpsc, Semaphore},
};
use tokio_util::sync::CancellationToken;

pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Vec<u8>> {
    let length = reader.read_u32_le().await? as usize;
    if length > MAX_FRAME {
        bail!("IPC frame exceeds {MAX_FRAME} bytes");
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes).await?;
    Ok(bytes)
}

pub async fn write_frame<W: AsyncWrite + Unpin>(writer: &mut W, bytes: &[u8]) -> Result<()> {
    if bytes.len() > MAX_FRAME {
        bail!("IPC frame exceeds {MAX_FRAME} bytes");
    }
    writer.write_u32_le(bytes.len() as u32).await?;
    writer.write_all(bytes).await?;
    writer.flush().await?;
    Ok(())
}

pub async fn serve<S>(core: Arc<Core>, stream: S, cancel: CancellationToken) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut reader, mut writer) = tokio::io::split(stream);
    let (responses, mut pending) = mpsc::channel::<Vec<u8>>(64);
    let permits = Arc::new(Semaphore::new(64));
    core.events.enabled.store(true, Ordering::Release);
    let events = Arc::clone(&core.events);
    let writer_cancel = cancel.child_token();
    let mut delivery = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(16));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            let bytes = tokio::select! {
                _ = writer_cancel.cancelled() => return Ok::<(), anyhow::Error>(()),
                response = pending.recv() => match response { Some(response) => response, None => return Ok(()) },
                _ = interval.tick() => match events.batch() { Some(batch) => batch, None => continue },
            };
            write_frame(&mut writer, &bytes).await?;
        }
    });
    let result = loop {
        let input = tokio::select! {
            _ = cancel.cancelled() => break Ok(()),
            result = &mut delivery => break match result { Ok(result) => result, Err(error) => Err(error).context("IPC writer task") },
            frame = read_frame(&mut reader) => match frame { Ok(frame) => frame, Err(error) => break Err(error) },
        };
        let sequence = core.next_sequence();
        let permit = tokio::select! {
            _ = cancel.cancelled() => break Ok(()),
            permit = Arc::clone(&permits).acquire_owned() => permit?,
        };
        let core = Arc::clone(&core);
        let responses = responses.clone();
        // Accepted mutations finish even if a lightweight handoff closes this transport.
        tokio::spawn(async move {
            let _permit = permit;
            let response = core.invoke(&input, sequence).await;
            let _ = responses.send(response).await;
        });
    };
    core.events.enabled.store(false, Ordering::Release);
    if !delivery.is_finished() {
        delivery.abort();
        let _ = delivery.await;
    }
    result
}

#[cfg(windows)]
pub async fn connect(address: &str) -> Result<tokio::net::windows::named_pipe::NamedPipeClient> {
    use tokio::net::windows::named_pipe::ClientOptions;
    anyhow::ensure!(
        address.starts_with(r"\\.\pipe\FlClashCore_"),
        "Invalid Core pipe address"
    );
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        match ClientOptions::new().open(address) {
            Ok(client) => return Ok(client),
            Err(error)
                if matches!(error.raw_os_error(), Some(2 | 231))
                    && tokio::time::Instant::now() < deadline =>
            {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            Err(error) => return Err(error).context("Connect Core named pipe"),
        }
    }
}

#[cfg(unix)]
pub async fn connect(address: &str) -> Result<tokio::net::UnixStream> {
    tokio::net::UnixStream::connect(address)
        .await
        .context("Connect Core Unix socket")
}
