use std::{io, net::IpAddr};

#[path = "windows_dns_native.rs"]
mod native;

trait Port {
    fn dns(&mut self) -> io::Result<String>;
    fn set_dns(&mut self, servers: &str) -> io::Result<()>;
    fn metric(&mut self) -> io::Result<(u32, bool)>;
    fn set_metric(&mut self, metric: (u32, bool)) -> io::Result<()>;
    fn flush(&mut self) -> io::Result<()>;
}

struct Scope<P: Port> {
    port: P,
    previous_dns: String,
    previous_metric: (u32, bool),
    installed: String,
}

impl<P: Port> Scope<P> {
    fn setup(mut port: P, address: IpAddr) -> io::Result<Self> {
        let previous_dns = port.dns()?;
        let previous_metric = port.metric()?;
        let mut scope = Self {
            port,
            previous_dns,
            previous_metric,
            installed: address.to_string(),
        };
        scope.port.set_dns(&scope.installed)?;
        scope.port.set_metric((0, false))?;
        scope.port.flush()?;
        Ok(scope)
    }
}

impl<P: Port> Drop for Scope<P> {
    fn drop(&mut self) {
        let mut restore = || -> io::Result<()> {
            let mut first_error = None;
            if self.port.dns()? == self.installed {
                if let Err(error) = self.port.set_dns(&self.previous_dns) {
                    first_error = Some(error);
                }
            }
            if self.port.metric()? == (0, false) {
                if let Err(error) = self.port.set_metric(self.previous_metric) {
                    first_error.get_or_insert(error);
                }
            }
            if let Some(error) = first_error {
                return Err(error);
            }
            Ok(())
        };
        if let Err(error) = restore() {
            tracing::warn!("TUN adapter DNS cleanup failed: {error}");
        }
        if let Err(error) = self.port.flush() {
            tracing::warn!("TUN DNS cache flush failed: {error}");
        }
    }
}

pub(super) struct DnsGuard {
    _scope: Scope<native::Native>,
}
impl DnsGuard {
    pub(super) fn setup(interface: u32, address: IpAddr) -> io::Result<Self> {
        Ok(Self {
            _scope: Scope::setup(native::Native::new(interface)?, address)?,
        })
    }
}

#[cfg(test)]
pub(super) fn test_owned_adapter(index: u32) {
    let mut port = native::Native::new(index).unwrap();
    let original_dns = port.dns().unwrap();
    let original_metric = port.metric().unwrap();
    for previous in ["", "1.1.1.1,8.8.8.8"] {
        port.set_dns(previous).unwrap();
        let guard = DnsGuard::setup(index, "198.18.0.2".parse().unwrap()).unwrap();
        assert_eq!(port.dns().unwrap(), "198.18.0.2");
        assert_eq!(port.metric().unwrap(), (0, false));
        drop(guard);
        assert_eq!(port.dns().unwrap(), previous);
        assert_eq!(port.metric().unwrap(), original_metric);
    }
    let guard = DnsGuard::setup(index, "198.18.0.2".parse().unwrap()).unwrap();
    port.set_dns("9.9.9.9").unwrap();
    drop(guard);
    assert_eq!(port.dns().unwrap(), "9.9.9.9");
    port.set_dns(&original_dns).unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, rc::Rc};
    #[derive(Clone)]
    struct Recording(Rc<RefCell<(String, (u32, bool), bool)>>);
    impl Port for Recording {
        fn dns(&mut self) -> io::Result<String> {
            Ok(self.0.borrow().0.clone())
        }
        fn set_dns(&mut self, servers: &str) -> io::Result<()> {
            self.0.borrow_mut().0 = servers.into();
            Ok(())
        }
        fn metric(&mut self) -> io::Result<(u32, bool)> {
            Ok(self.0.borrow().1)
        }
        fn set_metric(&mut self, value: (u32, bool)) -> io::Result<()> {
            if self.0.borrow().2 {
                return Err(io::Error::other("denied"));
            }
            self.0.borrow_mut().1 = value;
            Ok(())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    #[test]
    fn owned_adapter_dns_and_metric_restore_for_dhcp_and_static() {
        for previous in ["", "1.1.1.1,8.8.8.8"] {
            let state = Rc::new(RefCell::new((previous.to_owned(), (35, true), false)));
            let guard =
                Scope::setup(Recording(state.clone()), "198.18.0.2".parse().unwrap()).unwrap();
            assert_eq!(state.borrow().0, "198.18.0.2");
            assert_eq!(state.borrow().1, (0, false));
            drop(guard);
            assert_eq!(state.borrow().0, previous);
            assert_eq!(state.borrow().1, (35, true));
        }
    }
    #[test]
    fn partial_setup_rolls_back_and_manual_adapter_changes_survive() {
        let state = Rc::new(RefCell::new(("1.1.1.1".into(), (35, true), true)));
        assert!(Scope::setup(Recording(state.clone()), "198.18.0.2".parse().unwrap()).is_err());
        assert_eq!(state.borrow().0, "1.1.1.1");
        state.borrow_mut().2 = false;
        let guard = Scope::setup(Recording(state.clone()), "198.18.0.2".parse().unwrap()).unwrap();
        state.borrow_mut().0 = "9.9.9.9".into();
        state.borrow_mut().1 = (9, false);
        drop(guard);
        assert_eq!(state.borrow().0, "9.9.9.9");
        assert_eq!(state.borrow().1, (9, false));
    }
}
