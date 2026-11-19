//! SECURITY-SENSITIVE — requires human review before merge (fee estimates, broadcast).
//!
//! Electrum server access: wallet sync, fee estimates and broadcast.
//! The server is chosen by the user in Settings; there is no built-in default.

use bdk_electrum::electrum_client::{self, ElectrumApi};
use bdk_electrum::BdkElectrumClient;
use bdk_wallet::bitcoin::{Transaction, Txid};
use bdk_wallet::{
    chain::spk_client::{FullScanRequest, FullScanResponse, SyncRequest, SyncResponse},
    KeychainKind,
};

use crate::models::*;

pub type Client = BdkElectrumClient<electrum_client::Client>;

/// The conventional BIP44 gap limit.
pub const STOP_GAP: usize = 20;
pub const BATCH_SIZE: usize = 10;

pub type ScanRequest = (String, FullScanRequest<KeychainKind>, SyncRequest<(KeychainKind, u32)>);
pub type ScanUpdate = (String, FullScanResponse<KeychainKind>, SyncResponse);
pub struct Discovery {
    pub updates: Vec<ScanUpdate>,
    pub fees: Result<Vec<FeeEstimate>, WalletError>,
}

pub fn discover(client: &BdkElectrumClient<impl ElectrumApi>, requests: Vec<ScanRequest>) -> Result<Discovery, WalletError> {
    let mut updates = Vec::new();
    for (id, full, revealed) in requests {
        let full = client.full_scan(full, STOP_GAP, BATCH_SIZE, true).map_err(WalletError::server)?;
        let revealed = client.sync(revealed, BATCH_SIZE, true).map_err(WalletError::server)?;
        updates.push((id, full, revealed));
    }
    // Fee RPCs are optional on some servers. Keep successfully downloaded history.
    Ok(Discovery { updates, fees: fee_estimates(client) })
}

/// `ssl://host:50002` or `tcp://host:50001`.
pub fn connect(url: &str) -> Result<Client, WalletError> {
    let url = url.trim();
    if !(url.starts_with("ssl://") || url.starts_with("tcp://")) {
        return Err(WalletError::server("server address must start with ssl:// or tcp://"));
    }
    let config = electrum_client::ConfigBuilder::new().timeout(Some(std::time::Duration::from_secs(20))).retry(1).build();
    let client = electrum_client::Client::from_config(url, config).map_err(WalletError::server)?;
    Ok(BdkElectrumClient::new(client))
}

pub fn fee_estimates(client: &BdkElectrumClient<impl ElectrumApi>) -> Result<Vec<FeeEstimate>, WalletError> {
    let floor = client.inner.relay_fee().map(btc_per_kvb_to_sat_per_vb).unwrap_or(1.0).max(1.0);
    [(FeeLevel::Priority, 1u32), (FeeLevel::Standard, 6), (FeeLevel::Economy, 144)]
        .into_iter()
        .map(|(level, blocks)| {
            let btc_kvb = client.inner.estimate_fee(blocks as usize, None).map_err(WalletError::server)?;
            // -1 means "no estimate"; fall back to the relay floor.
            let rate = if btc_kvb > 0.0 { btc_per_kvb_to_sat_per_vb(btc_kvb).max(floor) } else { floor };
            Ok(FeeEstimate { level, sat_per_vb: (rate * 10.0).round() / 10.0, target_blocks: blocks })
        })
        .collect()
}

pub fn broadcast(client: &Client, tx: &Transaction) -> Result<Txid, WalletError> {
    client.transaction_broadcast(tx).map_err(WalletError::server)
}

fn btc_per_kvb_to_sat_per_vb(v: f64) -> f64 {
    v * 100_000.0
}
