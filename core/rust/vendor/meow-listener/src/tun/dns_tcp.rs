use meow_dns::server::{DnsServer, ResolverSlot};
use std::{io, time::Duration};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub(super) async fn serve<S: AsyncRead + AsyncWrite + Unpin>(
    mut stream: S,
    resolver: ResolverSlot,
) -> io::Result<()> {
    loop {
        let length = match tokio::time::timeout(Duration::from_secs(30), stream.read_u16()).await? {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Empty DNS TCP frame",
                ))
            }
            Ok(length) => length as usize,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error),
        };
        let mut request = vec![0; length];
        tokio::time::timeout(Duration::from_secs(10), stream.read_exact(&mut request)).await??;
        let current = resolver.read().clone();
        let response = tokio::time::timeout(
            Duration::from_secs(10),
            DnsServer::handle_query(&request, &current),
        )
        .await?
        .map_err(|error| io::Error::other(error.to_string()))?;
        let size = u16::try_from(response.len()).map_err(io::Error::other)?;
        tokio::time::timeout(Duration::from_secs(10), async {
            stream.write_u16(size).await?;
            stream.write_all(&response).await?;
            stream.flush().await
        })
        .await??;
    }
}
