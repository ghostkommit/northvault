//! SECURITY-SENSITIVE — requires human review before merge (wallet and key import).

pub mod bsms;
pub mod coldcard;
pub mod labels;
pub mod psbt_io;
pub mod sparrow;
pub mod ur;

use crate::models::*;
use crate::wallet::descriptor::{self, fmt_path, parse_fingerprint, parse_path, parse_xpub};

/// Detects the format of a wallet file: BSMS, multisig setup file, or descriptor text.
pub fn import_wallet(contents: &[u8], filename: &str, network: Network) -> Result<WalletConfig, WalletError> {
    let text = std::str::from_utf8(contents).map_err(|_| WalletError::interop("not a text file"))?;
    let name = filename.rsplit('/').next().unwrap_or(filename).split('.').next().unwrap_or("Imported wallet");
    if bsms::looks_like_bsms(text) {
        bsms::import(text, name, network)
    } else if coldcard::looks_like_multisig_file(text) {
        coldcard::import_multisig(text, network)
    } else {
        sparrow::import(text, name, network)
    }
}

/// Reads one keystore: Coldcard/Sparrow JSON export, or a key expression
/// `[fingerprint/path]xpub` as shown by Sparrow and most devices.
pub fn import_keystore(contents: &[u8], script: ScriptType, network: Network) -> Result<Keystore, WalletError> {
    let text = std::str::from_utf8(contents).map_err(|_| WalletError::interop("not a text file"))?.trim();
    if text.contains("prv") {
        return Err(WalletError::PrivateKeyNotAllowed);
    }
    if text.starts_with('{') {
        return coldcard::import_keystore(text, script, network);
    }
    let rest = text.strip_prefix('[').ok_or_else(|| WalletError::interop("expected [fingerprint/path]xpub"))?;
    let (origin, key) = rest.split_once(']').ok_or_else(|| WalletError::interop("expected [fingerprint/path]xpub"))?;
    let (fp, path) = origin.split_once('/').unwrap_or((origin, ""));
    let key = key.split('/').next().unwrap_or_default();
    let keystore = Keystore {
        label: "Keystore".into(),
        fingerprint: parse_fingerprint(fp)?.to_string(),
        derivation_path: fmt_path(&parse_path(path)?),
        xpub: parse_xpub(key, network)?.to_string(),
        device: None,
    };
    // Same depth check as wallet creation, so mistakes show up right away.
    let probe = WalletConfig {
        name: "probe".into(),
        script_type: if script.is_multisig() { script } else { ScriptType::P2wpkh },
        threshold: 1,
        keystores: vec![keystore.clone()],
    };
    descriptor::validate(&probe, network)?;
    Ok(keystore)
}
