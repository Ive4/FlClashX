use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

const BULK: &[&str] = &["proxies", "proxy-groups", "rules", "sub-rules"];
pub const MAX_PROFILE_BYTES: u64 = 128 * 1024 * 1024;

pub fn read(path: &str) -> Result<Value> {
    let bytes = read_bytes(Path::new(path))?;
    let plain = decrypt_bytes(&bytes, "")?;
    parse(std::str::from_utf8(&plain).context("Profile is not UTF-8")?)
}

pub fn read_bytes(path: &Path) -> Result<Vec<u8>> {
    use std::io::Read;
    let mut bytes = Vec::new();
    fs::File::open(path)
        .with_context(|| format!("Read {}", path.display()))?
        .take(MAX_PROFILE_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_PROFILE_BYTES {
        bail!("Profile exceeds 128 MiB");
    }
    Ok(bytes)
}

pub fn decrypt_bytes(bytes: &[u8], secret: &str) -> Result<Vec<u8>> {
    use std::io::Read;
    if !bytes.starts_with(b"-----BEGIN AGE ENCRYPTED FILE-----")
        && !bytes.starts_with(b"age-encryption.org/v1")
    {
        return Ok(bytes.to_vec());
    }
    let identities = secret
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| {
            line.parse::<age::x25519::Identity>()
                .map_err(anyhow::Error::msg)
        })
        .collect::<Result<Vec<_>>>()?;
    if identities.is_empty() {
        bail!("An age secret key is required to decrypt this profile");
    }
    let input = age::armor::ArmoredReader::new(bytes);
    let decryptor = age::Decryptor::new(input)?;
    let reader = decryptor.decrypt(identities.iter().map(|key| key as &dyn age::Identity))?;
    let mut output = Vec::new();
    reader
        .take(MAX_PROFILE_BYTES + 1)
        .read_to_end(&mut output)?;
    if output.len() as u64 > MAX_PROFILE_BYTES {
        bail!("Decrypted profile exceeds 128 MiB");
    }
    Ok(output)
}

pub fn parse(text: &str) -> Result<Value> {
    let text = text.trim_start_matches('\u{feff}');
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    meow_common::yaml::run_on_parse_stack(text, |text| {
        let options = serde_saphyr::options! {
            strict_booleans: true,
            reject_unsupported_tags: true,
            ignore_binary_tag_for_string: true,
            budget: serde_saphyr::budget! { max_depth: meow_common::yaml::MAX_DEPTH },
        };
        let value: Value = serde_saphyr::from_str_with_options(text, options)?;
        reject_numeric_short_ids(&value)?;
        if value.is_null() {
            return Ok(json!({}));
        }
        if !value.is_object() {
            bail!("A profile must be a YAML mapping");
        }
        Ok(value)
    })
    .context("Cannot spawn profile parse thread")?
}

fn reject_numeric_short_ids(value: &Value) -> Result<()> {
    match value {
        Value::Object(mapping) => {
            for (key, value) in mapping {
                if key == "short-id"
                    && (value.is_number()
                        || value
                            .as_array()
                            .is_some_and(|items| items.iter().any(Value::is_number)))
                {
                    bail!("Unquoted numeric REALITY short-id cannot be preserved by this parser; quote the original short-id literal in the profile");
                }
                reject_numeric_short_ids(value)?;
            }
        }
        Value::Array(items) => {
            for item in items {
                reject_numeric_short_ids(item)?;
            }
        }
        _ => {}
    }
    Ok(())
}

pub fn base(path: &str) -> Result<Value> {
    let bytes = read_bytes(Path::new(path))?;
    let plain = decrypt_bytes(&bytes, "")?;
    let mut config = parse(std::str::from_utf8(&plain)?)?;
    let rules = array(&config, "rules")?;
    let mut result = json!({
        "digest": hex::encode(Sha256::digest(&bytes)),
        "proxies": array(&config, "proxies")?.len(),
        "proxy-groups": array(&config, "proxy-groups")?.len(),
        "rules": rules.len(),
        "match-rules": rules.iter().filter(|r| r.as_str().is_some_and(|r| r.split(',').next().unwrap_or("").trim().eq_ignore_ascii_case("MATCH"))).collect::<Vec<_>>(),
    });
    for key in BULK {
        config.as_object_mut().unwrap().remove(*key);
    }
    result["config"] = config;
    Ok(result)
}

pub fn outbounds(path: &str) -> Result<Value> {
    let config = read(path)?;
    let entries = |key| -> Result<Vec<Value>> {
        array(&config, key)?.iter().map(|p| {
            Ok(json!({"name": p["name"].as_str().context("Outbound has no name")?, "type": p["type"].as_str().context("Outbound has no type")?}))
        }).collect()
    };
    Ok(json!({"proxies": entries("proxies")?, "proxy-groups": entries("proxy-groups")?}))
}

pub fn merge(base: &Value, home: &Path) -> Result<Value> {
    if base.is_null() {
        return read(&home.join("config.yaml").to_string_lossy());
    }
    let path = base["path"].as_str().context("Missing profile path")?;
    let profile = read(path)?;
    let mut overlay = parse(
        base["overlay"]
            .as_str()
            .context("Missing profile overlay")?,
    )?;
    let mut rules = array(&overlay, "rules")?;
    rules.extend(array(&profile, "rules")?);
    for key in &["proxies", "proxy-groups", "sub-rules"] {
        if let Some(value) = profile.get(*key) {
            overlay[*key] = value.clone();
        }
    }
    overlay["rules"] = Value::Array(rules);
    Ok(overlay)
}

pub fn patch(target: &mut Value, changes: &Value) {
    if let (Some(target), Some(changes)) = (target.as_object_mut(), changes.as_object()) {
        for (key, value) in changes {
            if value.is_null() {
                continue;
            }
            if value.is_object() {
                let item = target.entry(key).or_insert_with(|| json!({}));
                if !item.is_object() {
                    *item = json!({});
                }
                patch(item, value);
            } else {
                target.insert(key.clone(), value.clone());
            }
        }
    }
}

pub struct StagedFile {
    temporary: PathBuf,
    target: PathBuf,
}

impl StagedFile {
    pub fn bytes(path: &Path, bytes: &[u8]) -> Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        let staged = Self {
            temporary,
            target: path.into(),
        };
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&staged.temporary)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o644))?;
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        Ok(staged)
    }

    pub fn document(path: &Path, value: &Value) -> Result<Self> {
        Self::bytes(path, serde_saphyr::to_string(value)?.as_bytes())
    }

    pub fn commit(self) -> Result<()> {
        fs::rename(&self.temporary, &self.target)
            .with_context(|| format!("Commit {}", self.target.display()))?;
        Ok(())
    }
}

impl Drop for StagedFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.temporary);
    }
}

pub fn write(path: &Path, value: &Value) -> Result<()> {
    StagedFile::document(path, value)?.commit()
}

pub fn spill_path(home: &Path, extension: &str) -> Result<PathBuf> {
    if home.as_os_str().is_empty() {
        bail!("Core has not been initialized");
    }
    let dir = home.join("responses");
    fs::create_dir_all(&dir)?;
    crate::ownership::reclaim_path(home, &dir)?;
    Ok(dir.join(format!("{}.{}", uuid::Uuid::new_v4(), extension)))
}

pub fn runtime_document(config: &Value, listening: bool, mobile: bool) -> Result<Value> {
    let mut config = config.clone();
    if !config.is_object() {
        bail!("A config must be a mapping");
    }
    config["strict"] = json!(true);
    config["logbook"] = json!({"enable": false});
    if let Some(auto) = config.get("geo-auto-update").cloned() {
        ensure_object(&mut config, "geodata")["auto-update"] = auto;
    }
    if let Some(interval) = config.get("geo-update-interval").cloned() {
        ensure_object(&mut config, "geodata")["auto-update-interval"] = interval;
    }
    if mobile || !listening {
        config["tun"] = json!({"enable": false});
    }
    if !listening {
        for key in [
            "port",
            "socks-port",
            "mixed-port",
            "redir-port",
            "tproxy-port",
            "listeners",
            "tunnels",
            "external-controller",
        ] {
            config.as_object_mut().unwrap().remove(key);
        }
        if let Some(dns) = config["dns"].as_object_mut() {
            dns.remove("listen");
        }
    }
    if let Some(dns) = config["dns"].as_object_mut() {
        if dns.get("listen").and_then(Value::as_str) == Some("") {
            dns.remove("listen");
        }
    }
    if config["external-controller"].as_str() == Some("") {
        config
            .as_object_mut()
            .unwrap()
            .remove("external-controller");
    }
    if let Some(tun) = config["tun"].as_object_mut() {
        normalize_tun_device(tun, cfg!(target_os = "macos"));
    }
    Ok(config)
}

fn normalize_tun_device(tun: &mut serde_json::Map<String, Value>, macos: bool) {
    let Some(device) = tun.get("device").and_then(Value::as_str) else {
        return;
    };
    let valid_macos_name = device
        .strip_prefix("utun")
        .is_some_and(|index| index.parse::<u32>().is_ok());
    if device.is_empty() || (macos && !valid_macos_name) {
        tun.remove("device");
    }
}

fn ensure_object<'a>(value: &'a mut Value, key: &str) -> &'a mut Value {
    if !value[key].is_object() {
        value[key] = json!({});
    }
    &mut value[key]
}

pub fn array(value: &Value, key: &str) -> Result<Vec<Value>> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(array)) => Ok(array.clone()),
        _ => bail!("{key} must be a list"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tun_device_names_use_platform_defaults_only_when_required() {
        for (macos, device, expected) in [
            (true, "FlClash", None),
            (true, "FlClashX", None),
            (true, "custom-tun", None),
            (true, "", None),
            (true, "utun", None),
            (true, "utun7-1", None),
            (true, "utun0", Some("utun0")),
            (true, "utun7", Some("utun7")),
            (false, "FlClashX", Some("FlClashX")),
            (false, "custom-tun", Some("custom-tun")),
            (false, "", None),
        ] {
            let mut tun = json!({"enable":true,"device":device,"auto-route":true});
            normalize_tun_device(tun.as_object_mut().unwrap(), macos);
            assert_eq!(tun.get("device").and_then(Value::as_str), expected);
            assert_eq!(tun["enable"], true);
            assert_eq!(tun["auto-route"], true);
        }
    }
}
