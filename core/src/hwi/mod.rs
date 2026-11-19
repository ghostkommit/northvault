//! SECURITY-SENSITIVE — requires human review before merge.
//!
//! USB hardware wallets: Coldcard, Jade and Trezor. The app only ever asks a
//! device for public keys, to show an address, to register a multisig wallet
//! or to sign a PSBT the user reviews on the device screen.

use bdk_wallet::bitcoin::Psbt;

use crate::models::*;
use crate::store::WalletRecord;

#[cfg(feature = "hardware")]
mod coldcard;
#[cfg(feature = "hardware")]
mod jade;
#[cfg(feature = "hardware")]
mod trezor;
#[cfg(feature = "hardware")]
mod util;
#[cfg(feature = "hardware")]
mod worker;

#[cfg(not(feature = "hardware"))]
fn unavailable() -> WalletError {
    WalletError::NotSupported { message: "built without USB hardware wallet support".into() }
}

fn split_id(device_id: &str) -> Result<(&str, &str), WalletError> {
    device_id.split_once(':').ok_or_else(|| WalletError::device("unknown device"))
}

pub async fn list(network: Network) -> Result<Vec<HardwareDevice>, WalletError> {
    #[cfg(feature = "hardware")]
    {
        let mut out = Vec::new();
        out.extend(worker::run(coldcard::list).await?);
        out.extend(jade::list(network).await);
        out.extend(worker::run(move || trezor::list(network)).await?);
        Ok(out)
    }
    #[cfg(not(feature = "hardware"))]
    {
        let _ = network;
        Ok(Vec::new())
    }
}

pub async fn keystore(device_id: &str, path: &str, network: Network) -> Result<Keystore, WalletError> {
    let (kind, handle) = split_id(device_id)?;
    #[cfg(feature = "hardware")]
    {
        let (handle, path) = (handle.to_string(), path.to_string());
        match kind {
            "coldcard" => worker::run(move || coldcard::keystore(&handle, &path, network)).await?,
            "jade" => jade::keystore(&handle, &path, network).await,
            "trezor" => worker::run(move || trezor::keystore(&handle, &path, network)).await?,
            _ => Err(WalletError::device("unknown device")),
        }
    }
    #[cfg(not(feature = "hardware"))]
    {
        let _ = (kind, handle, path, network);
        Err(unavailable())
    }
}

/// Returns the address the device derived and displayed.
pub async fn display_address(device_id: &str, record: &WalletRecord, network: Network, chain: Chain, index: u32) -> Result<String, WalletError> {
    let (kind, handle) = split_id(device_id)?;
    #[cfg(feature = "hardware")]
    {
        let (handle, record) = (handle.to_string(), record.clone());
        match kind {
            "coldcard" => worker::run(move || coldcard::display_address(&handle, &record, network, chain, index)).await?,
            "jade" => jade::display_address(&handle, &record, network, chain, index).await,
            "trezor" => worker::run(move || trezor::display_address(&handle, &record, network, chain, index)).await?,
            _ => Err(WalletError::device("unknown device")),
        }
    }
    #[cfg(not(feature = "hardware"))]
    {
        let _ = (kind, handle, record, network, chain, index);
        Err(unavailable())
    }
}

pub async fn register(device_id: &str, record: &WalletRecord, network: Network) -> Result<(), WalletError> {
    let (kind, handle) = split_id(device_id)?;
    if !record.script_type.is_multisig() {
        return Ok(());
    }
    #[cfg(feature = "hardware")]
    {
        let (handle, record) = (handle.to_string(), record.clone());
        match kind {
            "coldcard" => worker::run(move || coldcard::register(&handle, &record, network)).await?,
            "jade" => jade::register(&handle, &record, network).await,
            "trezor" => Ok(()), // Trezor is stateless: the multisig is sent with every request.
            _ => Err(WalletError::device("unknown device")),
        }
    }
    #[cfg(not(feature = "hardware"))]
    {
        let _ = (kind, handle, network);
        Err(unavailable())
    }
}

pub async fn sign(device_id: &str, record: &WalletRecord, network: Network, psbt: Psbt) -> Result<Psbt, WalletError> {
    let (kind, handle) = split_id(device_id)?;
    #[cfg(feature = "hardware")]
    {
        let (handle, record) = (handle.to_string(), record.clone());
        match kind {
            "coldcard" => worker::run(move || coldcard::sign(&handle, psbt)).await?,
            "jade" => jade::sign(&handle, &record, network, psbt).await,
            "trezor" => worker::run(move || trezor::sign(&handle, &record, network, psbt)).await?,
            _ => Err(WalletError::device("unknown device")),
        }
    }
    #[cfg(not(feature = "hardware"))]
    {
        let _ = (kind, handle, record, network, psbt);
        Err(unavailable())
    }
}
