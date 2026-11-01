use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

struct Columns {
    local: usize,
    remote: usize,
    uid: usize,
}

impl Columns {
    fn from_header(header: &str) -> Option<Self> {
        let (mut local, mut remote, mut uid) = (None, None, None);
        let (mut tx, mut timer, mut collapsed) = (false, false, 0);
        for (index, name) in header.split_whitespace().enumerate() {
            if (name == "rx_queue" && tx) || (name == "tm->when" && timer) {
                collapsed += 1;
            }
            let column = index.checked_sub(collapsed)?;
            match name {
                "local_address" => local = Some(column),
                "rem_address" | "remote_address" => remote = Some(column),
                "uid" => uid = Some(column),
                "tx_queue" => tx = true,
                "tr" => timer = true,
                _ => {}
            }
        }
        Some(Self {
            local: local?,
            remote: remote?,
            uid: uid?,
        })
    }

    fn owner(&self, row: &str, source: SocketAddr, target: SocketAddr) -> Option<(u8, u32)> {
        let fields = row.split_whitespace().collect::<Vec<_>>();
        let local = address(fields.get(self.local)?)?;
        let remote = address(fields.get(self.remote)?)?;
        let exact_local = normalize(local.ip()) == normalize(source.ip());
        if local.port() != source.port() || (!exact_local && !local.ip().is_unspecified()) {
            return None;
        }
        let score =
            if normalize(remote.ip()) == normalize(target.ip()) && remote.port() == target.port() {
                if exact_local {
                    4
                } else {
                    3
                }
            } else if remote.ip().is_unspecified() && remote.port() == 0 {
                if exact_local {
                    2
                } else {
                    1
                }
            } else {
                return None;
            };
        Some((score, fields.get(self.uid)?.parse().ok()?))
    }
}

fn normalize(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(ip) => ip
            .to_ipv4_mapped()
            .map(IpAddr::V4)
            .unwrap_or(IpAddr::V6(ip)),
        ip => ip,
    }
}

fn address(value: &str) -> Option<SocketAddr> {
    let (ip, port) = value.split_once(':')?;
    let port = u16::from_str_radix(port, 16).ok()?;
    let ip = match ip.len() {
        8 => IpAddr::V4(Ipv4Addr::from(
            u32::from_str_radix(ip, 16).ok()?.to_le_bytes(),
        )),
        32 => {
            let mut bytes = [0; 16];
            for (index, word) in bytes.chunks_exact_mut(4).enumerate() {
                word.copy_from_slice(
                    &u32::from_str_radix(ip.get(index * 8..index * 8 + 8)?, 16)
                        .ok()?
                        .to_le_bytes(),
                );
            }
            IpAddr::V6(Ipv6Addr::from(bytes))
        }
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

pub fn parse_uid_table(table: &str, source: SocketAddr, target: SocketAddr) -> Option<u32> {
    let mut lines = table.lines();
    let columns = Columns::from_header(lines.next()?)?;
    lines
        .filter_map(|row| columns.owner(row, source, target))
        .max_by_key(|(score, _)| *score)
        .map(|(_, uid)| uid)
}

#[cfg(target_os = "android")]
pub fn lookup_socket_uid(protocol: u8, source: SocketAddr, target: SocketAddr) -> Option<u32> {
    use std::io::{BufRead, BufReader};
    let protocol = match protocol {
        6 => "tcp",
        17 => "udp",
        _ => return None,
    };
    let mut best = None;
    for suffix in ["6", ""] {
        if !source.is_ipv4() && suffix.is_empty() {
            continue;
        }
        let Ok(file) = std::fs::File::open(format!("/proc/net/{protocol}{suffix}")) else {
            continue;
        };
        let mut lines = BufReader::new(file).lines();
        let Some(Ok(header)) = lines.next() else {
            continue;
        };
        let Some(columns) = Columns::from_header(&header) else {
            continue;
        };
        for row in lines.take(65_536).map_while(std::result::Result::ok) {
            let Some(owner) = columns.owner(&row, source, target) else {
                continue;
            };
            if owner.0 == 4 {
                return Some(owner.1);
            }
            if best.is_none_or(|prior: (u8, u32)| owner.0 > prior.0) {
                best = Some(owner);
            }
        }
    }
    best.map(|(_, uid)| uid)
}
