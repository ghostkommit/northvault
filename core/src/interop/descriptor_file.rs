//! SECURITY-SENSITIVE — requires human review before merge (key import).
//!
//! Output descriptor text files, single-line descriptors pasted or scanned
//! from anywhere else, and Specter DIY `addwallet` lines.

use crate::models::*;
use crate::wallet::descriptor;

pub fn export(config: &WalletConfig, network: Network) -> Result<String, WalletError> {
    let multipath = descriptor::build(config, network)?;
    let (receive, change) = descriptor::split(&multipath)?;
    Ok(format!(
        "# Receive and change descriptor (BIP389):\n{multipath}\n\n# Receive descriptor (Bitcoin Core):\n{receive}\n\n# Change descriptor (Bitcoin Core):\n{change}\n"
    ))
}

/// Specter DIY wallet line: `addwallet <name>&<descriptor>`, keys without a
/// branch suffix (the device implies receive `/0/*` and change `/1/*`).
pub fn export_specter(config: &WalletConfig, network: Network) -> Result<String, WalletError> {
    let multipath = descriptor::build(config, network)?;
    let body = multipath.split('#').next().unwrap_or_default().replace("/<0;1>/*", "").replace('\'', "h");
    Ok(format!("addwallet {}&{body}\n", config.name.replace('&', " ")))
}

/// Splits an `addwallet` line into its name and a descriptor with the implied branches written out.
fn specter_line(line: &str) -> Option<(&str, String)> {
    let (name, body) = line.strip_prefix("addwallet ")?.split_once('&')?;
    let mut descriptor = String::new();
    let mut in_key = false;
    for c in body.chars() {
        if in_key && (c == ',' || c == ')') {
            descriptor += "/<0;1>/*";
            in_key = false;
        }
        in_key |= c == ']';
        descriptor.push(c);
    }
    Some((name, descriptor))
}

/// Uses the first line that parses as a descriptor. Comment lines are skipped.
pub fn import(text: &str, name: &str, network: Network) -> Result<WalletConfig, WalletError> {
    let mut last_error = None;
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        let specter = specter_line(line);
        let (name, line) = specter.as_ref().map_or((name, line), |(name, descriptor)| (*name, descriptor.as_str()));
        match descriptor::parse(line, name, network) {
            Ok(config) => return Ok(config),
            Err(e @ (WalletError::PrivateKeyNotAllowed | WalletError::WrongNetwork)) => return Err(e),
            Err(e) => last_error = Some(e),
        }
    }
    Err(last_error.unwrap_or_else(|| WalletError::interop("no descriptor found")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wallet::test_keys::multisig_config;

    #[test]
    fn round_trip() {
        let config = multisig_config(ScriptType::P2shP2wsh, 2, 3);
        let text = export(&config, Network::Bitcoin).unwrap();
        let back = import(&text, "Vault", Network::Bitcoin).unwrap();
        assert_eq!(descriptor::build(&back, Network::Bitcoin).unwrap(), descriptor::build(&config, Network::Bitcoin).unwrap());
    }
}
