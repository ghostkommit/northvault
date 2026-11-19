//! SECURITY-SENSITIVE — requires human review before merge.
//!
//! Blockstream Jade over USB serial, through async-hwi. Unlocking a Jade
//! contacts Blockstream's PIN server over the network: that is how Jade's
//! PIN protection works (Sparrow does the same).

use std::str::FromStr;

use async_hwi::jade::{api, Jade, SerialTransport, Transport};
use async_hwi::HWI;
use bdk_wallet::bitcoin::bip32::DerivationPath;
use bdk_wallet::bitcoin::Psbt;
use serde::Serialize;

use super::util;
use crate::models::*;
use crate::store::WalletRecord;
use crate::wallet::descriptor::{parse_path, parse_xpub};

fn err(e: impl std::fmt::Debug) -> WalletError {
    WalletError::device(format!("Jade: {e:?}"))
}

fn jade_network(network: Network) -> &'static str {
    match network {
        Network::Bitcoin => "mainnet",
        Network::Regtest => "localtest",
        _ => "testnet",
    }
}

/// A Jade handle plus a second transport on the same serial stream, for RPCs
/// async-hwi doesn't expose (single-sig address display).
struct Session {
    jade: Jade<SerialTransport>,
    raw: SerialTransport,
}

async fn connect(port: &str, network: Network, unlock: bool) -> Result<Session, WalletError> {
    let transport = SerialTransport::new(port.to_string()).map_err(err)?;
    let raw = SerialTransport { stream: transport.stream.clone() };
    let jade = Jade::new(transport).with_network(network.into());
    if unlock {
        // Prompts for the PIN on the device, then talks to the PIN server.
        jade.auth().await.map_err(err)?;
    }
    Ok(Session { jade, raw })
}

pub async fn list(network: Network) -> Vec<HardwareDevice> {
    let Ok(ports) = SerialTransport::enumerate_potential_ports() else { return Vec::new() };
    let mut out = Vec::new();
    for port in ports {
        let Ok(session) = connect(&port, network, false).await else { continue };
        let Ok(info) = session.jade.get_info().await else { continue };
        let fingerprint = if info.jade_state == api::JadeState::Ready { session.jade.get_master_fingerprint().await.ok().map(|f| f.to_string()) } else { None };
        out.push(HardwareDevice { id: format!("jade:{port}"), kind: DeviceKind::Jade, model: "Jade".into(), fingerprint });
    }
    out
}

pub async fn keystore(port: &str, path: &str, network: Network) -> Result<Keystore, WalletError> {
    let session = connect(port, network, true).await?;
    let fingerprint = session.jade.get_master_fingerprint().await.map_err(err)?.to_string();
    let path_parsed = DerivationPath::from_str(path).map_err(err)?;
    let xpub = session.jade.get_extended_pubkey(&path_parsed).await.map_err(err)?;
    let xpub = parse_xpub(&xpub.to_string(), network)?;
    Ok(Keystore { label: "Jade".into(), fingerprint, derivation_path: path.into(), xpub: xpub.to_string(), device: Some(DeviceKind::Jade) })
}

#[derive(Serialize)]
struct SingleAddressParams<'a> {
    network: &'a str,
    path: Vec<u32>,
    /// Jade RPC script variant.
    variant: &'a str,
}

fn policy(record: &WalletRecord) -> String {
    record.descriptor.split('#').next().unwrap_or_default().to_string()
}

pub async fn display_address(port: &str, record: &WalletRecord, network: Network, chain: Chain, index: u32) -> Result<String, WalletError> {
    let session = connect(port, network, true).await?;
    let net = jade_network(network);
    if !record.script_type.is_multisig() {
        let variant = match record.script_type {
            ScriptType::P2pkh => "pkh(k)",
            ScriptType::P2shP2wpkh => "sh(wpkh(k))",
            ScriptType::P2wpkh => "wpkh(k)",
            ScriptType::P2tr => "tr(k)",
            _ => unreachable!("multisig handled below"),
        };
        let path = parse_path(&format!("{}/{}/{index}", record.keystores[0].derivation_path, util::chain_index(chain)))?;
        let params = SingleAddressParams { network: net, path: path.to_u32_vec(), variant };
        let response: api::Response<String> = session.raw.request("get_receive_address", Some(params)).await.map_err(err)?;
        return response.into_result().map_err(err);
    }
    let name = util::short_name(record);
    if !session.jade.is_wallet_registered(&name, &policy(record)).await.map_err(err)? {
        return Err(WalletError::device("register this wallet on the Jade first"));
    }
    let params = api::DescriptorAddressParams { network: net, branch: util::chain_index(chain), pointer: index, descriptor_name: &name };
    let response: api::Response<String> = session.raw.request("get_receive_address", Some(params)).await.map_err(err)?;
    response.into_result().map_err(err)
}

pub async fn register(port: &str, record: &WalletRecord, network: Network) -> Result<(), WalletError> {
    let session = connect(port, network, true).await?;
    let name = util::short_name(record);
    if session.jade.is_wallet_registered(&name, &policy(record)).await.map_err(err)? {
        return Ok(());
    }
    session.jade.register_wallet(&name, &policy(record)).await.map_err(err).map(|_| ())
}

pub async fn sign(port: &str, record: &WalletRecord, network: Network, mut psbt: Psbt) -> Result<Psbt, WalletError> {
    let session = connect(port, network, true).await?;
    if record.script_type.is_multisig() && !session.jade.is_wallet_registered(&util::short_name(record), &policy(record)).await.map_err(err)? {
        return Err(WalletError::device("register this wallet on the Jade first"));
    }
    session.jade.sign_tx(&mut psbt).await.map_err(err)?;
    Ok(psbt)
}
