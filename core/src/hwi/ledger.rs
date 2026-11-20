//! SECURITY-SENSITIVE — requires human review before merge.
//!
//! Ledger (Bitcoin app 2.x) over USB HID, through Ledger's own client crate.
//! The app works with BIP388 wallet policies: single-sig uses the standard
//! policies, multisig must be registered once and every later request carries
//! the HMAC the device returned. The policy itself is always rebuilt from the
//! stored descriptor, so a tampered HMAC only makes the device refuse.

use std::str::FromStr;

use bdk_wallet::bitcoin::address::NetworkUnchecked;
use bdk_wallet::bitcoin::bip32::DerivationPath;
use bdk_wallet::bitcoin::{Address, Psbt};
use ledger_bitcoin_client::apdu::{APDUCommand, StatusWord};
use ledger_bitcoin_client::client::{BitcoinClient, Transport};
use ledger_bitcoin_client::error::BitcoinClientError;
use ledger_bitcoin_client::wallet::Version;
use ledger_bitcoin_client::{PartialSignature, SignPsbtYieldedObject, WalletPolicy, WalletPubKey};
use ledger_transport_hidapi::hidapi::HidApi;
use ledger_transport_hidapi::TransportNativeHID;

use super::util;
use crate::models::*;
use crate::store::{LedgerRegistration, WalletRecord};
use crate::wallet::descriptor::{self, parse_fingerprint, parse_xpub};

/// The test-only firmware emulator (Speculos) listens for APDUs here.
#[cfg(feature = "emulator")]
const EMULATOR: &str = "emulator";

/// shortcut: legacy (non-SegWit) inputs are refused. The app probes each input for a
/// witness UTXO, and ledger_bitcoin_client (0.6.2 and 0.7.0) errors on a missing map
/// key instead of answering "not found" as Ledger's Python client does. Upgrade when
/// a client release answers absent keys; the emulator test then covers P2PKH and P2SH.
fn legacy(path: &str) -> Result<(), WalletError> {
    if path.starts_with("m/44'") || path.starts_with("m/45'") {
        return Err(WalletError::NotSupported { message: "Ledger supports SegWit and Taproot wallets here, not legacy P2PKH or P2SH".into() });
    }
    Ok(())
}

fn err(e: impl std::fmt::Display) -> WalletError {
    WalletError::device(format!("Ledger: {e}"))
}

fn client_err<T: std::fmt::Debug>(e: BitcoinClientError<T>) -> WalletError {
    match e {
        BitcoinClientError::Device { status: StatusWord::Deny, .. } => err("declined on the device"),
        // 0x6E00/0x6D00/0x6511: no app, or another app, is open.
        BitcoinClientError::Device { status: StatusWord::Unknown, .. } | BitcoinClientError::Transport(_) => {
            err("open the Bitcoin app on the Ledger and try again")
        }
        other => err(format!("{other:?}")),
    }
}

/// USB, or the test-only emulator's APDU socket.
enum Link {
    Hid(TransportNativeHID),
    #[cfg(feature = "emulator")]
    Tcp(std::sync::Mutex<std::net::TcpStream>),
}

impl Transport for Link {
    type Error = String;

    fn exchange(&self, cmd: &APDUCommand) -> Result<(StatusWord, Vec<u8>), String> {
        let (status, data) = match self {
            Link::Hid(hid) => {
                let command = ledger_apdu::APDUCommand { cla: cmd.cla, ins: cmd.ins, p1: cmd.p1, p2: cmd.p2, data: cmd.data.clone() };
                let answer = hid.exchange(&command).map_err(|e| e.to_string())?;
                (answer.retcode(), answer.data().to_vec())
            }
            #[cfg(feature = "emulator")]
            Link::Tcp(stream) => speculos(&mut stream.lock().unwrap(), &cmd.encode()).map_err(|e| e.to_string())?,
        };
        Ok((StatusWord::try_from(status).unwrap_or(StatusWord::Unknown), data))
    }
}

/// Speculos frames an APDU with a 4-byte big-endian length; the reply adds a
/// 2-byte status word after the data.
#[cfg(feature = "emulator")]
fn speculos(stream: &mut std::net::TcpStream, apdu: &[u8]) -> std::io::Result<(u16, Vec<u8>)> {
    use std::io::{Read, Write};
    stream.write_all(&(apdu.len() as u32).to_be_bytes())?;
    stream.write_all(apdu)?;
    let mut len = [0u8; 4];
    stream.read_exact(&mut len)?;
    let mut reply = vec![0u8; u32::from_be_bytes(len) as usize + 2];
    stream.read_exact(&mut reply)?;
    let status = reply.split_off(reply.len() - 2);
    Ok((u16::from_be_bytes([status[0], status[1]]), reply))
}

type Client = BitcoinClient<Link>;

fn open(handle: &str) -> Result<Client, WalletError> {
    #[cfg(feature = "emulator")]
    if handle == EMULATOR {
        let stream = std::net::TcpStream::connect(("127.0.0.1", 9999)).map_err(err)?;
        return Ok(BitcoinClient::new(Link::Tcp(std::sync::Mutex::new(stream))));
    }
    let api = HidApi::new().map_err(err)?;
    let info = TransportNativeHID::list_ledgers(&api).find(|d| d.path().to_string_lossy() == handle).ok_or_else(|| err("the device was disconnected"))?;
    let transport = TransportNativeHID::open_device(&api, info).map_err(err)?;
    Ok(BitcoinClient::new(Link::Hid(transport)))
}

pub fn list() -> Vec<HardwareDevice> {
    let mut handles: Vec<String> =
        HidApi::new().map(|api| TransportNativeHID::list_ledgers(&api).map(|d| d.path().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    // One Ledger exposes several HID interfaces; each path is one device here.
    handles.dedup();
    #[cfg(feature = "emulator")]
    if std::net::TcpStream::connect(("127.0.0.1", 9999)).is_ok() {
        handles.push(EMULATOR.into());
    }
    handles
        .into_iter()
        .map(|handle| {
            // Without the Bitcoin app open there is no fingerprint yet.
            let fingerprint = open(&handle).ok().and_then(|c| c.get_master_fingerprint().ok()).map(|f| f.to_string());
            HardwareDevice { id: format!("ledger:{handle}"), kind: DeviceKind::Ledger, model: "Ledger".into(), fingerprint }
        })
        .collect()
}

pub fn keystore(handle: &str, path: &str, network: Network) -> Result<Keystore, WalletError> {
    legacy(path)?;
    let client = open(handle)?;
    let fingerprint = client.get_master_fingerprint().map_err(client_err)?.to_string();
    let parsed = DerivationPath::from_str(path).map_err(err)?;
    let xpub = client.get_extended_pubkey(&parsed, false).map_err(client_err)?;
    let xpub = parse_xpub(&xpub.to_string(), network).map_err(|e| match e {
        WalletError::WrongNetwork => err("open the Bitcoin app for this network (Bitcoin Test for test networks)"),
        other => other,
    })?;
    Ok(Keystore { label: "Ledger".into(), fingerprint, derivation_path: path.into(), xpub: xpub.to_string(), device: Some(DeviceKind::Ledger) })
}

/// The wallet as a BIP388 policy: the descriptor with each key replaced by
/// `@i/**`, keys in the stored order. Single-sig policies have no name.
fn policy(record: &WalletRecord, name: &str) -> Result<WalletPolicy, WalletError> {
    let (open, close) = descriptor::wrapper(record.script_type);
    let placeholders: Vec<String> = (0..record.keystores.len()).map(|i| format!("@{i}/**")).collect();
    let inner = if record.script_type.is_multisig() { format!("{},{}", record.threshold, placeholders.join(",")) } else { placeholders.join(",") };
    let keys = record
        .keystores
        .iter()
        .map(|k| {
            WalletPubKey::from_str(&format!("[{}/{}]{}", k.fingerprint, k.derivation_path.trim_start_matches("m/"), k.xpub)).map_err(|e| err(format!("{e:?}")))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(WalletPolicy::new(name.into(), Version::V2, format!("{open}{inner}{close}"), keys))
}

/// The policy and HMAC this device registered for a multisig wallet, or the
/// standard unnamed policy for single-sig.
fn wallet(client: &Client, record: &WalletRecord) -> Result<(WalletPolicy, Option<[u8; 32]>), WalletError> {
    if !record.script_type.is_multisig() {
        return Ok((policy(record, "")?, None));
    }
    let fingerprint = client.get_master_fingerprint().map_err(client_err)?;
    util::own_keystore(record, &fingerprint)?;
    let registration = record
        .ledger_registrations
        .iter()
        .find(|r| parse_fingerprint(&r.fingerprint).ok() == Some(fingerprint))
        .ok_or_else(|| err("register this wallet on the Ledger first"))?;
    let hmac = <[u8; 32]>::try_from(hex(&registration.hmac)?).map_err(|_| err("the stored registration is damaged; register again"))?;
    Ok((policy(record, &registration.name)?, Some(hmac)))
}

fn hex(text: &str) -> Result<Vec<u8>, WalletError> {
    use bdk_wallet::bitcoin::hex::FromHex;
    Vec::from_hex(text).map_err(|_| err("the stored registration is damaged; register again"))
}

pub fn display_address(handle: &str, record: &WalletRecord, network: Network, chain: Chain, index: u32) -> Result<String, WalletError> {
    record.keystores.iter().try_for_each(|k| legacy(&k.derivation_path))?;
    let client = open(handle)?;
    let (policy, hmac) = wallet(&client, record)?;
    let shown = client.get_wallet_address(&policy, hmac.as_ref(), chain == Chain::Change, index, true).map_err(client_err)?;
    rendered(shown, network)
}

/// The Bitcoin Test app shows testnet encodings (`tb1…`) on every test network.
/// The caller compares the result with our own address, so it is re-encoded
/// from its script for `network`, after checking it is for the right chain family.
fn rendered(shown: Address<NetworkUnchecked>, network: Network) -> Result<String, WalletError> {
    let family = if network == Network::Bitcoin { bdk_wallet::bitcoin::Network::Bitcoin } else { bdk_wallet::bitcoin::Network::Testnet };
    let checked = shown.require_network(family).map_err(|_| WalletError::WrongNetwork)?;
    Address::from_script(&checked.script_pubkey(), bdk_wallet::bitcoin::Network::from(network)).map(|a| a.to_string()).map_err(err)
}

/// Registers a multisig wallet after the user checks every key on the device.
/// Returns the registration to store with the wallet.
pub fn register(handle: &str, record: &WalletRecord) -> Result<LedgerRegistration, WalletError> {
    record.keystores.iter().try_for_each(|k| legacy(&k.derivation_path))?;
    let client = open(handle)?;
    let fingerprint = client.get_master_fingerprint().map_err(client_err)?;
    util::own_keystore(record, &fingerprint)?;
    let name = util::short_name(record);
    let (_id, hmac) = client.register_wallet(&policy(record, &name)?).map_err(client_err)?;
    Ok(LedgerRegistration { fingerprint: fingerprint.to_string(), name, hmac: hmac.iter().map(|b| format!("{b:02x}")).collect() })
}

pub fn sign(handle: &str, record: &WalletRecord, mut psbt: Psbt) -> Result<Psbt, WalletError> {
    record.keystores.iter().try_for_each(|k| legacy(&k.derivation_path))?;
    let client = open(handle)?;
    let (policy, hmac) = wallet(&client, record)?;
    for (i, signed) in client.sign_psbt(&psbt, &policy, hmac.as_ref()).map_err(client_err)? {
        let input = psbt.inputs.get_mut(i).ok_or_else(|| err("signed an input that doesn't exist"))?;
        // MuSig2 and unknown objects don't apply to these policies.
        if let SignPsbtYieldedObject::Partial(sig) = signed {
            match sig {
                PartialSignature::Sig(key, sig) => {
                    input.partial_sigs.insert(key, sig);
                }
                PartialSignature::TapScriptSig(key, Some(leaf), sig) => {
                    input.tap_script_sigs.insert((key, leaf), sig);
                }
                PartialSignature::TapScriptSig(_, None, sig) => input.tap_key_sig = Some(sig),
            }
        }
    }
    Ok(psbt)
}
