//! Northvault wallet core.
//!
//! Everything the macOS UI needs comes through [`WalletService`]. It has two
//! backends: deterministic sample data (`mock.rs`, for previews and design
//! review) and real watch-only wallets (BDK + Electrum, `wallet/`).
//!
//! Security boundary: private keys and signing never live in this crate or in
//! Swift. Spending produces an unsigned PSBT that is signed on the hardware
//! device; the signed PSBT is checked against the draft before broadcast.

uniffi::setup_scaffolding!();

// One Rust link unit in the full macOS app avoids duplicate secp256k1 symbols.
pub use northvault_descriptor::{nv_descriptor_free, nv_descriptor_validate};

mod chain;
mod hwi;
mod interop;
mod mock;
mod models;
mod pin;
mod store;
mod wallet;

#[cfg(test)]
mod sync_tests;

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use bdk_wallet::bitcoin::Psbt;

pub use interop::ur::UrDecoder;
pub use models::*;
pub use pin::{set_trezor_pin_provider, TrezorPinProvider};

use chain::electrum;
use chain::price::{PriceSource, SamplePrices};
use interop::labels::LabelType;
use interop::psbt_io;
use store::{Store, WalletRecord};
use wallet::descriptor;
use wallet::live::LiveAccount;
use wallet::tx::DraftRequest;

#[derive(uniffi::Object)]
pub struct WalletService {
    backend: Backend,
}

enum Backend {
    Sample(mock::SampleData),
    Live(Live),
}

struct Live {
    network: Network,
    store: Store,
    accounts: Mutex<Vec<LiveAccount>>,
    server: Mutex<Option<String>>,
    fees: Mutex<Vec<FeeEstimate>>,
    prices: Box<dyn PriceSource>,
}

impl Live {
    fn apply_discovery(&self, discovery: electrum::Discovery) -> Result<(), WalletError> {
        for (id, full, revealed) in discovery.updates {
            self.with_account(&id, |a| {
                a.wallet.apply_update(full).map_err(WalletError::backend)?;
                a.wallet.apply_update(revealed).map_err(WalletError::backend)?;
                a.persist()
            })?;
        }
        if let Ok(fees) = discovery.fees {
            *self.fees.lock().unwrap() = fees;
        }
        Ok(())
    }

    fn accounts(&self) -> MutexGuard<'_, Vec<LiveAccount>> {
        self.accounts.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn with_account<T>(&self, id: &str, f: impl FnOnce(&mut LiveAccount) -> Result<T, WalletError>) -> Result<T, WalletError> {
        let mut accounts = self.accounts();
        let acc = accounts.iter_mut().find(|a| a.id() == id).ok_or(WalletError::UnknownAccount)?;
        f(acc)
    }

    fn record(&self, id: &str) -> Result<WalletRecord, WalletError> {
        self.with_account(id, |a| Ok(a.record.clone()))
    }

    fn server(&self) -> Result<String, WalletError> {
        self.server.lock().unwrap().clone().ok_or_else(|| WalletError::server("add an Electrum server in Settings first"))
    }
}

fn read_only() -> WalletError {
    WalletError::NotSupported { message: "the sample wallet is read-only".into() }
}

/// Filter for "this account, or every account when `id` is `None`".
fn selected(id: &Option<String>) -> impl Fn(&&LiveAccount) -> bool + '_ {
    move |a| id.as_deref().is_none_or(|id| a.id() == id)
}

/// Decodes the draft and every signed copy; all are untrusted base64 input.
fn parse_psbts(draft: &str, signed: &[String]) -> Result<(Psbt, Vec<Psbt>), WalletError> {
    Ok((psbt_io::from_base64(draft)?, signed.iter().map(|s| psbt_io::from_base64(s)).collect::<Result<_, _>>()?))
}

fn label_type(kind: LabelKind) -> LabelType {
    match kind {
        LabelKind::Transaction => LabelType::Tx,
        LabelKind::Address => LabelType::Addr,
        LabelKind::Output => LabelType::Output,
    }
}

impl WalletService {
    fn live(&self) -> Result<&Live, WalletError> {
        match &self.backend {
            Backend::Live(l) => Ok(l),
            Backend::Sample(_) => Err(read_only()),
        }
    }

    fn network_or_bitcoin(&self) -> Network {
        match &self.backend {
            Backend::Live(l) => l.network,
            Backend::Sample(_) => Network::Bitcoin,
        }
    }
}

#[uniffi::export]
impl WalletService {
    /// Deterministic sample wallet used for UI development and previews.
    #[uniffi::constructor]
    pub fn new_sample() -> Arc<Self> {
        Arc::new(Self { backend: Backend::Sample(mock::SampleData::generate()) })
    }

    /// Opens the real wallets stored under `data_dir` for `network`.
    #[uniffi::constructor]
    pub fn open(data_dir: String, network: Network, electrum_url: Option<String>) -> Result<Arc<Self>, WalletError> {
        let store = Store::open(&PathBuf::from(data_dir), network)?;
        let accounts = store.load()?.into_iter().map(|r| LiveAccount::open(&store, r, network)).collect::<Result<Vec<_>, _>>()?;
        Ok(Arc::new(Self {
            backend: Backend::Live(Live {
                network,
                store,
                accounts: Mutex::new(accounts),
                server: Mutex::new(electrum_url.filter(|u| !u.trim().is_empty())),
                fees: Mutex::new(Vec::new()),
                prices: Box::new(SamplePrices),
            }),
        }))
    }

    pub fn is_sample(&self) -> bool {
        matches!(self.backend, Backend::Sample(_))
    }

    pub fn network(&self) -> Network {
        self.network_or_bitcoin()
    }

    pub fn set_electrum_server(&self, url: Option<String>) -> Result<(), WalletError> {
        *self.live()?.server.lock().unwrap() = url.filter(|u| !u.trim().is_empty());
        Ok(())
    }

    pub fn accounts(&self) -> Vec<Account> {
        match &self.backend {
            Backend::Sample(d) => d.accounts.iter().map(|a| a.account.clone()).collect(),
            Backend::Live(l) => l.accounts().iter().map(LiveAccount::account).collect(),
        }
    }

    /// Total balance across every account, in sats.
    pub fn total_balance_sats(&self) -> u64 {
        self.accounts().iter().map(|a| a.balance_sats).sum()
    }

    /// Newest first. `account_id = None` returns all accounts merged.
    pub fn transactions(&self, account_id: Option<String>) -> Vec<WalletTransaction> {
        let mut out: Vec<WalletTransaction> = match &self.backend {
            Backend::Sample(d) => d.select(account_id.as_deref()).flat_map(|a| a.txs.iter().map(|t| t.tx.clone())).collect(),
            Backend::Live(l) => l.accounts().iter().filter(selected(&account_id)).flat_map(LiveAccount::transactions).collect(),
        };
        out.sort_by(|a, b| (b.confirmations == 0, b.timestamp).cmp(&(a.confirmations == 0, a.timestamp)));
        out
    }

    pub fn utxos(&self, account_id: Option<String>) -> Vec<Utxo> {
        match &self.backend {
            Backend::Sample(d) => d.select(account_id.as_deref()).flat_map(|a| a.utxos.iter().cloned()).collect(),
            Backend::Live(l) => l.accounts().iter().filter(selected(&account_id)).flat_map(LiveAccount::utxos).collect(),
        }
    }

    pub fn addresses(&self, account_id: String, chain: Chain) -> Result<Vec<AddressInfo>, WalletError> {
        match &self.backend {
            Backend::Sample(d) => Ok(d.account(&account_id)?.addresses(chain)),
            Backend::Live(l) => l.with_account(&account_id, |a| Ok(a.addresses(chain))),
        }
    }

    /// First unused receive address, skipping `offset` further unused ones
    /// ("Get next address").
    pub fn next_receive_address(&self, account_id: String, offset: u32) -> Result<AddressInfo, WalletError> {
        match &self.backend {
            Backend::Sample(d) => d.account(&account_id)?.next_receive(offset),
            Backend::Live(l) => l.with_account(&account_id, |a| a.next_receive(offset)),
        }
    }

    /// Balance history for the chart. `account_id = None` = whole portfolio.
    pub fn net_worth_history(&self, account_id: Option<String>, range: TimeRange) -> Vec<NetWorthPoint> {
        let l = match &self.backend {
            Backend::Sample(d) => return d.history(account_id.as_deref(), range),
            Backend::Live(l) => l,
        };
        let (days, step) = match range {
            TimeRange::Week => (7, 1),
            TimeRange::Month => (30, 1),
            TimeRange::Quarter => (90, 1),
            TimeRange::Year => (365, 4),
            TimeRange::AllTime => {
                let today = wallet::live::now().div_euclid(86_400);
                let first_day = self.transactions(account_id.clone()).iter().map(|tx| tx.timestamp.div_euclid(86_400)).min().unwrap_or(today);
                ((today - first_day).max(0) as usize, 1)
            }
        };
        let prices = l.prices.daily_usd(days);
        let accounts = l.accounts();
        let series: Vec<Vec<(i64, u64)>> = accounts.iter().filter(selected(&account_id)).map(|a| a.daily_balances(days)).collect();
        let mut idx: Vec<usize> = (0..=days).step_by(step).collect();
        if idx.last() != Some(&days) {
            idx.push(days);
        }
        idx.into_iter()
            .map(|d| NetWorthPoint {
                timestamp: series.first().map_or(0, |s| s[d].0),
                balance_sats: series.iter().map(|s| s[d].1).sum(),
                btc_price_usd: prices.get(d).copied().unwrap_or_default(),
            })
            .collect()
    }

    /// Latest BTC price in USD.
    pub fn btc_price_usd(&self) -> f64 {
        match &self.backend {
            Backend::Sample(d) => d.latest_price(),
            Backend::Live(l) => l.prices.daily_usd(0).last().copied().unwrap_or_default(),
        }
    }

    /// Multiply a USD amount by this to get `currency`.
    pub fn fx_rate_from_usd(&self, currency: FiatCurrency) -> f64 {
        match &self.backend {
            Backend::Sample(_) => mock::fx_rate(currency),
            Backend::Live(l) => l.prices.fx_rate_from_usd(currency),
        }
    }

    /// Empty until the first successful sync with a live backend.
    pub fn fee_estimates(&self) -> Vec<FeeEstimate> {
        match &self.backend {
            Backend::Sample(_) => mock::fee_estimates(),
            Backend::Live(l) => l.fees.lock().unwrap().clone(),
        }
    }

    /// Builds (but does not sign) a transaction and returns its summary.
    /// `selected_utxos` empty = automatic coin selection.
    pub fn draft_transaction(
        &self,
        account_id: String,
        address: String,
        amount_sats: u64,
        sat_per_vb: f64,
        selected_utxos: Vec<OutPoint>,
        send_max: bool,
    ) -> Result<DraftTransaction, WalletError> {
        match &self.backend {
            Backend::Sample(d) => d.account(&account_id)?.draft(&address, amount_sats, sat_per_vb),
            Backend::Live(l) => l.with_account(&account_id, |a| {
                let req = DraftRequest { address: &address, amount_sats, sat_per_vb, selected: &selected_utxos, send_max };
                a.draft(&req, false).map(|(d, _)| d)
            }),
        }
    }

    /// Same as `draft_transaction`, but keeps the change address reserved.
    /// Call this when the user commits to signing.
    pub fn create_transaction(
        &self,
        account_id: String,
        address: String,
        amount_sats: u64,
        sat_per_vb: f64,
        selected_utxos: Vec<OutPoint>,
        send_max: bool,
    ) -> Result<DraftTransaction, WalletError> {
        let l = self.live()?;
        l.with_account(&account_id, |a| {
            let req = DraftRequest { address: &address, amount_sats, sat_per_vb, selected: &selected_utxos, send_max };
            let (draft, _) = a.draft(&req, true)?;
            a.persist()?;
            Ok(draft)
        })
    }

    /// Largest amount that can be sent at this fee rate.
    pub fn max_sendable_sats(&self, account_id: String, sat_per_vb: f64, selected_utxos: Vec<OutPoint>) -> Result<u64, WalletError> {
        match &self.backend {
            Backend::Sample(d) => {
                let acc = d.account(&account_id)?;
                Ok(acc.spendable_sats().saturating_sub(acc.fee_sats(sat_per_vb)?))
            }
            Backend::Live(l) => l.with_account(&account_id, |a| a.max_sendable(sat_per_vb, &selected_utxos)),
        }
    }

    // MARK: Wallet setup (SECURITY-SENSITIVE: descriptors and imported keys)

    /// The standard default account path for this script type on the current network.
    pub fn default_derivation_path(&self, script_type: ScriptType) -> String {
        descriptor::default_path(script_type, self.network_or_bitcoin())
    }

    /// Validates a setup and returns its descriptor plus the first receive
    /// addresses, so they can be compared with another wallet or a device before saving.
    pub fn preview_wallet(&self, config: WalletConfig) -> Result<Vec<String>, WalletError> {
        let network = self.network_or_bitcoin();
        let desc = descriptor::build(&config, network)?;
        let (receive, _) = descriptor::split(&desc)?;
        let mut out = vec![desc];
        for i in 0..3 {
            out.push(descriptor::address_at(&receive, i, network)?.to_string());
        }
        Ok(out)
    }

    pub fn create_wallet(&self, config: WalletConfig) -> Result<Account, WalletError> {
        let l = self.live()?;
        let config = descriptor::normalize(&config, l.network)?;
        let desc = descriptor::build(&config, l.network)?;
        let id = WalletRecord::id_for(&desc);
        let mut accounts = l.accounts();
        if accounts.iter().any(|a| a.id() == id) {
            return Err(WalletError::config("this wallet already exists"));
        }
        let record = WalletRecord {
            id,
            name: config.name.trim().to_string(),
            script_type: config.script_type,
            threshold: config.threshold,
            keystores: config.keystores,
            descriptor: desc,
            created_at: wallet::live::now(),
            ledger_registrations: Vec::new(),
        };
        let account = LiveAccount::open(&l.store, record, l.network)?;
        let summary = account.account();
        // Publish only after the registry commits. A failed write must leave the
        // existing accounts usable and allow retrying the same descriptor.
        let mut records: Vec<_> = accounts.iter().map(|a| a.record.clone()).collect();
        records.push(account.record.clone());
        l.store.save(&records)?;
        accounts.push(account);
        Ok(summary)
    }

    /// Reads a wallet file (output descriptor, Specter DIY, Coldcard/Jade multisig setup,
    /// BSMS). Returns the setup for review. Nothing is saved yet.
    pub fn import_wallet(&self, contents: Vec<u8>, filename: String) -> Result<WalletConfig, WalletError> {
        interop::import_wallet(&contents, &filename, self.network_or_bitcoin())
    }

    /// Reads one keystore from a device export or `[fp/path]xpub` text.
    pub fn import_keystore(&self, contents: Vec<u8>, script_type: ScriptType) -> Result<Keystore, WalletError> {
        interop::import_keystore(&contents, script_type, self.network_or_bitcoin())
    }

    pub fn wallet_details(&self, account_id: String) -> Result<WalletDetails, WalletError> {
        self.live()?.with_account(&account_id, |a| a.details())
    }

    pub fn export_wallet(&self, account_id: String, format: ExportFormat) -> Result<Vec<u8>, WalletError> {
        let l = self.live()?;
        l.with_account(&account_id, |a| {
            let config = a.record.config();
            let text = match format {
                ExportFormat::Descriptor => interop::descriptor_file::export(&config, l.network)?,
                ExportFormat::ColdcardMultisig => interop::coldcard::export_multisig(&config, l.network)?,
                ExportFormat::Bsms => interop::bsms::export(&config, l.network)?,
                ExportFormat::SpecterDiy => interop::descriptor_file::export_specter(&config, l.network)?,
                ExportFormat::Labels => a.labels.to_jsonl(Some(a.record.descriptor.split('#').next().unwrap_or_default())),
            };
            Ok(text.into_bytes())
        })
    }

    /// Merges a BIP329 file. Returns the number of labels imported.
    pub fn import_labels(&self, account_id: String, contents: Vec<u8>) -> Result<u32, WalletError> {
        let l = self.live()?;
        let text = String::from_utf8(contents).map_err(|_| WalletError::interop("not a text file"))?;
        l.with_account(&account_id, |a| {
            let mut labels = a.labels.clone();
            let n = labels.merge_jsonl(&text)?;
            l.store.save_labels(&a.record.id, &labels)?;
            a.labels = labels;
            Ok(n as u32)
        })
    }

    /// Empty label removes it.
    pub fn set_label(&self, account_id: String, kind: LabelKind, reference: String, label: String) -> Result<(), WalletError> {
        let l = self.live()?;
        l.with_account(&account_id, |a| a.set_label(&l.store, label_type(kind), &reference, &label))
    }

    pub fn rename_wallet(&self, account_id: String, name: String) -> Result<(), WalletError> {
        let l = self.live()?;
        if name.trim().is_empty() {
            return Err(WalletError::config("give the wallet a name"));
        }
        let mut accounts = l.accounts();
        let index = accounts.iter().position(|a| a.id() == account_id).ok_or(WalletError::UnknownAccount)?;
        let name = name.trim().to_string();
        let mut records: Vec<_> = accounts.iter().map(|a| a.record.clone()).collect();
        records[index].name = name.clone();
        l.store.save(&records)?;
        accounts[index].record.name = name;
        Ok(())
    }

    /// Removes the watch-only wallet from this Mac. Funds are unaffected.
    pub fn delete_wallet(&self, account_id: String) -> Result<(), WalletError> {
        let l = self.live()?;
        let mut accounts = l.accounts();
        let index = accounts.iter().position(|a| a.id() == account_id).ok_or(WalletError::UnknownAccount)?;
        let records: Vec<_> = accounts.iter().filter(|a| a.id() != account_id).map(|a| a.record.clone()).collect();
        l.store.save(&records)?;
        accounts.remove(index);
        l.store.remove(&account_id);
        Ok(())
    }

    // MARK: PSBTs

    /// Signatures collected so far on `draft` plus any `signed` copies.
    pub fn signature_status(&self, account_id: String, draft_psbt: String, signed_psbts: Vec<String>) -> Result<SignatureStatus, WalletError> {
        let l = self.live()?;
        let (draft, signed) = parse_psbts(&draft_psbt, &signed_psbts)?;
        l.with_account(&account_id, |a| Ok(a.signature_status(&a.combine(&draft, &signed)?)))
    }

    /// Reads a `.psbt` file (binary or base64) and returns base64.
    pub fn psbt_from_file(&self, contents: Vec<u8>) -> Result<String, WalletError> {
        Ok(psbt_io::to_base64(&psbt_io::decode(&contents)?))
    }

    /// Binary PSBT for saving to an SD card (Coldcard).
    pub fn psbt_to_file(&self, psbt: String) -> Result<Vec<u8>, WalletError> {
        Ok(psbt_io::from_base64(&psbt)?.serialize())
    }

    /// Frames for an animated BC-UR QR code (Jade, Keystone, Passport).
    pub fn psbt_to_ur_parts(&self, psbt: String) -> Result<Vec<String>, WalletError> {
        interop::ur::psbt_to_parts(&psbt_io::from_base64(&psbt)?)
    }

    /// The account's descriptor as animated `crypto-output` QR frames, for
    /// signers that keep no wallet setup (SeedSigner) to recognize change.
    pub fn descriptor_to_ur_parts(&self, account_id: String) -> Result<Vec<String>, WalletError> {
        let l = self.live()?;
        let config = l.record(&account_id)?.config();
        interop::ur::descriptor_to_parts(&config, l.network)
    }

    /// The key for `script_type` from a scanned account QR (`crypto-account`
    /// or `[fingerprint/path]xpub`). None until every frame is in.
    pub fn import_keystore_qr(&self, decoder: Arc<UrDecoder>, script_type: ScriptType) -> Result<Option<Keystore>, WalletError> {
        decoder.keystore(script_type, self.network_or_bitcoin())
    }
}

// SECURITY-SENSITIVE — requires human review before merge: sync, broadcast
// and every hardware device call (address verification, registration, signing).
#[uniffi::export(async_runtime = "tokio")]
impl WalletService {
    /// Syncs one account (or all) with the Electrum server and refreshes fee estimates.
    pub async fn sync(&self, account_id: Option<String>) -> Result<(), WalletError> {
        let l = self.live()?;
        let url = l.server()?;
        let requests: Vec<_> = l
            .accounts()
            .iter()
            .filter(selected(&account_id))
            .map(|a| (a.id().to_string(), a.wallet.start_full_scan().build(), a.wallet.start_sync_with_revealed_spks().build()))
            .collect();

        let discovery = tokio::task::spawn_blocking(move || -> Result<_, WalletError> {
            let client = electrum::connect(&url)?;
            electrum::discover(&client, requests)
        })
        .await
        .map_err(WalletError::backend)??;

        l.apply_discovery(discovery)
    }

    /// Checks every signed PSBT against the draft, finalizes and broadcasts.
    /// Returns the txid.
    pub async fn broadcast(&self, account_id: String, draft_psbt: String, signed_psbts: Vec<String>) -> Result<String, WalletError> {
        let l = self.live()?;
        let url = l.server()?;
        let (draft, signed) = parse_psbts(&draft_psbt, &signed_psbts)?;
        let tx = l.with_account(&account_id, |a| a.finalize(a.combine(&draft, &signed)?))?;

        let sent = tx.clone();
        let txid = tokio::task::spawn_blocking(move || electrum::broadcast(&electrum::connect(&url)?, &sent)).await.map_err(WalletError::backend)??;
        l.with_account(&account_id, |a| {
            a.wallet.apply_unconfirmed_txs([(tx, wallet::live::now() as u64)]);
            a.persist()
        })?;
        Ok(txid.to_string())
    }

    /// Hardware wallets connected over USB.
    pub async fn list_devices(&self) -> Result<Vec<HardwareDevice>, WalletError> {
        hwi::list(self.network_or_bitcoin()).await
    }

    /// Reads the account xpub for `script_type` (the standard default path) from a device.
    pub async fn device_keystore(&self, device_id: String, script_type: ScriptType) -> Result<Keystore, WalletError> {
        let network = self.network_or_bitcoin();
        hwi::keystore(&device_id, &descriptor::default_path(script_type, network), network).await
    }

    /// Shows a wallet address on the device screen and checks the device
    /// derived the same address. Returns the verified address.
    pub async fn device_verify_address(&self, device_id: String, account_id: String, chain: Chain, index: u32) -> Result<String, WalletError> {
        let l = self.live()?;
        let record = l.record(&account_id)?;
        let expected = l.with_account(&account_id, |a| Ok(a.wallet.peek_address(wallet::live::keychain(chain), index).address.to_string()))?;
        let shown = hwi::display_address(&device_id, &record, l.network, chain, index).await?;
        if shown != expected {
            return Err(WalletError::AddressMismatch { device_address: shown });
        }
        Ok(shown)
    }

    /// Registers a multisig wallet on the device (Coldcard, Jade, Ledger). Trezor needs no registration.
    pub async fn device_register_wallet(&self, device_id: String, account_id: String) -> Result<(), WalletError> {
        let l = self.live()?;
        let record = l.record(&account_id)?;
        let Some(registration) = hwi::register(&device_id, &record, l.network).await? else { return Ok(()) };
        // Ledger needs its registration back on every request; one per device.
        let mut accounts = l.accounts();
        let index = accounts.iter().position(|a| a.id() == account_id).ok_or(WalletError::UnknownAccount)?;
        let mut records: Vec<_> = accounts.iter().map(|a| a.record.clone()).collect();
        let registrations = &mut records[index].ledger_registrations;
        registrations.retain(|r| r.fingerprint != registration.fingerprint);
        registrations.push(registration);
        l.store.save(&records)?;
        accounts[index].record = records.swap_remove(index);
        Ok(())
    }

    /// Asks the device to sign. Returns the device's PSBT (base64), which is
    /// checked against the draft before it can be broadcast.
    pub async fn device_sign(&self, device_id: String, account_id: String, psbt: String) -> Result<String, WalletError> {
        let l = self.live()?;
        let record = l.record(&account_id)?;
        let draft = psbt_io::from_base64(&psbt)?;
        let signed = hwi::sign(&device_id, &record, l.network, draft.clone()).await?;
        if signed.unsigned_tx.compute_txid() != draft.unsigned_tx.compute_txid() {
            return Err(WalletError::PsbtMismatch);
        }
        Ok(psbt_io::to_base64(&signed))
    }
}
