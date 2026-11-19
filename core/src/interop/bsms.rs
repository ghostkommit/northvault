//! SECURITY-SENSITIVE — requires human review before merge (key import).
//!
//! BIP129 (BSMS) descriptor record, unencrypted:
//! `BSMS 1.0` / descriptor with `/**` / path restrictions / first address.

use bdk_wallet::miniscript::descriptor::checksum::desc_checksum;

use crate::models::*;
use crate::wallet::descriptor;

pub fn looks_like_bsms(text: &str) -> bool {
    text.trim_start().starts_with("BSMS ")
}

pub fn export(config: &WalletConfig, network: Network) -> Result<String, WalletError> {
    let multipath = descriptor::build(config, network)?;
    let body = multipath.split('#').next().unwrap_or_default().replace("/<0;1>/*", "/**");
    let checksum = desc_checksum(&body).map_err(WalletError::backend)?;
    let (receive, _) = descriptor::split(&multipath)?;
    let first = descriptor::address_at(&receive, 0, network)?;
    Ok(format!("BSMS 1.0\n{body}#{checksum}\n/0/*,/1/*\n{first}\n"))
}

pub fn import(text: &str, name: &str, network: Network) -> Result<WalletConfig, WalletError> {
    let lines: Vec<&str> = text.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    if lines.len() < 4 || lines[0] != "BSMS 1.0" {
        return Err(WalletError::interop("expected a BSMS 1.0 descriptor record"));
    }
    if lines[2] != "/0/*,/1/*" && lines[2] != "No path restrictions" {
        return Err(WalletError::interop(format!("unsupported path restrictions: {}", lines[2])));
    }
    let (body, checksum) = lines[1].split_once('#').unwrap_or((lines[1], ""));
    if !checksum.is_empty() && desc_checksum(body).map_err(WalletError::backend)? != checksum {
        return Err(WalletError::interop("descriptor checksum doesn't match"));
    }
    let config = descriptor::parse(&body.replace("/**", "/<0;1>/*"), name, network)?;

    // BIP129 requires checking the first address against the record.
    let (receive, _) = descriptor::split(&descriptor::build(&config, network)?)?;
    if descriptor::address_at(&receive, 0, network)?.to_string() != lines[3] {
        return Err(WalletError::interop("first address doesn't match the descriptor. The file may have been altered"));
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wallet::test_keys::multisig_config;

    #[test]
    fn round_trip_and_tamper_check() {
        let config = multisig_config(ScriptType::P2wsh, 2, 3);
        let text = export(&config, Network::Bitcoin).unwrap();
        let back = import(&text, "Vault", Network::Bitcoin).unwrap();
        assert_eq!(back.threshold, 2);
        assert_eq!(descriptor::build(&back, Network::Bitcoin).unwrap(), descriptor::build(&config, Network::Bitcoin).unwrap());

        let mut lines: Vec<String> = text.lines().map(String::from).collect();
        lines[3] = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu".into();
        assert!(import(&lines.join("\n"), "Vault", Network::Bitcoin).is_err());
    }
}
