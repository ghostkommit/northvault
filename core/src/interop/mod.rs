//! SECURITY-SENSITIVE — requires human review before merge (wallet and key import).

pub mod bsms;
pub mod coldcard;
pub mod descriptor_file;
pub mod labels;
pub mod psbt_io;
pub mod ur;

use bdk_wallet::miniscript::descriptor::checksum::desc_checksum;

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
        descriptor_file::import(text, name, network)
    }
}

/// Jade and Keystone export a single-sig key as a descriptor, e.g. `wpkh([fp/path]xpub/0/*)#checksum`.
/// Returns the text from the key expression on; a bare key expression passes through.
fn descriptor_key(text: &str, script: ScriptType) -> Result<&str, WalletError> {
    if !text.contains('(') {
        return Ok(text);
    }
    if let Some((body, checksum)) = text.split_once('#') {
        if desc_checksum(body).ok().as_deref() != Some(checksum.trim()) {
            return Err(WalletError::interop("the descriptor checksum doesn't match"));
        }
    }
    // The device chose the script when it exported; a different one here would derive other addresses.
    text.strip_prefix(descriptor::wrapper(script).0)
        .filter(|rest| rest.starts_with('['))
        .ok_or_else(|| WalletError::interop("this export is for a different script type"))
}

/// Reads one keystore: Coldcard, Cobo Vault or Keystone JSON export, a Jade or
/// Keystone single-sig descriptor, or a key expression `[fingerprint/path]xpub`
/// as shown by Specter DIY and most devices.
pub fn import_keystore(contents: &[u8], script: ScriptType, network: Network) -> Result<Keystore, WalletError> {
    let text = std::str::from_utf8(contents).map_err(|_| WalletError::interop("not a text file"))?.trim();
    if text.contains("prv") {
        return Err(WalletError::PrivateKeyNotAllowed);
    }
    if text.starts_with('{') {
        return coldcard::import_keystore(text, script, network);
    }
    let rest = descriptor_key(text, script)?.strip_prefix('[').ok_or_else(|| WalletError::interop("expected [fingerprint/path]xpub"))?;
    let (origin, key) = rest.split_once(']').ok_or_else(|| WalletError::interop("expected [fingerprint/path]xpub"))?;
    let (fp, path) = origin.split_once('/').unwrap_or((origin, ""));
    let key = key.split(['/', ')']).next().unwrap_or_default();
    let keystore = Keystore {
        label: "Keystore".into(),
        fingerprint: parse_fingerprint(fp)?.to_string(),
        derivation_path: fmt_path(&parse_path(path)?),
        xpub: parse_xpub(key, network)?.to_string(),
        device: None,
    };
    checked(keystore, script, network)
}

/// Same depth check as wallet creation, so mistakes show up right away.
pub(crate) fn checked(keystore: Keystore, script: ScriptType, network: Network) -> Result<Keystore, WalletError> {
    let probe = WalletConfig {
        name: "probe".into(),
        script_type: if script.is_multisig() { script } else { ScriptType::P2wpkh },
        threshold: 1,
        keystores: vec![keystore.clone()],
    };
    descriptor::validate(&probe, network)?;
    Ok(keystore)
}
