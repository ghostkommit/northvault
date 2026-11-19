//! SECURITY-SENSITIVE — requires human review before merge.
//!
//! Recipient address parsing. Every address the user types, pastes or scans
//! goes through here, so a wrong-network or mistyped address can't be paid.

use std::str::FromStr;

use bdk_wallet::bitcoin::address::NetworkUnchecked;
use bdk_wallet::bitcoin::Address;

use crate::models::*;

/// Accepts a plain address or a BIP21 `bitcoin:` URI (the amount in the URI is ignored).
pub fn parse_recipient(input: &str, network: Network) -> Result<Address, WalletError> {
    let s = input.trim();
    let s = match s.get(..8) {
        Some(prefix) if prefix.eq_ignore_ascii_case("bitcoin:") => s[8..].split('?').next().unwrap_or_default(),
        _ => s,
    };
    let unchecked = Address::<NetworkUnchecked>::from_str(s).map_err(|_| WalletError::InvalidAddress)?;
    unchecked.require_network(network.into()).map_err(|_| WalletError::WrongNetwork)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checks_checksum_and_network() {
        let good = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu";
        assert!(parse_recipient(good, Network::Bitcoin).is_ok());
        assert!(parse_recipient(&format!("bitcoin:{good}?amount=0.1"), Network::Bitcoin).is_ok());
        assert!(matches!(parse_recipient(good, Network::Signet), Err(WalletError::WrongNetwork)));
        // One character changed: bech32 checksum fails.
        assert!(matches!(parse_recipient("bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyv", Network::Bitcoin), Err(WalletError::InvalidAddress)));
        assert!(matches!(parse_recipient("nope", Network::Bitcoin), Err(WalletError::InvalidAddress)));
    }
}
