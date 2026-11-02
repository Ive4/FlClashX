use crate::protocol::{self, MethodError};
use ipnet::IpNet;
use serde_json::{json, Value};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RouteLists {
    pub include: Vec<IpNet>,
    pub exclude: Vec<IpNet>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OsRoutePlan {
    pub routes: Vec<IpNet>,
    pub ipv6: bool,
}

fn invalid(path: &str, value: &Value, reason: &str) -> MethodError {
    MethodError::new("invalid_config", format!("{path}: {reason}"))
        .details(json!({"path":path,"value":value}))
}

pub fn parse_cidrs(value: &Value, path: &str) -> protocol::Result<Vec<IpNet>> {
    if value.is_null() {
        return Ok(Vec::new());
    }
    let values = value
        .as_array()
        .ok_or_else(|| invalid(path, value, "expected a list of IPv4 or IPv6 CIDRs"))?;
    let mut nets = Vec::with_capacity(values.len());
    for (index, value) in values.iter().enumerate() {
        let path = format!("{path}[{index}]");
        let text = value
            .as_str()
            .ok_or_else(|| invalid(&path, value, "expected an IPv4 or IPv6 CIDR string"))?;
        let net = text
            .parse::<IpNet>()
            .map_err(|_| invalid(&path, value, "invalid IPv4 or IPv6 CIDR"))?;
        nets.push(net.trunc());
    }
    Ok(IpNet::aggregate(&nets))
}

impl RouteLists {
    pub fn parse(tun: &Value) -> protocol::Result<Self> {
        Ok(Self {
            include: parse_cidrs(&tun["route-address"], "tun.route-address")?,
            exclude: parse_cidrs(&tun["route-exclude-address"], "tun.route-exclude-address")?,
        })
    }

    pub fn configured(&self) -> bool {
        !self.include.is_empty() || !self.exclude.is_empty()
    }

    pub fn routes(&self, defaults: &[IpNet]) -> Vec<IpNet> {
        subtract(
            if self.include.is_empty() {
                defaults
            } else {
                &self.include
            },
            &self.exclude,
        )
    }

    pub fn desktop_plan(
        &self,
        defaults: &[IpNet],
        ipv6: bool,
    ) -> protocol::Result<Option<Vec<IpNet>>> {
        if !self.configured() {
            return Ok(None);
        }
        self.validate_ipv6(ipv6)?;
        let routes = self.routes(defaults);
        let routes = routes
            .into_iter()
            .flat_map(|net| {
                if net.prefix_len() == 0 {
                    net.subnets(1)
                        .expect("a default route can be split")
                        .collect::<Vec<_>>()
                } else {
                    vec![net]
                }
            })
            .collect();
        Ok(Some(routes))
    }

    fn validate_ipv6(&self, ipv6: bool) -> protocol::Result<()> {
        if !ipv6 && self.include.iter().any(|net| net.addr().is_ipv6()) {
            return Err(MethodError::new(
                "unsupported_config",
                "tun.route-address requests IPv6 routes but the VPN has no IPv6 address",
            )
            .details(json!({"path":"tun.route-address"})));
        }
        Ok(())
    }
}

impl OsRoutePlan {
    pub fn parse(options: &Value) -> protocol::Result<Option<Self>> {
        if options.get("routes").is_none() && options.get("ipv6").is_none() {
            return Ok(None);
        }
        let ipv6 = options["ipv6"].as_bool().ok_or_else(|| {
            invalid(
                "ipv6",
                &options["ipv6"],
                "OS route metadata requires an IPv6 boolean",
            )
        })?;
        if !options["routes"].is_array() {
            return Err(invalid(
                "routes",
                &options["routes"],
                "OS route metadata requires a CIDR list",
            ));
        }
        let routes = parse_cidrs(&options["routes"], "routes")?;
        if !ipv6 && routes.iter().any(|net| net.addr().is_ipv6()) {
            return Err(invalid(
                "routes",
                &options["routes"],
                "installed IPv6 routes require an IPv6 VPN address",
            ));
        }
        Ok(Some(Self { routes, ipv6 }))
    }
}

pub fn validate(document: &Value) -> protocol::Result<()> {
    let lists = RouteLists::parse(&document["tun"])?;
    if lists.configured() && cfg!(target_os = "android") {
        return Err(MethodError::new(
            "unsupported_config",
            "Android route declarations require native installed-route metadata",
        )
        .details(json!({"path":"tun.route-address"})));
    }
    if lists.configured() && document["tun"]["enable"] == true {
        if !cfg!(target_env = "ohos") && document["tun"]["auto-route"] == false {
            return Err(MethodError::new(
                "unsupported_config",
                "TUN route lists require tun.auto-route",
            )
            .details(json!({"path":"tun.auto-route","value":false})));
        }
    }
    Ok(())
}

pub fn validate_mobile(document: &Value, installed: Option<&OsRoutePlan>) -> protocol::Result<()> {
    let lists = RouteLists::parse(&document["tun"])?;
    if !lists.configured() {
        return Ok(());
    }
    let installed = installed.ok_or_else(|| {
        MethodError::new(
            "unsupported_config",
            "TUN route declarations cannot be verified without native installed-route metadata",
        )
        .details(json!({"path":"tun.route-address"}))
    })?;
    lists.validate_ipv6(installed.ipv6)?;
    let mut defaults = vec!["0.0.0.0/0".parse().unwrap()];
    if installed.ipv6 {
        defaults.push("::/0".parse().unwrap());
    }
    let mut expected = lists.routes(&defaults);
    expected.retain(|net| installed.ipv6 || net.addr().is_ipv4());
    expected.push("172.19.0.2/32".parse().unwrap());
    let expected = IpNet::aggregate(&expected);
    let actual = IpNet::aggregate(&installed.routes);
    if expected != actual {
        return Err(MethodError::new("unsupported_config", "Profile TUN route lists do not match the installed VPN routes; restart with matching native route settings")
            .details(json!({"path":"tun.route-address","expected":expected.iter().map(ToString::to_string).collect::<Vec<_>>(),"installed":actual.iter().map(ToString::to_string).collect::<Vec<_>>()})));
    }
    Ok(())
}

pub fn subtract(include: &[IpNet], exclude: &[IpNet]) -> Vec<IpNet> {
    let mut routes = IpNet::aggregate(&include.to_vec());
    for excluded in IpNet::aggregate(&exclude.to_vec()) {
        let mut remaining = Vec::new();
        for route in routes {
            subtract_one(route, excluded, &mut remaining);
        }
        routes = remaining;
    }
    IpNet::aggregate(&routes)
}

fn subtract_one(route: IpNet, excluded: IpNet, output: &mut Vec<IpNet>) {
    if excluded.contains(&route) {
        return;
    }
    if !route.contains(&excluded) {
        output.push(route);
        return;
    }
    for child in route
        .subnets(route.prefix_len() + 1)
        .expect("overlap has a more specific prefix")
    {
        subtract_one(child, excluded, output);
    }
}
