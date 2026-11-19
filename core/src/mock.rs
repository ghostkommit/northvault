//! Deterministic sample data. Replace with a real backend (see DEVELOPMENT.md).

use std::time::{SystemTime, UNIX_EPOCH};

use crate::models::*;
use crate::wallet::address::parse_recipient;

const DAYS: usize = 365;
const DAY_SECS: i64 = 86_400;
const BECH32: &[u8] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";
const HEX: &[u8] = b"0123456789abcdef";
const RECEIVE_LABELS: [&str; 6] = ["Salary", "Exchange withdrawal", "Client payment", "Recurring purchase", "Gift", "Refund"];
const SEND_LABELS: [&str; 6] = ["Transfer to savings", "Rent share", "Online order", "Restaurant", "Travel booking", "Invoice payment"];
const RECEIVE_GAP: u32 = 5;
const CHANGE_GAP: u32 = 3;

/// Sample FX rates (USD -> currency). Replace with a price feed.
pub fn fx_rate(c: FiatCurrency) -> f64 {
    match c {
        FiatCurrency::Usd => 1.0,
        FiatCurrency::Eur => 0.92,
        FiatCurrency::Gbp => 0.79,
        FiatCurrency::Chf => 0.88,
        FiatCurrency::Jpy => 151.4,
    }
}

/// Sample daily BTC/USD closes, oldest first, ending today (DAYS + 1 entries).
pub fn sample_prices() -> Vec<f64> {
    let mut r = Rng(7);
    let mut price_usd = vec![0.0; DAYS + 1];
    price_usd[DAYS] = 68_420.0;
    for i in (1..=DAYS).rev() {
        price_usd[i - 1] = price_usd[i] / (1.0 + 0.0011 + (r.next() - 0.5) * 0.05);
    }
    price_usd
}

pub fn fee_estimates() -> Vec<FeeEstimate> {
    vec![
        FeeEstimate { level: FeeLevel::Economy, sat_per_vb: 4.0, target_blocks: 144 },
        FeeEstimate { level: FeeLevel::Standard, sat_per_vb: 12.0, target_blocks: 6 },
        FeeEstimate { level: FeeLevel::Priority, sat_per_vb: 28.0, target_blocks: 1 },
    ]
}

struct Rng(u32);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x6D2B_79F5);
        let mut t = self.0;
        t = (t ^ (t >> 15)).wrapping_mul(t | 1);
        t ^= t.wrapping_add((t ^ (t >> 7)).wrapping_mul(t | 61));
        f64::from(t ^ (t >> 14)) / 4_294_967_296.0
    }
    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[(self.next() * items.len() as f64) as usize % items.len()]
    }
    fn string(&mut self, charset: &[u8], len: usize) -> String {
        (0..len).map(|_| charset[(self.next() * charset.len() as f64) as usize % charset.len()] as char).collect()
    }
}

struct Def {
    id: &'static str,
    name: &'static str,
    policy: &'static str,
    script: ScriptType,
    standard: &'static str,
    path: &'static str,
    balance_sats: u64,
    seed: u32,
    tx_count: usize,
    has_pending: bool,
}

const DEFS: [Def; 4] = [
    Def {
        id: "cold",
        name: "Cold Storage",
        policy: "Native SegWit",
        script: ScriptType::P2wpkh,
        standard: "BIP84",
        path: "m/84'/0'/0'",
        balance_sats: 184_215_730,
        seed: 11,
        tx_count: 12,
        has_pending: false,
    },
    Def {
        id: "savings",
        name: "Savings",
        policy: "Taproot",
        script: ScriptType::P2tr,
        standard: "BIP86",
        path: "m/86'/0'/0'",
        balance_sats: 62_500_000,
        seed: 23,
        tx_count: 8,
        has_pending: false,
    },
    Def {
        id: "spend",
        name: "Daily Spending",
        policy: "Native SegWit",
        script: ScriptType::P2wpkh,
        standard: "BIP84",
        path: "m/84'/0'/1'",
        balance_sats: 4_382_190,
        seed: 37,
        tx_count: 16,
        has_pending: true,
    },
    Def {
        id: "vault",
        name: "Family Vault",
        policy: "Multisig 2-of-3",
        script: ScriptType::P2wsh,
        standard: "BIP48",
        path: "m/48'/0'/0'/2'",
        balance_sats: 310_000_000,
        seed: 51,
        tx_count: 6,
        has_pending: false,
    },
];

pub struct TxData {
    pub tx: WalletTransaction,
    chain: Chain,
    index: u32,
}

pub struct AccountData {
    pub account: Account,
    pub txs: Vec<TxData>, // newest first
    pub utxos: Vec<Utxo>,
    /// Balance at the end of each day, oldest first (DAYS + 1 entries).
    hold: Vec<u64>,
    receive_used: u32,
    change_used: u32,
    seed: u32,
}

pub struct SampleData {
    pub accounts: Vec<AccountData>,
    price_usd: Vec<f64>,
    today: i64,
}

impl SampleData {
    pub fn generate() -> Self {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        let today = now - now.rem_euclid(DAY_SECS);
        let price_usd = sample_prices();
        let accounts = DEFS.iter().map(|d| AccountData::generate(d, today)).collect();
        Self { accounts, price_usd, today }
    }

    pub fn select<'a>(&'a self, id: Option<&'a str>) -> impl Iterator<Item = &'a AccountData> + 'a {
        self.accounts.iter().filter(move |a| id.is_none_or(|id| a.account.id == id))
    }

    pub fn account(&self, id: &str) -> Result<&AccountData, WalletError> {
        self.accounts.iter().find(|a| a.account.id == id).ok_or(WalletError::UnknownAccount)
    }

    pub fn latest_price(&self) -> f64 {
        self.price_usd[DAYS]
    }

    pub fn history(&self, id: Option<&str>, range: TimeRange) -> Vec<NetWorthPoint> {
        let (span, step) = match range {
            TimeRange::Week => (7, 1),
            TimeRange::Month => (30, 1),
            TimeRange::Quarter => (90, 1),
            TimeRange::Year => (365, 4),
            TimeRange::AllTime => (DAYS, 1),
        };
        let mut days: Vec<usize> = (DAYS - span..=DAYS).step_by(step).collect();
        if days.last() != Some(&DAYS) {
            days.push(DAYS);
        }
        days.into_iter()
            .map(|d| NetWorthPoint {
                timestamp: day_ts(self.today, d),
                balance_sats: self.select(id).map(|a| a.hold[d]).sum(),
                btc_price_usd: self.price_usd[d],
            })
            .collect()
    }
}

fn day_ts(today: i64, day: usize) -> i64 {
    today - (DAYS - day) as i64 * DAY_SECS + 12 * 3600
}

fn address_at(seed: u32, script: ScriptType, chain: Chain, index: u32) -> String {
    let c = if chain == Chain::Receive { 0u32 } else { 1 };
    let mut r = Rng(seed.wrapping_mul(7919).wrapping_add(c.wrapping_mul(104_729)).wrapping_add(index.wrapping_mul(31)).wrapping_add(1));
    let (prefix, len) = match script {
        ScriptType::P2tr => ("bc1p", 58),
        ScriptType::P2wsh => ("bc1q", 58),
        ScriptType::P2wpkh => ("bc1q", 38),
        ScriptType::P2pkh => ("1", 33),
        ScriptType::P2sh | ScriptType::P2shP2wsh | ScriptType::P2shP2wpkh => ("3", 33),
    };
    format!("{prefix}{}", r.string(BECH32, len))
}

impl AccountData {
    fn generate(def: &Def, today: i64) -> Self {
        let mut r = Rng(def.seed);
        let mut days: Vec<usize> = (0..def.tx_count).map(|_| 3 + (r.next() * (DAYS as f64 - 6.0)) as usize).collect();
        days.sort_unstable_by(|a, b| b.cmp(a));
        if def.has_pending {
            days[0] = DAYS;
        }
        let total = def.balance_sats as f64;
        let mut after = def.balance_sats as i64;
        let mut raw = Vec::with_capacity(days.len());
        for (j, &day) in days.iter().enumerate() {
            let oldest = j == days.len() - 1;
            let received = oldest || r.next() < 0.58;
            let amount: i64 = if oldest {
                after
            } else if received {
                (after as f64 * 0.7).min(total * (0.06 + r.next() * 0.3)) as i64
            } else {
                -((total * (0.02 + r.next() * 0.12)) as i64)
            };
            let confirmations = if def.has_pending && day == DAYS { 0 } else { ((DAYS - day) * 144 + 1 + (r.next() * 120.0) as usize) as u32 };
            let label = r.pick(if received { &RECEIVE_LABELS } else { &SEND_LABELS }).to_string();
            raw.push((day, amount, after as u64, confirmations, label, r.string(HEX, 64)));
            after -= amount;
        }

        // Assign derivation indices oldest-first.
        let (mut rc, mut cc) = (0u32, 0u32);
        let mut txs: Vec<TxData> = Vec::with_capacity(raw.len());
        for (day, amount, balance_after, confirmations, label, txid) in raw.into_iter().rev() {
            let (chain, index) = if amount > 0 {
                rc += 1;
                (Chain::Receive, rc - 1)
            } else {
                cc += 1;
                (Chain::Change, cc - 1)
            };
            txs.push(TxData {
                tx: WalletTransaction {
                    txid,
                    account_id: def.id.into(),
                    timestamp: day_ts(today, day),
                    label: Some(label),
                    amount_sats: amount,
                    balance_after_sats: balance_after,
                    confirmations,
                },
                chain,
                index,
            });
        }

        let mut hold = Vec::with_capacity(DAYS + 1);
        let (mut p, mut bal) = (0usize, 0u64);
        for d in 0..=DAYS {
            let ts = day_ts(today, d);
            while p < txs.len() && txs[p].tx.timestamp <= ts {
                bal = txs[p].tx.balance_after_sats;
                p += 1;
            }
            hold.push(bal);
        }
        txs.reverse(); // newest first

        // Current coins: the five most recent receives share the balance.
        let receives: Vec<&TxData> = txs.iter().filter(|t| t.tx.amount_sats > 0).take(5).collect();
        let weight: i64 = receives.iter().map(|t| t.tx.amount_sats).sum();
        let mut assigned = 0u64;
        let utxos = receives
            .iter()
            .enumerate()
            .map(|(i, t)| {
                let value = if i == receives.len() - 1 {
                    def.balance_sats - assigned
                } else {
                    (def.balance_sats as f64 * t.tx.amount_sats as f64 / weight as f64) as u64
                };
                assigned += value;
                Utxo {
                    txid: t.tx.txid.clone(),
                    vout: (r.next() * 2.0) as u32,
                    account_id: def.id.into(),
                    address: address_at(def.seed, def.script, Chain::Receive, t.index),
                    value_sats: value,
                    timestamp: t.tx.timestamp,
                    label: t.tx.label.clone(),
                }
            })
            .collect();

        Self {
            account: Account {
                id: def.id.into(),
                name: def.name.into(),
                policy: def.policy.into(),
                script_type: def.script,
                standard: def.standard.into(),
                derivation_path: def.path.into(),
                is_multisig: def.script.is_multisig(),
                balance_sats: def.balance_sats,
            },
            txs,
            utxos,
            hold,
            receive_used: rc,
            change_used: cc,
            seed: def.seed,
        }
    }

    fn address_info(&self, chain: Chain, index: u32) -> AddressInfo {
        let address = address_at(self.seed, self.account.script_type, chain, index);
        let tx = self.txs.iter().find(|t| t.chain == chain && t.index == index);
        let balance: u64 = self.utxos.iter().filter(|u| u.address == address).map(|u| u.value_sats).sum();
        let c = if chain == Chain::Receive { 0 } else { 1 };
        AddressInfo {
            chain,
            index,
            derivation_path: format!("{}/{c}/{index}", self.account.derivation_path),
            label: tx.and_then(|t| t.tx.label.clone()),
            tx_count: match (tx.is_some(), balance > 0) {
                (false, _) => 0,
                (true, true) => 1,
                (true, false) => 2, // received then spent
            },
            balance_sats: balance,
            address,
        }
    }

    pub fn addresses(&self, chain: Chain) -> Vec<AddressInfo> {
        let count = match chain {
            Chain::Receive => self.receive_used + RECEIVE_GAP,
            Chain::Change => self.change_used + CHANGE_GAP,
        };
        (0..count).map(|i| self.address_info(chain, i)).collect()
    }

    pub fn next_receive(&self, offset: u32) -> Result<AddressInfo, WalletError> {
        let index = self.receive_used.checked_add(offset).ok_or_else(|| WalletError::backend("receive address offset is too large"))?;
        Ok(self.address_info(Chain::Receive, index))
    }

    pub fn spendable_sats(&self) -> u64 {
        let pending: i64 = self.txs.iter().filter(|t| t.tx.confirmations == 0).map(|t| t.tx.amount_sats).sum();
        (self.account.balance_sats as i64 - pending.max(0)).max(0) as u64
    }

    fn vbytes(&self) -> u32 {
        match self.account.script_type {
            ScriptType::P2wpkh => 141,
            ScriptType::P2tr => 154,
            ScriptType::P2wsh | ScriptType::P2shP2wsh => 211,
            ScriptType::P2shP2wpkh => 166,
            ScriptType::P2pkh => 226,
            ScriptType::P2sh => 297,
        }
    }

    pub fn fee_sats(&self, sat_per_vb: f64) -> Result<u64, WalletError> {
        // Preview quotes must reject the same invalid fee inputs as live drafts.
        crate::wallet::tx::fee_rate(sat_per_vb)?;
        Ok((sat_per_vb * f64::from(self.vbytes())).ceil() as u64)
    }

    pub fn draft(&self, address: &str, amount_sats: u64, sat_per_vb: f64) -> Result<DraftTransaction, WalletError> {
        // Sample addresses are random strings, but recipients are checked for real.
        let recipient = parse_recipient(address, Network::Bitcoin)?;
        if amount_sats == 0 {
            return Err(WalletError::ZeroAmount);
        }
        let fee = self.fee_sats(sat_per_vb)?;
        let total = amount_sats.checked_add(fee).ok_or_else(|| WalletError::backend("amount plus fee exceeds the supported range"))?;
        let available = self.spendable_sats();
        if total > available {
            return Err(WalletError::InsufficientFunds { needed_sats: total, available_sats: available });
        }
        Ok(DraftTransaction {
            amount_sats,
            fee_sats: fee,
            vbytes: self.vbytes(),
            total_sats: total,
            balance_after_sats: available - total,
            psbt_base64: String::new(),
            outputs: vec![TxOutput { address: recipient.to_string(), amount_sats, is_change: false }],
            effective_fee_rate: sat_per_vb,
            warnings: Vec::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn balances_are_consistent() {
        let data = SampleData::generate();
        for a in &data.accounts {
            assert_eq!(a.hold[DAYS], a.account.balance_sats, "{}", a.account.id);
            let utxo_sum: u64 = a.utxos.iter().map(|u| u.value_sats).sum();
            assert_eq!(utxo_sum, a.account.balance_sats, "{}", a.account.id);
            assert_eq!(a.txs[0].tx.balance_after_sats, a.account.balance_sats);
        }
    }

    #[test]
    fn history_lengths() {
        let data = SampleData::generate();
        assert_eq!(data.history(None, TimeRange::Week).len(), 8);
        assert_eq!(data.history(Some("cold"), TimeRange::Quarter).len(), 91);
        let total: u64 = data.accounts.iter().map(|a| a.account.balance_sats).sum();
        assert_eq!(data.history(None, TimeRange::Year).last().unwrap().balance_sats, total);
    }

    #[test]
    fn draft_rejects_overspend() {
        let data = SampleData::generate();
        let acc = data.account("spend").unwrap();
        let addr = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu";
        assert!(matches!(acc.draft(addr, 10_000_000_000, 12.0), Err(WalletError::InsufficientFunds { .. })));
        assert!(acc.draft(addr, 10_000, 12.0).is_ok());
        assert!(matches!(acc.draft(&acc.next_receive(0).unwrap().address, 10_000, 12.0), Err(WalletError::InvalidAddress)));
        assert!(matches!(acc.draft("nope", 10_000, 12.0), Err(WalletError::InvalidAddress)));
    }
}
