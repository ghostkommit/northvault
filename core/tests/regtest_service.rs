//! Public service workflows. Live wallets use disposable Regtest storage. The
//! legacy design-preview backend advertises Bitcoin and never contacts a node.
#[allow(dead_code)]
mod support;

use std::str::FromStr;

use bdk_wallet::bitcoin::{Address, Network as BitcoinNetwork};
use northvault_core::{Chain, ExportFormat, FiatCurrency, Network, ScriptType, TimeRange, WalletError, WalletService};

fn recipients() -> (String, String) {
    let dir = tempfile::tempdir().unwrap();
    let service = WalletService::open(dir.path().to_str().unwrap().into(), Network::Regtest, None).unwrap();
    let account = service.create_wallet(support::config(ScriptType::P2wpkh)).unwrap();
    let regtest = service.wallet_details(account.id).unwrap().first_receive_address;
    let script = Address::from_str(&regtest).unwrap().require_network(BitcoinNetwork::Regtest).unwrap().script_pubkey();
    let preview = Address::from_script(&script, BitcoinNetwork::Bitcoin).unwrap().to_string();
    (regtest, preview)
}

fn read_only<T>(result: Result<T, WalletError>) {
    assert!(matches!(result, Err(WalletError::NotSupported { .. })));
}

const RANGES: [(TimeRange, usize); 5] =
    [(TimeRange::Week, 8), (TimeRange::Month, 31), (TimeRange::Quarter, 91), (TimeRange::Year, 93), (TimeRange::AllTime, 366)];

#[test]
fn regtest_portfolio_filters_and_history_survive_account_lifecycle() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_str().unwrap().to_owned();
    let service = WalletService::open(path.clone(), Network::Regtest, Some("  ".into())).unwrap();
    assert!(service.fee_estimates().is_empty());
    let first = service.create_wallet(support::config(ScriptType::P2wpkh)).unwrap();
    let second = service.create_wallet(support::config(ScriptType::P2wsh)).unwrap();
    for scope in [None, Some(first.id.clone()), Some(second.id.clone())] {
        for (range, count) in RANGES {
            let history = service.net_worth_history(scope.clone(), range);
            assert_eq!(history.len(), if range == TimeRange::AllTime { 1 } else { count });
            assert!(history.iter().all(|p| p.balance_sats == 0 && p.timestamp > 0 && p.btc_price_usd > 0.0));
            assert!(history.windows(2).all(|w| w[0].timestamp < w[1].timestamp));
            assert_eq!(history.last().unwrap().btc_price_usd, service.btc_price_usd());
        }
        assert!(service.transactions(scope.clone()).is_empty());
        assert!(service.utxos(scope).is_empty());
    }
    for currency in [FiatCurrency::Usd, FiatCurrency::Eur, FiatCurrency::Gbp, FiatCurrency::Chf, FiatCurrency::Jpy] {
        assert!(service.fx_rate_from_usd(currency).is_finite());
        assert!(service.fx_rate_from_usd(currency) > 0.0);
    }
    assert!(service.transactions(Some("missing".into())).is_empty());
    assert!(service.utxos(Some("missing".into())).is_empty());
    assert!(matches!(service.addresses("missing".into(), Chain::Receive), Err(WalletError::UnknownAccount)));
    assert!(matches!(service.next_receive_address("missing".into(), 0), Err(WalletError::UnknownAccount)));
    assert!(matches!(service.rename_wallet("missing".into(), "Valid name".into()), Err(WalletError::UnknownAccount)));
    service.delete_wallet(first.id).unwrap();
    drop(service);
    let reopened = WalletService::open(path, Network::Regtest, None).unwrap();
    assert_eq!(reopened.accounts().len(), 1);
    assert_eq!(reopened.accounts()[0].id, second.id);
    assert_eq!(reopened.net_worth_history(None, TimeRange::Week).last().unwrap().balance_sats, 0);
}

#[test]
fn preview_portfolio_balances_transactions_addresses_and_charts_agree() {
    let sample = WalletService::new_sample();
    assert!(sample.is_sample());
    assert_eq!(sample.network(), Network::Bitcoin);
    let accounts = sample.accounts();
    assert_eq!(accounts.len(), 4);
    assert_eq!(sample.total_balance_sats(), accounts.iter().map(|a| a.balance_sats).sum::<u64>());
    let all = sample.transactions(None);
    assert!(all.iter().any(|tx| tx.confirmations == 0));
    assert!(all.windows(2).all(|w| (w[0].confirmations == 0, w[0].timestamp) >= (w[1].confirmations == 0, w[1].timestamp)));
    for account in &accounts {
        let txs = sample.transactions(Some(account.id.clone()));
        assert!(txs.iter().all(|tx| tx.account_id == account.id));
        assert_eq!(txs.iter().map(|tx| tx.amount_sats).sum::<i64>(), account.balance_sats as i64);
        assert_eq!(sample.utxos(Some(account.id.clone())).iter().map(|u| u.value_sats).sum::<u64>(), account.balance_sats);
        for chain in [Chain::Receive, Chain::Change] {
            let addresses = sample.addresses(account.id.clone(), chain).unwrap();
            assert!(addresses.iter().all(|a| a.chain == chain));
            assert!(addresses.windows(2).all(|w| w[0].index + 1 == w[1].index && w[0].address != w[1].address));
            if chain == Chain::Receive {
                let unused = addresses.iter().find(|a| a.tx_count == 0).unwrap();
                assert_eq!(sample.next_receive_address(account.id.clone(), 0).unwrap().address, unused.address);
                assert_eq!(sample.next_receive_address(account.id.clone(), 2).unwrap().index, unused.index + 2);
                assert_eq!(addresses.iter().map(|a| a.balance_sats).sum::<u64>(), account.balance_sats);
            }
        }
        for (range, count) in RANGES {
            let chart = sample.net_worth_history(Some(account.id.clone()), range);
            assert_eq!(chart.len(), count);
            assert_eq!(chart.last().unwrap().balance_sats, account.balance_sats);
            assert!(chart.windows(2).all(|w| w[0].timestamp < w[1].timestamp));
        }
    }
    assert_eq!(all.len(), accounts.iter().map(|a| sample.transactions(Some(a.id.clone())).len()).sum::<usize>());
    for (range, _) in RANGES {
        assert_eq!(sample.net_worth_history(None, range).last().unwrap().balance_sats, sample.total_balance_sats());
    }
    assert!(sample.net_worth_history(Some("missing".into()), TimeRange::Week).iter().all(|p| p.balance_sats == 0));
    for currency in [FiatCurrency::Usd, FiatCurrency::Eur, FiatCurrency::Gbp, FiatCurrency::Chf, FiatCurrency::Jpy] {
        assert!(sample.fx_rate_from_usd(currency) > 0.0);
    }
    assert!(sample.btc_price_usd() > 0.0);
    let fees = sample.fee_estimates();
    assert_eq!(fees.len(), 3);
    assert!(fees.windows(2).all(|w| w[0].sat_per_vb < w[1].sat_per_vb && w[0].target_blocks > w[1].target_blocks));
    assert!(sample.transactions(Some("missing".into())).is_empty());
    assert!(sample.utxos(Some("missing".into())).is_empty());
    assert!(matches!(sample.addresses("missing".into(), Chain::Change), Err(WalletError::UnknownAccount)));
}

#[tokio::test]
async fn preview_can_quote_but_cannot_persist_sign_or_broadcast() {
    let sample = WalletService::new_sample();
    let (regtest, preview) = recipients();
    for account in sample.accounts() {
        let id = account.id;
        let draft = sample.draft_transaction(id.clone(), preview.clone(), 10_000, 2.0, vec![], false).unwrap();
        assert_eq!(draft.total_sats, draft.amount_sats + draft.fee_sats);
        assert_eq!(draft.amount_sats, 10_000);
        assert!(draft.psbt_base64.is_empty());
        assert_eq!(draft.outputs.len(), 1);
        assert_eq!(draft.outputs[0].address, preview);
        let maximum = sample.max_sendable_sats(id.clone(), 2.0, vec![]).unwrap();
        assert!(maximum < account.balance_sats);
        assert!(sample.draft_transaction(id.clone(), preview.clone(), maximum, 2.0, vec![], false).is_ok());
        assert!(matches!(sample.draft_transaction(id.clone(), preview.clone(), maximum + 1, 2.0, vec![], false), Err(WalletError::InsufficientFunds { .. })));
        assert!(matches!(sample.draft_transaction(id.clone(), regtest.clone(), 1_000, 2.0, vec![], false), Err(WalletError::WrongNetwork)));
        assert!(matches!(sample.draft_transaction(id.clone(), preview.clone(), 0, 2.0, vec![], false), Err(WalletError::ZeroAmount)));
        assert!(matches!(sample.draft_transaction(id.clone(), "invalid".into(), 1_000, 2.0, vec![], false), Err(WalletError::InvalidAddress)));
        read_only(sample.create_transaction(id.clone(), preview.clone(), 1_000, 2.0, vec![], false));
        read_only(sample.wallet_details(id.clone()));
        read_only(sample.export_wallet(id.clone(), ExportFormat::Descriptor));
        read_only(sample.import_labels(id.clone(), vec![]));
        read_only(sample.rename_wallet(id.clone(), "Other".into()));
        read_only(sample.delete_wallet(id.clone()));
        read_only(sample.signature_status(id.clone(), String::new(), vec![]));
        read_only(sample.broadcast(id.clone(), String::new(), vec![]).await);
        read_only(sample.device_verify_address("synthetic:none".into(), id.clone(), Chain::Receive, 0).await);
        read_only(sample.device_register_wallet("synthetic:none".into(), id.clone()).await);
        read_only(sample.device_sign("synthetic:none".into(), id, String::new()).await);
    }
    read_only(sample.create_wallet(support::config(ScriptType::P2wpkh)));
    read_only(sample.set_electrum_server(None));
    read_only(sample.sync(None).await);
    assert_eq!(sample.accounts().len(), 4);
}

#[test]
fn preview_rejects_invalid_fee_quotes() {
    let sample = WalletService::new_sample();
    let (_, address) = recipients();
    let id = sample.accounts()[0].id.clone();
    for rate in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0, 0.0, 0.5, 1001.0] {
        assert!(sample.draft_transaction(id.clone(), address.clone(), 1_000, rate, vec![], false).is_err());
        assert!(sample.max_sendable_sats(id.clone(), rate, vec![]).is_err());
    }
}

#[test]
fn preview_rejects_oversized_amounts_without_panicking() {
    let sample = WalletService::new_sample();
    let (_, address) = recipients();
    let id = sample.accounts()[0].id.clone();
    assert!(sample.draft_transaction(id, address, u64::MAX, 1.0, vec![], false).is_err());
}

#[test]
fn preview_receive_offset_overflow_is_an_error_and_does_not_change_the_account() {
    let sample = WalletService::new_sample();
    let id = sample.accounts()[0].id.clone();
    let before = sample.next_receive_address(id.clone(), 0).unwrap();
    assert!(sample.next_receive_address(id.clone(), u32::MAX).is_err());
    assert_eq!(sample.next_receive_address(id, 0).unwrap().address, before.address);
}

#[cfg(not(feature = "hardware"))]
#[tokio::test]
async fn portable_regtest_service_reports_unavailable_hardware_without_mutation() {
    use bdk_wallet::bitcoin::{absolute, transaction, Psbt, Transaction};
    let dir = tempfile::tempdir().unwrap();
    let service = WalletService::open(dir.path().to_str().unwrap().into(), Network::Regtest, None).unwrap();
    assert!(service.list_devices().await.unwrap().is_empty());
    let unsigned =
        Psbt::from_unsigned_tx(Transaction { version: transaction::Version::TWO, lock_time: absolute::LockTime::ZERO, input: vec![], output: vec![] }).unwrap();
    let encoded = service.psbt_from_file(unsigned.serialize()).unwrap();
    for script in [ScriptType::P2wpkh, ScriptType::P2wsh] {
        let account = service.create_wallet(support::config(script)).unwrap();
        let before = service.wallet_details(account.id.clone()).unwrap();
        let device = "synthetic:no-device".to_owned();
        read_only(service.device_keystore(device.clone(), script).await);
        read_only(service.device_verify_address(device.clone(), account.id.clone(), Chain::Receive, 0).await);
        read_only(service.device_sign(device.clone(), account.id.clone(), encoded.clone()).await);
        let registered = service.device_register_wallet(device, account.id.clone()).await;
        if script.is_multisig() {
            read_only(registered);
        } else {
            // Single-signature wallets have no registration operation.
            registered.unwrap();
        }
        assert!(matches!(service.device_keystore("malformed".into(), script).await, Err(WalletError::Device { .. })));
        assert!(matches!(service.device_verify_address("malformed".into(), account.id.clone(), Chain::Receive, 0).await, Err(WalletError::Device { .. })));
        assert!(matches!(service.device_sign("malformed".into(), account.id.clone(), encoded.clone()).await, Err(WalletError::Device { .. })));
        assert!(matches!(service.device_register_wallet("malformed".into(), account.id.clone()).await, Err(WalletError::Device { .. })));
        assert_eq!(service.wallet_details(account.id).unwrap().descriptor, before.descriptor);
    }
    assert_eq!(service.total_balance_sats(), 0);
}

#[test]
fn trezor_credential_provider_can_be_registered_without_a_device() {
    struct Cancelled;
    impl northvault_core::TrezorPinProvider for Cancelled {
        fn request_pin(&self) -> Option<String> {
            None
        }
        fn request_passphrase(&self) -> Option<String> {
            None
        }
    }
    // Registration alone must not prompt, connect to hardware or change wallet state.
    northvault_core::set_trezor_pin_provider(Box::new(Cancelled));
    assert!(WalletService::new_sample().is_sample());
}
