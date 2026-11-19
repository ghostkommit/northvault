//! A real watch-only wallet: BDK + SQLite per account, mapped to the same
//! types the sample backend returns.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use bdk_wallet::bitcoin::{Address, ScriptBuf};
use bdk_wallet::chain::{ChainPosition, ConfirmationBlockTime};
use bdk_wallet::rusqlite::Connection;
use bdk_wallet::{KeychainKind, PersistedWallet, Wallet};

use crate::interop::labels::{LabelType, Labels};
use crate::models::*;
use crate::store::{Store, WalletRecord};
use crate::wallet::descriptor;

/// Addresses shown past the last used one (the gap limit).
const ADDRESS_GAP: u32 = 20;
const DAY_SECS: i64 = 86_400;

pub struct LiveAccount {
    pub record: WalletRecord,
    pub wallet: PersistedWallet<Connection>,
    conn: Connection,
    pub labels: Labels,
    pub network: Network,
}

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub fn keychain(chain: Chain) -> KeychainKind {
    match chain {
        Chain::Receive => KeychainKind::External,
        Chain::Change => KeychainKind::Internal,
    }
}

impl LiveAccount {
    /// Opens the account's database, creating it on first use.
    pub fn open(store: &Store, record: WalletRecord, network: Network) -> Result<Self, WalletError> {
        let (receive, change) = descriptor::split(&record.descriptor)?;
        let (receive, change) = (receive.to_string(), change.to_string());
        let mut conn = Connection::open(store.db_path(&record.id)).map_err(WalletError::backend)?;
        let loaded = Wallet::load()
            .descriptor(KeychainKind::External, Some(receive.clone()))
            .descriptor(KeychainKind::Internal, Some(change.clone()))
            .check_network(network.into())
            .load_wallet(&mut conn)
            .map_err(WalletError::backend)?;
        let wallet = match loaded {
            Some(w) => w,
            None => Wallet::create(receive, change).network(network.into()).lookahead(ADDRESS_GAP).create_wallet(&mut conn).map_err(WalletError::backend)?,
        };
        let labels = store.load_labels(&record.id);
        Ok(Self { record, wallet, conn, labels, network })
    }

    pub fn persist(&mut self) -> Result<(), WalletError> {
        self.wallet.persist(&mut self.conn).map(|_| ()).map_err(WalletError::backend)
    }

    pub fn id(&self) -> &str {
        &self.record.id
    }

    pub fn account(&self) -> Account {
        let r = &self.record;
        let paths: Vec<&str> = r.keystores.iter().map(|k| k.derivation_path.as_str()).collect();
        let derivation_path = if paths.windows(2).all(|w| w[0] == w[1]) { paths[0].to_string() } else { "Mixed".into() };
        Account {
            id: r.id.clone(),
            name: r.name.clone(),
            policy: descriptor::policy_label(r.script_type, r.threshold, r.keystores.len()),
            script_type: r.script_type,
            standard: descriptor::standard(r.script_type).into(),
            derivation_path,
            is_multisig: r.script_type.is_multisig(),
            balance_sats: self.wallet.balance().total().to_sat(),
        }
    }

    pub fn details(&self) -> Result<WalletDetails, WalletError> {
        let (receive, _) = descriptor::split(&self.record.descriptor)?;
        Ok(WalletDetails {
            account: self.account(),
            threshold: self.record.threshold,
            keystores: self.record.keystores.clone(),
            descriptor: self.record.descriptor.clone(),
            first_receive_address: descriptor::address_at(&receive, 0, self.network)?.to_string(),
        })
    }

    pub fn tip_height(&self) -> u32 {
        self.wallet.latest_checkpoint().height()
    }

    fn position_time(pos: &ChainPosition<ConfirmationBlockTime>) -> i64 {
        match pos {
            ChainPosition::Confirmed { anchor, .. } => anchor.confirmation_time as i64,
            ChainPosition::Unconfirmed { first_seen, last_seen } => first_seen.or(*last_seen).map(|t| t as i64).unwrap_or_else(now),
        }
    }

    fn confirmations(&self, pos: &ChainPosition<ConfirmationBlockTime>) -> u32 {
        match pos {
            ChainPosition::Confirmed { anchor, .. } => self.tip_height().saturating_sub(anchor.block_id.height) + 1,
            ChainPosition::Unconfirmed { .. } => 0,
        }
    }

    pub fn address_string(&self, script: &ScriptBuf) -> String {
        Address::from_script(script, bdk_wallet::bitcoin::Network::from(self.network)).map(|a| a.to_string()).unwrap_or_default()
    }

    /// Newest first.
    pub fn transactions(&self) -> Vec<WalletTransaction> {
        let mut rows: Vec<(i64, u32, String, i64)> = self
            .wallet
            .transactions()
            .map(|t| {
                let (sent, received) = self.wallet.sent_and_received(&t.tx_node.tx);
                let net = received.to_sat() as i64 - sent.to_sat() as i64;
                (Self::position_time(&t.chain_position), self.confirmations(&t.chain_position), t.tx_node.txid.to_string(), net)
            })
            .collect();
        // Oldest first for the running balance; unconfirmed go last.
        rows.sort_by_key(|(ts, confs, txid, _)| (*confs == 0, *ts, txid.clone()));
        let mut balance: i64 = 0;
        let mut out: Vec<WalletTransaction> = rows
            .into_iter()
            .map(|(timestamp, confirmations, txid, amount)| {
                balance += amount;
                WalletTransaction {
                    label: self.labels.get(LabelType::Tx, &txid),
                    txid,
                    account_id: self.record.id.clone(),
                    timestamp,
                    amount_sats: amount,
                    balance_after_sats: balance.max(0) as u64,
                    confirmations,
                }
            })
            .collect();
        out.reverse();
        out
    }

    pub fn utxos(&self) -> Vec<Utxo> {
        self.wallet
            .list_unspent()
            .map(|u| {
                let txid = u.outpoint.txid.to_string();
                let address = self.address_string(&u.txout.script_pubkey);
                // Label inheritance: output, then address, then transaction.
                let label = self
                    .labels
                    .get(LabelType::Output, &format!("{txid}:{}", u.outpoint.vout))
                    .or_else(|| self.labels.get(LabelType::Addr, &address))
                    .or_else(|| self.labels.get(LabelType::Tx, &txid));
                Utxo {
                    vout: u.outpoint.vout,
                    account_id: self.record.id.clone(),
                    value_sats: u.txout.value.to_sat(),
                    timestamp: Self::position_time(&u.chain_position),
                    label,
                    address,
                    txid,
                }
            })
            .collect()
    }

    /// (tx count, unspent balance) per derivation index.
    fn usage(&self, keychain: KeychainKind) -> HashMap<u32, (u32, u64)> {
        let mut map: HashMap<u32, (u32, u64)> = HashMap::new();
        for o in self.wallet.list_output().filter(|o| o.keychain == keychain) {
            let entry = map.entry(o.derivation_index).or_default();
            entry.0 += if o.is_spent { 2 } else { 1 };
            if !o.is_spent {
                entry.1 += o.txout.value.to_sat();
            }
        }
        map
    }

    fn path_for(&self, chain: Chain, index: u32) -> String {
        let c = if chain == Chain::Receive { 0 } else { 1 };
        let base = &self.record.keystores[0].derivation_path;
        if self.record.keystores.len() == 1 {
            format!("{base}/{c}/{index}")
        } else {
            format!("…/{c}/{index}")
        }
    }

    fn address_info(&self, chain: Chain, index: u32, usage: &HashMap<u32, (u32, u64)>) -> AddressInfo {
        let address = self.wallet.peek_address(keychain(chain), index).address.to_string();
        let (tx_count, balance_sats) = usage.get(&index).copied().unwrap_or_default();
        AddressInfo {
            chain,
            index,
            derivation_path: self.path_for(chain, index),
            label: self.labels.get(LabelType::Addr, &address),
            tx_count,
            balance_sats,
            address,
        }
    }

    pub fn addresses(&self, chain: Chain) -> Vec<AddressInfo> {
        let usage = self.usage(keychain(chain));
        let used = usage.keys().max().map_or(0, |m| m + 1);
        let revealed = self.wallet.derivation_index(keychain(chain)).map_or(0, |i| i + 1);
        let count = used.max(revealed.min(used + ADDRESS_GAP)) + ADDRESS_GAP;
        (0..count).map(|i| self.address_info(chain, i, &usage)).collect()
    }

    /// First never-used receive address, skipping `offset` more. Reveals it so
    /// the next sync watches it even past the gap limit.
    pub fn next_receive(&mut self, offset: u32) -> Result<AddressInfo, WalletError> {
        let usage = self.usage(KeychainKind::External);
        let first_unused = (0..).find(|i| !usage.contains_key(i)).unwrap_or(0);
        let index = first_unused + offset;
        if self.wallet.derivation_index(KeychainKind::External).is_none_or(|i| i < index) {
            let _ = self.wallet.reveal_addresses_to(KeychainKind::External, index).count();
            self.persist()?;
        }
        Ok(self.address_info(Chain::Receive, index, &usage))
    }

    /// End-of-day balances for the last `days` days, oldest first (`days + 1` entries).
    pub fn daily_balances(&self, days: usize) -> Vec<(i64, u64)> {
        let today = now() - now().rem_euclid(DAY_SECS);
        let mut txs = self.transactions();
        txs.reverse();
        (0..=days)
            .map(|d| {
                let ts = today - (days - d) as i64 * DAY_SECS + 12 * 3600;
                let end = ts + 12 * 3600;
                let bal = txs.iter().take_while(|t| t.timestamp <= end || t.confirmations == 0 && d == days).last().map_or(0, |t| t.balance_after_sats);
                (ts, bal)
            })
            .collect()
    }

    pub fn set_label(&mut self, store: &Store, kind: LabelType, reference: &str, label: &str) -> Result<(), WalletError> {
        let mut labels = self.labels.clone();
        labels.set(kind, reference, label);
        store.save_labels(&self.record.id, &labels)?;
        self.labels = labels;
        Ok(())
    }
}
