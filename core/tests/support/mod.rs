//! Synthetic Regtest signer. This module belongs only to integration-test binaries.
//! No production feature, FFI method, wallet file, or UI exposes these private keys.
use std::str::FromStr;

use bdk_wallet::bitcoin::{
    bip32::{DerivationPath, Xpriv, Xpub},
    secp256k1::Secp256k1,
    NetworkKind, Psbt,
};
use northvault_core::{Keystore, ScriptType, UrDecoder, WalletConfig, WalletService};

pub const SCRIPTS: [ScriptType; 7] =
    [ScriptType::P2pkh, ScriptType::P2shP2wpkh, ScriptType::P2wpkh, ScriptType::P2tr, ScriptType::P2sh, ScriptType::P2shP2wsh, ScriptType::P2wsh];

pub struct Signer {
    master: Xpriv,
}

impl Signer {
    pub fn new(id: u8) -> Self {
        Self::from_seed(&[id; 32])
    }

    pub fn from_seed(seed: &[u8]) -> Self {
        Self { master: Xpriv::new_master(NetworkKind::Test, seed).unwrap() }
    }

    pub fn keystore(&self, script: ScriptType) -> Keystore {
        self.keystore_at(match script {
            ScriptType::P2pkh => "m/44'/1'/0'",
            ScriptType::P2shP2wpkh => "m/49'/1'/0'",
            ScriptType::P2wpkh => "m/84'/1'/0'",
            ScriptType::P2tr => "m/86'/1'/0'",
            ScriptType::P2sh => "m/45'",
            ScriptType::P2shP2wsh => "m/48'/1'/0'/1'",
            ScriptType::P2wsh => "m/48'/1'/0'/2'",
        })
    }

    pub fn keystore_at(&self, path: &str) -> Keystore {
        let secp = Secp256k1::new();
        let child = self.master.derive_priv(&secp, &DerivationPath::from_str(path).unwrap()).unwrap();
        Keystore {
            label: "Synthetic air-gapped signer".into(),
            fingerprint: self.master.fingerprint(&secp).to_string(),
            derivation_path: path.into(),
            xpub: Xpub::from_priv(&secp, &child).to_string(),
            device: None,
        }
    }

    pub fn sign(&self, bytes: &[u8]) -> Vec<u8> {
        let mut psbt = Psbt::deserialize(bytes).unwrap();
        let secp = Secp256k1::new();
        // Use the same BIP32 lookup contract as an external air-gapped signer.
        assert!(psbt.sign(&self.master, &secp).is_ok(), "synthetic signer failed");
        psbt.serialize()
    }
}

pub fn config(script: ScriptType) -> WalletConfig {
    WalletConfig {
        name: format!("Regtest {script:?}"),
        script_type: script,
        threshold: if script.is_multisig() { 2 } else { 1 },
        keystores: (1..=if script.is_multisig() { 3 } else { 1 }).map(|id| Signer::new(id).keystore(script)).collect(),
    }
}

/// Exercise the real animated air-gap protocol in both directions. Repeat and
/// reorder frames as a camera can; this does not emulate physical camera optics.
pub fn qr_roundtrip(service: &WalletService, psbt: String) -> String {
    let frames = service.psbt_to_ur_parts(psbt.clone()).unwrap();
    let decoder = UrDecoder::new();
    for frame in frames.iter().rev() {
        decoder.receive(frame.clone()).unwrap();
        decoder.receive(frame.clone()).unwrap();
    }
    let decoded = decoder.result().unwrap().expect("complete QR sequence");
    assert_eq!(service.psbt_to_file(decoded.clone()).unwrap(), service.psbt_to_file(psbt).unwrap());
    decoded
}
