//! SECURITY-SENSITIVE — requires human review before merge (key import).
//!
//! Coldcard file formats. The multisig setup file is also what Sparrow, Jade,
//! Keystone and Passport read and write.

use serde_json::Value;

use crate::models::*;
use crate::wallet::descriptor::{self, fmt_path, parse_fingerprint, parse_path, parse_xpub};

/// Coldcard limits multisig names to 20 characters.
pub fn device_name(name: &str) -> String {
    name.chars().filter(|c| c.is_ascii_graphic() || *c == ' ').take(20).collect::<String>().trim().to_string()
}

fn format_name(script: ScriptType) -> Result<&'static str, WalletError> {
    match script {
        ScriptType::P2sh => Ok("P2SH"),
        ScriptType::P2shP2wsh => Ok("P2SH-P2WSH"),
        ScriptType::P2wsh => Ok("P2WSH"),
        _ => Err(WalletError::NotSupported { message: "setup files are for multisig wallets".into() }),
    }
}

pub fn export_multisig(config: &WalletConfig, network: Network) -> Result<String, WalletError> {
    let keys = descriptor::validate(config, network)?;
    let mut out = format!(
        "# Northvault multisig setup file\n#\nName: {}\nPolicy: {} of {}\nFormat: {}\n",
        device_name(&config.name),
        config.threshold,
        keys.len(),
        format_name(config.script_type)?
    );
    for k in &keys {
        // Per-key derivation lines: Coldcard, Sparrow and Jade all accept them.
        out += &format!("\nDerivation: {}\n{}: {}\n", fmt_path(&k.path), k.fingerprint.to_string().to_uppercase(), k.xpub);
    }
    Ok(out)
}

pub fn looks_like_multisig_file(text: &str) -> bool {
    text.lines().any(|l| l.trim_start().to_ascii_lowercase().starts_with("policy:"))
}

pub fn import_multisig(text: &str, network: Network) -> Result<WalletConfig, WalletError> {
    let mut name = String::new();
    let mut policy: Option<(u32, usize)> = None;
    let mut script = None;
    let mut derivation: Option<String> = None;
    let mut keystores = Vec::new();

    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            return Err(WalletError::interop(format!("unexpected line: {line}")));
        };
        let (key, value) = (key.trim(), value.trim());
        match key.to_ascii_lowercase().as_str() {
            "name" => name = value.to_string(),
            "policy" => {
                let parts: Vec<&str> = value.split(|c: char| c == '/' || c.is_whitespace()).filter(|p| !p.is_empty() && *p != "of").collect();
                let (Some(m), Some(n)) = (parts.first().and_then(|m| m.parse().ok()), parts.get(1).and_then(|n| n.parse().ok())) else {
                    return Err(WalletError::interop("couldn't read Policy"));
                };
                policy = Some((m, n));
            }
            "format" => {
                script = Some(match value.to_ascii_uppercase().as_str() {
                    "P2SH" => ScriptType::P2sh,
                    "P2SH-P2WSH" | "P2WSH-P2SH" => ScriptType::P2shP2wsh,
                    "P2WSH" => ScriptType::P2wsh,
                    other => return Err(WalletError::interop(format!("unsupported Format: {other}"))),
                })
            }
            "derivation" => derivation = Some(value.to_string()),
            xfp if xfp.len() == 8 && xfp.chars().all(|c| c.is_ascii_hexdigit()) => {
                let xpub = parse_xpub(value, network)?;
                let path = match &derivation {
                    Some(d) => parse_path(d)?,
                    None => return Err(WalletError::interop("missing Derivation line")),
                };
                keystores.push(Keystore {
                    label: format!("Keystore {}", keystores.len() + 1),
                    fingerprint: parse_fingerprint(xfp)?.to_string(),
                    derivation_path: fmt_path(&path),
                    xpub: xpub.to_string(),
                    device: None,
                });
            }
            _ => {} // Unknown header lines are ignored, like Coldcard does.
        }
    }

    let (m, n) = policy.ok_or(WalletError::interop("missing Policy"))?;
    if n != keystores.len() {
        return Err(WalletError::interop(format!("Policy says {n} keys but the file has {}", keystores.len())));
    }
    let config = WalletConfig {
        name: if name.is_empty() { "Imported multisig".into() } else { name },
        script_type: script.unwrap_or(ScriptType::P2sh), // Coldcard's documented default
        threshold: m,
        keystores,
    };
    descriptor::validate(&config, network)?;
    Ok(config)
}

/// Reads one keystore for `script` from a Coldcard export:
/// generic wallet export (`coldcard-export.json`) or multisig xpub export (`ccxp-*.json`).
/// Sparrow writes the same JSON shapes for its keystore exports.
pub fn import_keystore(json: &str, script: ScriptType, network: Network) -> Result<Keystore, WalletError> {
    let v: Value = serde_json::from_str(json).map_err(|e| WalletError::interop(e.to_string()))?;
    let xfp = v.get("xfp").and_then(Value::as_str).ok_or_else(|| WalletError::interop("missing xfp"))?;
    let fingerprint = parse_fingerprint(xfp)?.to_string();

    // Generic export nests per BIP ("bip84": {"xpub", "deriv"}); multisig export is flat.
    let (bip, flat) = match script {
        ScriptType::P2pkh => ("bip44", None),
        ScriptType::P2shP2wpkh => ("bip49", None),
        ScriptType::P2wpkh => ("bip84", None),
        ScriptType::P2tr => ("bip86", None),
        ScriptType::P2sh => ("bip45", Some("p2sh")),
        ScriptType::P2shP2wsh => ("bip48_1", Some("p2sh_p2wsh")),
        ScriptType::P2wsh => ("bip48_2", Some("p2wsh")),
    };
    let (xpub, deriv) = if let Some(section) = v.get(bip) {
        (section.get("xpub").and_then(Value::as_str), section.get("deriv").and_then(Value::as_str))
    } else if let Some(flat) = flat {
        (v.get(flat).and_then(Value::as_str), v.get(format!("{flat}_deriv")).and_then(Value::as_str))
    } else {
        (None, None)
    };
    let (Some(xpub), Some(deriv)) = (xpub, deriv) else {
        return Err(WalletError::interop("this export has no key for the selected script type"));
    };
    Ok(Keystore {
        label: "Coldcard".into(),
        fingerprint,
        derivation_path: fmt_path(&parse_path(deriv)?),
        xpub: parse_xpub(xpub, network)?.to_string(),
        device: Some(DeviceKind::Coldcard),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wallet::test_keys::multisig_config;

    #[test]
    fn setup_file_round_trip() {
        let config = multisig_config(ScriptType::P2wsh, 2, 3);
        let text = export_multisig(&config, Network::Bitcoin).unwrap();
        assert!(text.contains("Policy: 2 of 3") && text.contains("Format: P2WSH"));
        let back = import_multisig(&text, Network::Bitcoin).unwrap();
        assert_eq!(descriptor::build(&back, Network::Bitcoin).unwrap(), descriptor::build(&config, Network::Bitcoin).unwrap());
    }

    #[test]
    fn rejects_key_count_mismatch() {
        let config = multisig_config(ScriptType::P2wsh, 2, 3);
        let text = export_multisig(&config, Network::Bitcoin).unwrap().replace("2 of 3", "2 of 4");
        assert!(import_multisig(&text, Network::Bitcoin).is_err());
    }

    #[test]
    fn generic_json_export() {
        let json =
            format!(r#"{{"xfp": "73C5DA0A", "bip84": {{"xpub": "{}", "deriv": "m/84'/0'/0'", "name": "p2wpkh"}}}}"#, crate::wallet::descriptor::tests::ZPUB);
        let ks = import_keystore(&json, ScriptType::P2wpkh, Network::Bitcoin).unwrap();
        assert_eq!(ks.fingerprint, "73c5da0a");
        assert!(ks.xpub.starts_with("xpub"));
        assert!(import_keystore(&json, ScriptType::P2tr, Network::Bitcoin).is_err());
    }
}
