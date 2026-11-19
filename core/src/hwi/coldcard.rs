//! SECURITY-SENSITIVE — requires human review before merge.
//!
//! Coldcard over USB (HID). Uses the `coldcard` crate directly: async-hwi's
//! wrapper only covers Coldcard's miniscript wallets, not classic multisig.

use std::str::FromStr;
use std::time::{Duration, Instant};

use async_hwi::coldcard::api as cc;
use bdk_wallet::bitcoin::bip32::Xpub;
use bdk_wallet::bitcoin::Psbt;

use super::util;
use crate::interop::coldcard::export_multisig;
use crate::models::*;
use crate::store::WalletRecord;
use crate::wallet::descriptor::parse_xpub;

/// How long to wait for the user to approve on the device.
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(600);

fn err(e: impl std::fmt::Display) -> WalletError {
    WalletError::device(format!("Coldcard: {e}"))
}

fn open(serial: &str) -> Result<cc::Coldcard, WalletError> {
    let api = cc::Api::new().map_err(err)?;
    let (device, _) = api.open(serial, None).map_err(|e| match e {
        cc::Error::NoSecretOnDevice => err("no seed on this Coldcard yet"),
        other => err(other),
    })?;
    Ok(device)
}

fn master_fingerprint(device: &mut cc::Coldcard) -> Result<String, WalletError> {
    let xpub = device.xpub(None).map_err(err)?;
    Ok(Xpub::from_str(&xpub).map_err(err)?.fingerprint().to_string())
}

pub fn list() -> Vec<HardwareDevice> {
    let Ok(mut api) = cc::Api::new() else { return Vec::new() };
    let Ok(serials) = api.detect() else { return Vec::new() };
    serials
        .into_iter()
        .map(|sn| {
            let serial = sn.as_ref().to_string();
            let fingerprint = open(&serial).and_then(|mut d| master_fingerprint(&mut d)).ok();
            HardwareDevice { id: format!("coldcard:{serial}"), kind: DeviceKind::Coldcard, model: "Coldcard".into(), fingerprint }
        })
        .collect()
}

pub fn keystore(serial: &str, path: &str, network: Network) -> Result<Keystore, WalletError> {
    let mut device = open(serial)?;
    let fingerprint = master_fingerprint(&mut device)?;
    let raw = device.xpub(Some(cc::protocol::DerivationPath::new(path).map_err(|e| err(format!("{e:?}")))?)).map_err(err)?;
    let xpub = parse_xpub(&raw, network).map_err(|e| match e {
        WalletError::WrongNetwork => err("the Coldcard is set to a different network (Advanced → Danger Zone → Testnet Mode)"),
        other => other,
    })?;
    Ok(Keystore { label: "Coldcard".into(), fingerprint, derivation_path: path.into(), xpub: xpub.to_string(), device: Some(DeviceKind::Coldcard) })
}

fn address_format(script: ScriptType) -> Result<cc::protocol::AddressFormat, WalletError> {
    use cc::protocol::AddressFormat as F;
    Ok(match script {
        ScriptType::P2pkh => F::P2PKH,
        ScriptType::P2shP2wpkh => F::P2WPKH_P2SH,
        ScriptType::P2wpkh => F::P2WPKH,
        ScriptType::P2sh => F::P2SH,
        ScriptType::P2shP2wsh => F::P2WSH_P2SH,
        ScriptType::P2wsh => F::P2WSH,
        // The coldcard crate has no taproot address format for USB display.
        ScriptType::P2tr => {
            return Err(WalletError::NotSupported {
                message: "Coldcard USB address display for taproot isn't available. Check it on the device under Address Explorer".into(),
            })
        }
    })
}

pub fn display_address(serial: &str, record: &WalletRecord, network: Network, chain: Chain, index: u32) -> Result<String, WalletError> {
    let fmt = address_format(record.script_type)?;
    let mut device = open(serial)?;
    if !record.script_type.is_multisig() {
        let path = format!("{}/{}/{index}", record.keystores[0].derivation_path, util::chain_index(chain));
        let path = cc::protocol::DerivationPath::new(&path).map_err(|e| err(format!("{e:?}")))?;
        return device.address(path, fmt).map_err(err);
    }
    let xfp_paths = util::keys_at(record, network, chain, index)?
        .into_iter()
        .map(|k| {
            let path = cc::protocol::DerivationPath::new(&crate::wallet::descriptor::fmt_path(&k.path)).map_err(|e| err(format!("{e:?}")))?;
            // Coldcard wants the fingerprint as a little-endian u32.
            Ok(cc::protocol::XfpPath { fingerprint: u32::from_le_bytes(k.fingerprint.to_bytes()), path })
        })
        .collect::<Result<Vec<_>, WalletError>>()?;
    let script = util::multisig_script(record, chain, index)?;
    let script = cc::protocol::RedeemScript::new(script.as_bytes()).map_err(|e| err(format!("{e:?}")))?;
    device.show_p2sh_address(record.threshold as u8, xfp_paths, script, fmt).map_err(err)
}

/// Uploads the multisig setup file; the user approves it on the Coldcard.
pub fn register(serial: &str, record: &WalletRecord, network: Network) -> Result<(), WalletError> {
    let mut device = open(serial)?;
    let file = export_multisig(&record.config(), network)?;
    let sha = device.upload(file.as_bytes(), |_, _| {}).map_err(err)?;
    device.multisig_enroll(file.len() as u32, sha).map_err(err)
}

pub fn sign(serial: &str, psbt: Psbt) -> Result<Psbt, WalletError> {
    let mut device = open(serial)?;
    device.sign_psbt(&psbt.serialize(), cc::SignMode::Signed).map_err(err)?;
    let started = Instant::now();
    loop {
        match device.get_signed_tx() {
            Ok(Some(bytes)) => return Psbt::deserialize(&bytes).map_err(err),
            Ok(None) if started.elapsed() < APPROVAL_TIMEOUT => std::thread::sleep(Duration::from_millis(300)),
            Ok(None) => return Err(err("timed out waiting for approval")),
            Err(cc::Error::UnexpectedResponse(cc::protocol::Response::Refused)) => return Err(err("signing was declined on the device")),
            Err(e) => return Err(err(e)),
        }
    }
}
