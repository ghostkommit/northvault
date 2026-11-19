//! SECURITY-SENSITIVE — requires human review before merge (key import).
//!
//! Sparrow "Output Descriptor" files (File → Export → Output Descriptor), and
//! single-line descriptors pasted or scanned from anywhere else.

use crate::models::*;
use crate::wallet::descriptor;

pub fn export(config: &WalletConfig, network: Network) -> Result<String, WalletError> {
    let multipath = descriptor::build(config, network)?;
    let (receive, change) = descriptor::split(&multipath)?;
    Ok(format!(
        "# Receive and change descriptor (BIP389):\n{multipath}\n\n# Receive descriptor (Bitcoin Core):\n{receive}\n\n# Change descriptor (Bitcoin Core):\n{change}\n"
    ))
}

/// Uses the first line that parses as a descriptor. Comment lines are skipped.
pub fn import(text: &str, name: &str, network: Network) -> Result<WalletConfig, WalletError> {
    let mut last_error = None;
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
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
