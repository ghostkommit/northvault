//! Deterministic test-only keys. Private keys exist only inside unit tests,
//! to produce xpubs and to check that PSBTs finalize.

use std::str::FromStr;

use bdk_wallet::bitcoin::bip32::{DerivationPath, Xpriv, Xpub};
use bdk_wallet::bitcoin::secp256k1::Secp256k1;
use bdk_wallet::bitcoin::NetworkKind;

use crate::models::*;
use crate::wallet::descriptor::default_path;

pub fn xpriv(seed: u8) -> Xpriv {
    Xpriv::new_master(NetworkKind::Main, &[seed; 32]).unwrap()
}

pub fn keystore(seed: u8, script: ScriptType) -> Keystore {
    keystore_on_network(seed, script, Network::Bitcoin)
}

pub fn keystore_on_network(seed: u8, script: ScriptType, network: Network) -> Keystore {
    let secp = Secp256k1::new();
    let kind = if network == Network::Bitcoin { NetworkKind::Main } else { NetworkKind::Test };
    let master = Xpriv::new_master(kind, &[seed; 32]).unwrap();
    let path_str = default_path(script, network);
    let path = DerivationPath::from_str(&path_str).unwrap();
    let account = Xpub::from_priv(&secp, &master.derive_priv(&secp, &path).unwrap());
    Keystore {
        label: format!("Key {seed}"),
        fingerprint: master.fingerprint(&secp).to_string(),
        derivation_path: path_str,
        xpub: account.to_string(),
        device: None,
    }
}

pub fn multisig_config(script: ScriptType, m: u32, n: u8) -> WalletConfig {
    WalletConfig { name: "Vault".into(), script_type: script, threshold: m, keystores: (1..=n).map(|s| keystore(s, script)).collect() }
}
