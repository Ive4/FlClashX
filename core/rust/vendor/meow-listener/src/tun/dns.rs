//! OS DNS resolver configuration for the TUN inbound.
//!
//! When `dns-hijack` is active, the OS resolver must be pointed at a
//! DNS server that returns fake IPs.  On macOS/Linux this is an address
//! the fake-IP pool reserves ([`GuardAddrs`]; `198.18.0.2` by default) —
//! queries enter the TUN device and are answered by `dns-hijack`.  On
//! Windows only the TUN adapter receives the resolver address. Physical
//! adapters keep their DNS settings, and both UDP and TCP queries enter TUN.
//!
//! `DnsGuard` restores the settings it owns on drop. On Windows that scope
//! is the TUN adapter; other platforms retain their system resolver guard.
//!
//! Windows setup failure aborts TUN startup. Teardown errors are logged.

use std::net::{IpAddr, Ipv4Addr};
use tracing::warn;
#[cfg(not(target_os = "windows"))]
use tracing::debug;

/// Where the guard points the OS resolver on macOS/Linux, and every
/// address a run may have pointed it at.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct GuardAddrs {
    /// The resolver address to install.
    pub(super) dns: IpAddr,
    /// The fake-IP pool's two reserved hosts. An unclean shutdown leaves
    /// one of them as the active DNS — the gateway before the device took
    /// it by default — and neither may ever be backed up as the user's.
    pub(super) own: [IpAddr; 2],
}

impl GuardAddrs {
    /// The fake-IP pool never hands out its range's first four addresses:
    /// network, gateway and the two above. The resolver gets the gateway,
    /// or the address above it when the device owns the gateway (its
    /// default address): a query to the device's own address is local and
    /// never enters the TUN.
    pub(super) fn new(gateway: Ipv4Addr, device: Ipv4Addr) -> Self {
        let spare = Ipv4Addr::from(u32::from(gateway).wrapping_add(1));
        let dns = if device == gateway { spare } else { gateway };
        Self {
            dns: dns.into(),
            own: [gateway.into(), spare.into()],
        }
    }
}

/// RAII guard that restores original DNS settings on drop.
///
/// When created, it saves the current OS DNS state and replaces it with
/// the loopback DNS addresses on all active network interfaces. On drop,
/// the original configuration is restored. Failed operations are logged
/// at `warn!` level rather than panicking.
pub(super) struct DnsGuard {
    #[cfg(target_os = "windows")]
    _guard: windows::DnsGuard,
    #[cfg(target_os = "macos")]
    backup: Vec<(String, Vec<IpAddr>)>,
    #[cfg(target_os = "linux")]
    backup: Option<linux::ResolvConfBackup>,
}

impl DnsGuard {
    /// Save current DNS settings and set all interfaces to `addrs.dns`.
    /// Returns `None` on platforms without a supported backend, or when
    /// the backup fails.
    ///
    /// Windows sets DNS only on `_interface`, the owned TUN adapter.
    pub(super) fn setup(addrs: GuardAddrs, _interface: u32) -> Option<Self> {
        #[cfg(target_os = "windows")]
        {
            let _ = (addrs.dns, addrs.own);
            match windows::DnsGuard::setup(_interface, addrs.dns) {
                Ok(guard) => Some(Self { _guard: guard }),
                Err(error) => { warn!("TUN adapter DNS setup failed: {error}"); None }
            }
        }
        #[cfg(target_os = "macos")]
        {
            let dns_addr = addrs.dns;
            match macos::backup(&addrs.own) {
                Ok(backup) => {
                    if let Err(e) = macos::set_all(dns_addr, &backup) {
                        warn!("tun dns-guard: failed to set DNS to {dns_addr}: {e}");
                    }
                    debug!(
                        "tun dns-guard: DNS set to {dns_addr} on {} network services",
                        backup.len()
                    );
                    Some(Self { backup })
                }
                Err(e) => {
                    warn!("tun dns-guard: failed to back up DNS settings: {e}");
                    None
                }
            }
        }
        #[cfg(target_os = "linux")]
        {
            let dns_addr = addrs.dns;
            match linux::backup_and_set(dns_addr) {
                Ok(backup) => {
                    debug!("tun dns-guard: DNS set to {dns_addr} in /etc/resolv.conf");
                    Some(Self {
                        backup: Some(backup),
                    })
                }
                Err(e) => {
                    warn!("tun dns-guard: failed to configure DNS: {e}");
                    None
                }
            }
        }
        #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
        {
            let _ = (addrs.dns, addrs.own);
            debug!("tun dns-guard: no DNS backend for this platform; skipping");
            None
        }
    }
}

// Restore runs synchronously in Drop — deliberately. `Tunnel::stop_tun`
// awaits the aborted task, so a config-reload disable→enable cannot start a
// new backup until this restore has finished; offloading to another thread
// would open that race, and the process-exit path must block anyway or the
// restore is lost. Windows changes only the owned virtual adapter.
impl Drop for DnsGuard {
    fn drop(&mut self) {
        #[cfg(target_os = "macos")]
        {
            if let Err(e) = macos::restore(&self.backup) {
                warn!("tun dns-guard: failed to restore DNS settings: {e}");
            } else {
                debug!("tun dns-guard: DNS settings restored");
            }
        }
        #[cfg(target_os = "linux")]
        {
            if let Some(backup) = self.backup.take() {
                if let Err(e) = linux::restore(&backup) {
                    warn!("tun dns-guard: failed to restore /etc/resolv.conf: {e}");
                } else {
                    debug!("tun dns-guard: /etc/resolv.conf restored");
                }
            }
        }
    }
}

#[cfg(target_os = "windows")]
#[path = "windows_dns.rs"]
mod windows;

// ---------------------------------------------------------------------------
// macOS backend — networksetup
//
// Only services that were snapshotted are ever changed: `set_all` and
// `restore` both iterate the backup, so a service whose
// `-getdnsservers` failed (or that appeared after the snapshot) is left
// untouched rather than pointed at the fake-IP range with nothing to
// restore it from.
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
mod macos {
    use super::networksetup;
    use std::io;
    use std::net::IpAddr;
    use std::process::Command;

    pub(super) fn backup(own: &[IpAddr]) -> io::Result<Vec<(String, Vec<IpAddr>)>> {
        let services = list_services()?;
        let mut result = Vec::with_capacity(services.len());
        for svc in services {
            match get_dns(&svc, own) {
                Ok(servers) => {
                    super::debug!("tun dns-guard: '{svc}' DNS before setup: {servers:?}");
                    result.push((svc, servers));
                }
                Err(e) => super::warn!(
                    "tun dns-guard: failed to get DNS for '{svc}', leaving it untouched: {e}"
                ),
            }
        }
        Ok(result)
    }

    pub(super) fn set_all(dns_addr: IpAddr, saved: &[(String, Vec<IpAddr>)]) -> io::Result<()> {
        let mut failed = 0usize;
        for (svc, _) in saved {
            if let Err(e) = set_dns(svc, std::slice::from_ref(&dns_addr)) {
                super::warn!("tun dns-guard: failed to set DNS on '{svc}': {e}");
                failed += 1;
            }
        }
        summarize(failed, saved.len())
    }

    pub(super) fn restore(saved: &[(String, Vec<IpAddr>)]) -> io::Result<()> {
        let mut failed = 0usize;
        for (svc, servers) in saved {
            if let Err(e) = set_dns(svc, servers) {
                super::warn!("tun dns-guard: failed to restore DNS on '{svc}': {e}");
                failed += 1;
            }
        }
        summarize(failed, saved.len())
    }

    fn summarize(failed: usize, total: usize) -> io::Result<()> {
        if failed == 0 {
            Ok(())
        } else {
            Err(io::Error::other(format!(
                "{failed} of {total} network services failed"
            )))
        }
    }

    fn list_services() -> io::Result<Vec<String>> {
        let stdout = run(&["-listallnetworkservices"])?;
        Ok(networksetup::parse_services(&stdout))
    }

    fn get_dns(service: &str, own: &[IpAddr]) -> io::Result<Vec<IpAddr>> {
        let stdout = run(&["-getdnsservers", service])?;
        Ok(networksetup::saved_dns_servers(&stdout, own))
    }

    fn set_dns(service: &str, servers: &[IpAddr]) -> io::Result<()> {
        let addrs = networksetup::dns_server_args(servers);
        let mut args = vec!["-setdnsservers", service];
        args.extend(addrs.iter().map(String::as_str));
        run(&args)?;
        Ok(())
    }

    /// Run `networksetup` and return its stdout; a non-zero exit is an
    /// error carrying networksetup's diagnostic (see `check_exit`).
    fn run(args: &[&str]) -> io::Result<String> {
        let output = Command::new("networksetup").args(args).output()?;
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        networksetup::check_exit(
            args.first().copied().unwrap_or_default(),
            output.status.code(),
            &stdout,
            &String::from_utf8_lossy(&output.stderr),
        )?;
        Ok(stdout)
    }
}

// ---------------------------------------------------------------------------
// networksetup output handling for the macOS backend.
//
// Pure functions, also compiled under `cfg(test)` on every platform so the
// Linux and Windows CI legs run their tests — the backend itself only
// builds on macOS. Measured `networksetup` behaviour (macOS 26, #695):
//
// - `-getdnsservers <svc>` with no manual servers: exit 0,
//   "There aren't any DNS Servers set on <svc>." — the service name, not
//   the "this device" wording an exact-match check once assumed.
// - Every failure exits 4 and prints its diagnostic on *stdout* (stderr
//   stays empty): "<svc> is not a recognized network service." /
//   "<arg> is not a valid IP address. No changes were saved...", then
//   "** Error: The parameters were not valid.".
// - `-setdnsservers` is all-or-nothing (one bad address saves nothing),
//   rejects scoped IPv6 (`fe80::1%en0`), and succeeds with exit 0 and no
//   output; the `Empty` keyword clears the manual list (DHCP/automatic).
// ---------------------------------------------------------------------------

#[cfg(any(target_os = "macos", test))]
mod networksetup {
    use std::io;
    use std::net::IpAddr;

    /// `-setdnsservers` keyword that clears a service's manual DNS list.
    const EMPTY: &str = "Empty";

    /// Classify one `networksetup` run. Exit 0 is success; any other exit
    /// — or death by signal (`code == None`) — is an error carrying the
    /// diagnostic, which networksetup prints on stdout (stderr is appended
    /// in case that ever changes), folded onto one line for the log.
    pub(super) fn check_exit(
        subcmd: &str,
        code: Option<i32>,
        stdout: &str,
        stderr: &str,
    ) -> io::Result<()> {
        if code == Some(0) {
            return Ok(());
        }
        let status = code.map_or_else(
            || "terminated by a signal".to_owned(),
            |c| format!("exit status {c}"),
        );
        let lines: Vec<&str> = stdout
            .lines()
            .chain(stderr.lines())
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .collect();
        let detail = if lines.is_empty() {
            "no output".to_owned()
        } else {
            lines.join(" ")
        };
        Err(io::Error::other(format!(
            "networksetup {subcmd} failed ({status}): {detail}"
        )))
    }

    /// Enabled network services from `-listallnetworkservices` stdout.
    /// Line 1 is the "An asterisk (*) denotes that a network service is
    /// disabled." legend; disabled services carry a leading `*`.
    pub(super) fn parse_services(stdout: &str) -> Vec<String> {
        stdout
            .lines()
            .skip(1)
            .map(str::trim)
            .filter(|s| !s.is_empty() && !s.starts_with('*'))
            .map(str::to_owned)
            .collect()
    }

    /// The server list to back up from `-getdnsservers` stdout (exit 0).
    ///
    /// The list is exactly the lines that parse as an IP address, so the
    /// "There aren't any DNS Servers set on <svc>." sentence — in any
    /// wording — yields an empty list, restored as `Empty`. `own` (the
    /// addresses meow installs, [`super::GuardAddrs::own`]) is dropped
    /// too: after an unclean shutdown one is still the active DNS, and
    /// keeping it would make a later clean exit "restore" the broken state.
    pub(super) fn saved_dns_servers(stdout: &str, own: &[IpAddr]) -> Vec<IpAddr> {
        stdout
            .lines()
            .filter_map(|l| l.trim().parse::<IpAddr>().ok())
            .filter(|ip| !own.contains(ip))
            .collect()
    }

    /// `-setdnsservers <svc>` arguments for `servers`; an empty list
    /// becomes `Empty`.
    pub(super) fn dns_server_args(servers: &[IpAddr]) -> Vec<String> {
        if servers.is_empty() {
            vec![EMPTY.to_owned()]
        } else {
            servers.iter().map(ToString::to_string).collect()
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::net::Ipv4Addr;

        /// The default fake-IP pool's reserved hosts (`198.18.0.1`, `.2`).
        const OWN: &[IpAddr] = &[
            IpAddr::V4(Ipv4Addr::new(198, 18, 0, 1)),
            IpAddr::V4(Ipv4Addr::new(198, 18, 0, 2)),
        ];

        /// networksetup's trailer on every parameter error.
        const PARAMS_INVALID: &str = "** Error: The parameters were not valid.";

        fn ips(list: &[&str]) -> Vec<IpAddr> {
            list.iter().map(|s| s.parse().unwrap()).collect()
        }

        #[test]
        fn no_servers_sentence_names_the_service() {
            // Real macOS 26 output (#695): the sentence names the service,
            // so the old exact match against "...on this device." missed it
            // and backed the sentence up as the server list.
            for svc in ["Ethernet", "Wi-Fi", "USB 10/100/1000 LAN"] {
                let out = format!("There aren't any DNS Servers set on {svc}.\n");
                assert!(saved_dns_servers(&out, OWN).is_empty(), "{out:?}");
            }
        }

        #[test]
        fn legacy_this_device_sentence_is_empty() {
            let out = "There aren't any DNS Servers set on this device.\n";
            assert!(saved_dns_servers(out, OWN).is_empty());
        }

        #[test]
        fn ipv4_and_ipv6_lists_are_kept_in_order() {
            assert_eq!(saved_dns_servers("9.9.9.9\n", OWN), ips(&["9.9.9.9"]));
            assert_eq!(
                saved_dns_servers("1.1.1.1\n2606:4700:4700::1111\n8.8.8.8\n", OWN),
                ips(&["1.1.1.1", "2606:4700:4700::1111", "8.8.8.8"]),
            );
        }

        #[test]
        fn tolerates_crlf_padding_and_blank_lines() {
            assert_eq!(
                saved_dns_servers("  8.8.8.8 \r\n\r\n2001:4860:4860::8888\t\r\n", OWN),
                ips(&["8.8.8.8", "2001:4860:4860::8888"]),
            );
            assert!(
                saved_dns_servers("There aren't any DNS Servers set on Ethernet. \r\n", OWN)
                    .is_empty()
            );
            assert!(saved_dns_servers("", OWN).is_empty());
        }

        #[test]
        fn own_gateway_is_never_backed_up() {
            // Cycle 2 of the #695 repro: the leaked gateway is the only
            // "original" server — it must restore as `Empty`.
            assert!(saved_dns_servers("198.18.0.1\n", OWN).is_empty());
            assert_eq!(
                saved_dns_servers("198.18.0.1\n1.1.1.1\n", OWN),
                ips(&["1.1.1.1"])
            );
            // The address above it, installed when the device owns the
            // gateway, leaks the same way.
            assert!(saved_dns_servers("198.18.0.2\n", OWN).is_empty());
            assert_eq!(
                saved_dns_servers("1.1.1.1\n198.18.0.2\n", OWN),
                ips(&["1.1.1.1"])
            );
        }

        #[test]
        fn scoped_ipv6_is_not_a_server() {
            // `-setdnsservers` rejects it (exit 4), so it can never be a
            // configured server — and could never be restored.
            assert_eq!(
                saved_dns_servers("1.1.1.1\nfe80::1%en0\n", OWN),
                ips(&["1.1.1.1"])
            );
        }

        #[test]
        fn error_text_never_parses_as_servers() {
            let out =
                format!("No Such Service is not a recognized network service.\n{PARAMS_INVALID}\n");
            assert!(saved_dns_servers(&out, OWN).is_empty());
            let err = check_exit("-getdnsservers", Some(4), &out, "").unwrap_err();
            assert_eq!(
                err.to_string(),
                format!(
                    "networksetup -getdnsservers failed (exit status 4): \
                     No Such Service is not a recognized network service. {PARAMS_INVALID}"
                ),
            );
        }

        #[test]
        fn check_exit_accepts_only_exit_zero() {
            assert!(check_exit("-setdnsservers", Some(0), "", "").is_ok());
            assert!(check_exit("-getdnsservers", Some(0), "9.9.9.9\n", "").is_ok());
            assert!(check_exit(
                "-getdnsservers",
                Some(0),
                "There aren't any DNS Servers set on Ethernet.\n",
                ""
            )
            .is_ok());
        }

        #[test]
        fn check_exit_surfaces_rejected_set() {
            // The exact failure #695 hid: restoring the backed-up sentence.
            let out = format!(
                "There aren't any DNS Servers set on Ethernet. is not a valid IP address. \
                 No changes were saved...\n{PARAMS_INVALID}\n"
            );
            let err = check_exit("-setdnsservers", Some(4), &out, "").unwrap_err();
            let msg = err.to_string();
            assert!(
                msg.starts_with("networksetup -setdnsservers failed (exit status 4): "),
                "{msg}"
            );
            assert!(
                msg.contains("is not a valid IP address. No changes were saved..."),
                "{msg}"
            );
            assert!(msg.ends_with(PARAMS_INVALID), "{msg}");
            assert!(!msg.contains('\n'), "folded onto one line: {msg}");

            let out = format!(
                "bogus is not a valid IP address. No changes were saved...\n{PARAMS_INVALID}\n"
            );
            assert!(check_exit("-setdnsservers", Some(4), &out, "").is_err());
        }

        #[test]
        fn check_exit_without_output() {
            let err = check_exit("-setdnsservers", None, "", "").unwrap_err();
            assert_eq!(
                err.to_string(),
                "networksetup -setdnsservers failed (terminated by a signal): no output"
            );
            let err = check_exit("-listallnetworkservices", Some(1), "", "boom\n").unwrap_err();
            assert!(err.to_string().ends_with("(exit status 1): boom"), "{err}");
        }

        #[test]
        fn empty_list_restores_as_empty_keyword() {
            assert_eq!(dns_server_args(&[]), ["Empty"]);
            // The full #695 path for a DHCP service: snapshot the
            // no-servers sentence, restore with `Empty` (exit 0, no
            // output) — never the sentence itself.
            let saved = saved_dns_servers("There aren't any DNS Servers set on Ethernet.\n", OWN);
            assert_eq!(dns_server_args(&saved), ["Empty"]);
        }

        #[test]
        fn server_args_round_trip() {
            let servers = ips(&["1.1.1.1", "2606:4700:4700::1111"]);
            assert_eq!(
                dns_server_args(&servers),
                ["1.1.1.1", "2606:4700:4700::1111"]
            );
            let out = "1.1.1.1\n2606:4700:4700::1111\n";
            assert_eq!(saved_dns_servers(out, OWN), servers);
        }

        #[test]
        fn services_skip_legend_and_disabled() {
            let out = "An asterisk (*) denotes that a network service is disabled.\n\
                       Ethernet\nWi-Fi\n*Thunderbolt Bridge\nUSB 10/100/1000 LAN\r\n\n";
            assert_eq!(
                parse_services(out),
                ["Ethernet", "Wi-Fi", "USB 10/100/1000 LAN"]
            );
            assert!(parse_services("").is_empty());
        }
    }
}

// ---------------------------------------------------------------------------
// Linux backend — /etc/resolv.conf
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
mod linux {
    use std::fs;
    use std::io;
    use std::net::IpAddr;
    use std::path::PathBuf;

    const MARKER: &str = "# Generated by meow-rs TUN dns-guard";
    /// On-disk copy of the pre-meow resolv.conf, written before we touch
    /// the real file so the original survives an unclean shutdown.
    const SIDECAR: &str = "/etc/resolv.conf.meow-backup";

    pub(super) struct ResolvConfBackup {
        path: PathBuf,
        content: Vec<u8>,
    }

    pub(super) fn backup_and_set(dns_addr: IpAddr) -> io::Result<ResolvConfBackup> {
        let path = PathBuf::from("/etc/resolv.conf");
        let current = fs::read(&path)?;

        let content = if current.starts_with(MARKER.as_bytes()) {
            // resolv.conf is our own generated file — a previous run exited
            // uncleanly. Recover the true original from the sidecar instead
            // of backing up (and later "restoring") the broken state.
            match fs::read(SIDECAR) {
                Ok(original) => {
                    super::warn!(
                        "tun dns-guard: /etc/resolv.conf was left over from an unclean \
                         shutdown; recovered the original from {SIDECAR}"
                    );
                    original
                }
                Err(e) => {
                    super::warn!(
                        "tun dns-guard: /etc/resolv.conf was left over from an unclean \
                         shutdown and no sidecar backup exists ({e}); will restore public \
                         resolvers on exit — reconfigure your resolver manually if needed"
                    );
                    b"# meow-rs tun dns-guard: the original /etc/resolv.conf was lost in an\n\
                      # unclean shutdown; falling back to public resolvers.\n\
                      nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
                        .to_vec()
                }
            }
        } else {
            fs::write(SIDECAR, &current)?;
            current
        };

        let new_content = format!("{MARKER}\nnameserver {dns_addr}\n");
        fs::write(&path, new_content.as_bytes())?;
        Ok(ResolvConfBackup { path, content })
    }

    pub(super) fn restore(backup: &ResolvConfBackup) -> io::Result<()> {
        fs::write(&backup.path, &backup.content)?;
        let _ = fs::remove_file(SIDECAR);
        Ok(())
    }
}

#[cfg(test)]
mod guard_addrs_tests {
    use super::GuardAddrs;
    use std::net::{IpAddr, Ipv4Addr};

    fn ip(s: &str) -> Ipv4Addr {
        s.parse().unwrap()
    }

    #[test]
    fn resolver_never_gets_the_device_address() {
        let gateway = ip("198.18.0.1");
        let spare = ip("198.18.0.2");
        // The default device address is the gateway itself.
        assert_eq!(GuardAddrs::new(gateway, gateway).dns, IpAddr::from(spare));
        // A device on the spare (a Windows retry), or outside the range,
        // leaves the gateway to the resolver.
        assert_eq!(GuardAddrs::new(gateway, spare).dns, IpAddr::from(gateway));
        assert_eq!(
            GuardAddrs::new(gateway, ip("172.19.0.1")).dns,
            IpAddr::from(gateway)
        );
    }

    #[test]
    fn both_reserved_hosts_are_own() {
        let gateway = ip("28.0.0.1");
        for device in [gateway, ip("28.0.0.2"), ip("172.19.0.1")] {
            assert_eq!(
                GuardAddrs::new(gateway, device).own,
                [IpAddr::from(gateway), IpAddr::from(ip("28.0.0.2"))]
            );
        }
    }
}
