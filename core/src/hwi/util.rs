//! Shared helpers for the device modules: per-address multisig keys and scripts.

use bdk_wallet::bitcoin::bip32::{ChildNumber, DerivationPath, Fingerprint, Xpub};
use bdk_wallet::bitcoin::secp256k1::{PublicKey, Secp256k1};
use bdk_wallet::bitcoin::ScriptBuf;

use crate::models::*;
use crate::store::WalletRecord;
use crate::wallet::descriptor::{self, parse_fingerprint, parse_path, parse_xpub};

pub struct CosignerKey {
    pub fingerprint: Fingerprint,
    /// Full path from the master key to this address key.
    pub path: DerivationPath,
    /// Path below the account xpub: [chain, index].
    pub child: [ChildNumber; 2],
    pub account_xpub: Xpub,
    pub pubkey: PublicKey,
}

pub fn chain_index(chain: Chain) -> u32 {
    if chain == Chain::Receive {
        0
    } else {
        1
    }
}

/// Every cosigner's key for one address, sorted like `sortedmulti` (BIP67).
pub fn keys_at(record: &WalletRecord, network: Network, chain: Chain, index: u32) -> Result<Vec<CosignerKey>, WalletError> {
    let secp = Secp256k1::verification_only();
    let child =
        [ChildNumber::from_normal_idx(chain_index(chain)).map_err(WalletError::backend)?, ChildNumber::from_normal_idx(index).map_err(WalletError::backend)?];
    let mut keys = record
        .keystores
        .iter()
        .map(|k| {
            let account_xpub = parse_xpub(&k.xpub, network)?;
            let pubkey = account_xpub.derive_pub(&secp, &child).map_err(WalletError::backend)?.public_key;
            Ok(CosignerKey {
                fingerprint: parse_fingerprint(&k.fingerprint)?,
                path: parse_path(&k.derivation_path)?.extend(child),
                child,
                account_xpub,
                pubkey,
            })
        })
        .collect::<Result<Vec<_>, WalletError>>()?;
    keys.sort_by_key(|k| k.pubkey.serialize());
    Ok(keys)
}

/// The multisig script itself (witness script for P2WSH / P2SH-P2WSH, redeem script for P2SH).
pub fn multisig_script(record: &WalletRecord, chain: Chain, index: u32) -> Result<ScriptBuf, WalletError> {
    let (receive, change) = descriptor::split(&record.descriptor)?;
    let desc = if chain == Chain::Receive { receive } else { change };
    desc.at_derivation_index(index).map_err(WalletError::backend)?.explicit_script().map_err(WalletError::backend)
}

/// The keystore in `record` that lives on the device with this master fingerprint.
pub fn own_keystore<'a>(record: &'a WalletRecord, device_fp: &Fingerprint) -> Result<&'a Keystore, WalletError> {
    record
        .keystores
        .iter()
        .find(|k| parse_fingerprint(&k.fingerprint).ok().as_ref() == Some(device_fp))
        .ok_or_else(|| WalletError::device(format!("this device ({device_fp}) isn't a signer of this wallet")))
}

/// Short, device-safe wallet name (Jade allows 16 characters).
pub fn short_name(record: &WalletRecord) -> String {
    let base: String = record.name.chars().filter(|c| c.is_ascii_alphanumeric()).take(10).collect();
    format!("{}{}", if base.is_empty() { "nv".to_string() } else { base }, &record.id[..6])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wallet::test_keys::multisig_config;

    #[test]
    fn key_order_matches_script() {
        let config = multisig_config(ScriptType::P2wsh, 2, 3);
        let desc = descriptor::build(&config, Network::Bitcoin).unwrap();
        let record = WalletRecord {
            id: WalletRecord::id_for(&desc),
            name: "Vault".into(),
            script_type: ScriptType::P2wsh,
            threshold: 2,
            keystores: config.keystores,
            descriptor: desc,
            created_at: 0,
            ledger_registrations: Vec::new(),
        };
        for index in 0..5 {
            let script = multisig_script(&record, Chain::Change, index).unwrap();
            let keys = keys_at(&record, Network::Bitcoin, Chain::Change, index).unwrap();
            let pushed: Vec<Vec<u8>> =
                script.instructions().filter_map(|i| i.ok()?.push_bytes().map(|b| b.as_bytes().to_vec())).filter(|b| b.len() == 33).collect();
            let ours: Vec<Vec<u8>> = keys.iter().map(|k| k.pubkey.serialize().to_vec()).collect();
            assert_eq!(pushed, ours);
            assert!(keys.iter().all(|k| k.path.to_string().ends_with(&format!("/1/{index}"))));
        }
    }
}
