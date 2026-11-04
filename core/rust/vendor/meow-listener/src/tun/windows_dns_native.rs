use std::io;
use windows_sys::{
    core::GUID,
    Win32::{
        NetworkManagement::{
            IpHelper::{
                ConvertInterfaceGuidToLuid, ConvertInterfaceIndexToLuid,
                ConvertInterfaceLuidToGuid, FreeInterfaceDnsSettings, GetInterfaceDnsSettings,
                GetIpInterfaceEntry, SetInterfaceDnsSettings, SetIpInterfaceEntry,
                DNS_INTERFACE_SETTINGS, DNS_INTERFACE_SETTINGS_VERSION1, DNS_SETTING_NAMESERVER,
                MIB_IPINTERFACE_ROW,
            },
            Ndis::NET_LUID_LH,
        },
        Networking::WinSock::AF_INET,
    },
};

#[link(name = "dnsapi")]
unsafe extern "system" {
    fn DnsFlushResolverCache() -> i32;
}

fn check(status: u32) -> io::Result<()> {
    if status == 0 {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(status as i32))
    }
}

pub(super) struct Native {
    interface: GUID,
}
impl Native {
    pub(super) fn new(index: u32) -> io::Result<Self> {
        let mut luid = NET_LUID_LH::default();
        let mut interface = GUID::from_u128(0);
        check(unsafe { ConvertInterfaceIndexToLuid(index, &mut luid) })?;
        check(unsafe { ConvertInterfaceLuidToGuid(&luid, &mut interface) })?;
        Ok(Self { interface })
    }
    fn row(&self) -> io::Result<MIB_IPINTERFACE_ROW> {
        let mut row = MIB_IPINTERFACE_ROW {
            Family: AF_INET,
            ..Default::default()
        };
        check(unsafe { ConvertInterfaceGuidToLuid(&self.interface, &mut row.InterfaceLuid) })?;
        check(unsafe { GetIpInterfaceEntry(&mut row) })?;
        Ok(row)
    }
}

impl super::Port for Native {
    fn dns(&mut self) -> io::Result<String> {
        let mut settings = DNS_INTERFACE_SETTINGS {
            Version: DNS_INTERFACE_SETTINGS_VERSION1,
            ..Default::default()
        };
        check(unsafe { GetInterfaceDnsSettings(self.interface, &mut settings) })?;
        let value = if settings.NameServer.is_null() {
            Ok(String::new())
        } else {
            let mut length = 0;
            while length < 32768 && unsafe { *settings.NameServer.add(length) } != 0 {
                length += 1;
            }
            if length == 32768 {
                Err(io::Error::other("Invalid TUN DNS setting"))
            } else {
                String::from_utf16(unsafe {
                    std::slice::from_raw_parts(settings.NameServer, length)
                })
                .map_err(io::Error::other)
            }
        };
        unsafe { FreeInterfaceDnsSettings(&mut settings) };
        value
    }
    fn set_dns(&mut self, servers: &str) -> io::Result<()> {
        let mut value: Vec<u16> = servers.encode_utf16().chain(Some(0)).collect();
        let settings = DNS_INTERFACE_SETTINGS {
            Version: DNS_INTERFACE_SETTINGS_VERSION1,
            Flags: DNS_SETTING_NAMESERVER as u64,
            NameServer: value.as_mut_ptr(),
            ..Default::default()
        };
        check(unsafe { SetInterfaceDnsSettings(self.interface, &settings) })
    }
    fn metric(&mut self) -> io::Result<(u32, bool)> {
        let row = self.row()?;
        Ok((row.Metric, row.UseAutomaticMetric))
    }
    fn set_metric(&mut self, metric: (u32, bool)) -> io::Result<()> {
        let mut row = self.row()?;
        row.Metric = metric.0;
        row.UseAutomaticMetric = metric.1;
        row.SitePrefixLength = 0;
        check(unsafe { SetIpInterfaceEntry(&mut row) })
    }
    fn flush(&mut self) -> io::Result<()> {
        if unsafe { DnsFlushResolverCache() } == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}
