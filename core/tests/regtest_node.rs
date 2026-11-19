//! Consensus-backed integration test. Run through scripts/test-regtest.py or
//! `docker compose run --build --rm tests`, using isolated Regtest services.
mod support;

use std::{env, path::PathBuf, process::Command, time::Duration};

use bdk_electrum::electrum_client::{Client, ElectrumApi};
use bdk_wallet::bitcoin::{
    blockdata::constants::genesis_block,
    hashes::{sha256, Hash},
    Network as BitcoinNetwork,
};
use northvault_core::{Chain, LabelKind, Network, OutPoint, TimeRange, WalletError, WalletService};
use serde_json::Value;

struct Node {
    cli: String,
    directory: PathBuf,
    port: u16,
}

impl Node {
    fn rpc(&self, args: &[&str]) -> Value {
        let output = Command::new(&self.cli)
            .arg(format!("-datadir={}", self.directory.display()))
            .arg("-regtest")
            .arg("-rpcconnect=127.0.0.1")
            .arg(format!("-rpcport={}", self.port))
            .arg("-rpcclienttimeout=15")
            .arg("-rpcwallet=northvault-integration-miner")
            .args(args)
            .output()
            .expect("run bitcoin-cli");
        assert!(output.status.success(), "Bitcoin Core fixture RPC failed");
        serde_json::from_slice(&output.stdout).unwrap_or_else(|_| Value::String(String::from_utf8(output.stdout).unwrap().trim().into()))
    }

    fn mine(&self) {
        let address = self.rpc(&["getnewaddress"]);
        self.rpc(&["generatetoaddress", "1", address.as_str().unwrap()]);
    }
}

async fn wait_balance(service: &WalletService, id: &str, expected: u64) {
    for _ in 0..60 {
        service.sync(Some(id.into())).await.expect("Regtest Electrum sync");
        if service.accounts().iter().find(|a| a.id == id).unwrap().balance_sats == expected {
            return;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    panic!("Regtest balance did not converge");
}

#[tokio::test]
#[ignore = "requires disposable Bitcoin Core + electrs; run make regtest-test"]
async fn fund_sign_broadcast_confirm_and_reopen_every_script() {
    let node = Node {
        cli: env::var("NORTHVAULT_TEST_BITCOIN_CLI").expect("use make regtest-test"),
        directory: env::var("NORTHVAULT_TEST_NODE_DIR").expect("use make regtest-test").into(),
        port: env::var("NORTHVAULT_TEST_RPC_PORT").unwrap().parse().unwrap(),
    };
    assert_eq!(std::fs::read_to_string(node.directory.join("northvault-test-only")).unwrap(), "disposable regtest\n");
    assert_eq!(node.rpc(&["getblockchaininfo"])["chain"], "regtest");
    let port: u16 = env::var("NORTHVAULT_TEST_ELECTRUM_PORT").unwrap().parse().unwrap();
    let url = format!("tcp://127.0.0.1:{port}");
    let electrum = Client::new(&url).unwrap();
    assert_eq!(electrum.block_header(0).unwrap(), genesis_block(BitcoinNetwork::Regtest).header);

    // The Compose chain persists between runs. Allocate a unique public fixture
    // namespace so these test-only keys cannot rediscover a previous run's coins.
    // These deliberately public seeds must never be used for real funds.
    let run_id = node.rpc(&["getnewaddress"]);
    let signers: Vec<_> = (1..=3)
        .map(|id| {
            let seed = sha256::Hash::hash(format!("northvault-regtest-only:{id}:{}", run_id.as_str().unwrap()).as_bytes());
            support::Signer::from_seed(seed.as_byte_array())
        })
        .collect();

    for script in support::SCRIPTS {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_str().unwrap().to_owned();
        let service = WalletService::open(path.clone(), Network::Regtest, Some(url.clone())).unwrap();
        let mut config = support::config(script);
        config.keystores = signers.iter().take(if script.is_multisig() { 3 } else { 1 }).map(|signer| signer.keystore(script)).collect();
        let account = service.create_wallet(config).unwrap();
        // Revealing an address beyond the gap must still make it discoverable.
        let receive = service.next_receive_address(account.id.clone(), 25).unwrap();
        let receive_address = receive.address.clone();
        node.rpc(&["sendtoaddress", &receive.address, "0.01000000"]);
        node.mine();
        wait_balance(&service, &account.id, 1_000_000).await;
        let coins = service.utxos(Some(account.id.clone()));
        assert_eq!(coins.len(), 1);
        assert_eq!(coins[0].value_sats, 1_000_000);
        assert!(service.transactions(Some(account.id.clone()))[0].confirmations > 0);
        // The funded address is reported as used; earlier ones stay available.
        let funded = &service.addresses(account.id.clone(), Chain::Receive).unwrap()[25];
        assert_eq!((funded.address.as_str(), funded.tx_count, funded.balance_sats), (receive.address.as_str(), 1, 1_000_000));
        assert_eq!(service.next_receive_address(account.id.clone(), 0).unwrap().index, 0);
        for range in [TimeRange::Week, TimeRange::Month, TimeRange::Quarter, TimeRange::Year, TimeRange::AllTime] {
            let chart = service.net_worth_history(Some(account.id.clone()), range);
            assert_eq!(chart.last().unwrap().balance_sats, 1_000_000);
            assert!(chart.iter().all(|point| point.btc_price_usd > 0.0));
        }
        // Exercise Sparrow-style inheritance on a real, indexed output.
        for (kind, reference, label) in [
            (LabelKind::Transaction, coins[0].txid.clone(), "Funding transaction"),
            (LabelKind::Address, receive.address.clone(), "Funding address"),
            (LabelKind::Output, format!("{}:{}", coins[0].txid, coins[0].vout), "Funding output"),
        ] {
            service.set_label(account.id.clone(), kind, reference, label.into()).unwrap();
            assert_eq!(service.utxos(Some(account.id.clone()))[0].label.as_deref(), Some(label));
        }
        service.set_label(account.id.clone(), LabelKind::Output, format!("{}:{}", coins[0].txid, coins[0].vout), String::new()).unwrap();
        assert_eq!(service.utxos(Some(account.id.clone()))[0].label.as_deref(), Some("Funding address"));
        service.set_label(account.id.clone(), LabelKind::Address, receive.address.clone(), String::new()).unwrap();
        assert_eq!(service.utxos(Some(account.id.clone()))[0].label.as_deref(), Some("Funding transaction"));
        let recipient = node.rpc(&["getnewaddress"]);
        let recipient = recipient.as_str().unwrap().to_owned();
        let selected = vec![OutPoint { txid: coins[0].txid.clone(), vout: coins[0].vout }];
        let maximum = service.max_sendable_sats(account.id.clone(), 2.0, selected.clone()).unwrap();
        let drain = service.draft_transaction(account.id.clone(), recipient.clone(), 0, 2.0, selected.clone(), true).unwrap();
        // The destination-independent maximum quote uses our own script size.
        // A Core-generated recipient can have a different output weight.
        let own_drain = service.draft_transaction(account.id.clone(), receive.address.clone(), 0, 2.0, selected.clone(), true).unwrap();
        assert_eq!(own_drain.amount_sats, maximum);
        assert_eq!(drain.amount_sats + drain.fee_sats, 1_000_000);
        assert_eq!(drain.total_sats, 1_000_000);
        assert_eq!(drain.outputs.len(), 1);
        assert!(!drain.outputs[0].is_change);
        let expensive = service.draft_transaction(account.id.clone(), receive.address, 10_000, 600.0, selected.clone(), false).unwrap();
        assert!(expensive.warnings.iter().any(|warning| warning.contains("very high")));
        assert!(expensive.warnings.iter().any(|warning| warning.contains("belongs to this wallet")));
        assert!(expensive.warnings.iter().any(|warning| warning.contains("amount sent")));
        let draft = service.create_transaction(account.id.clone(), recipient.clone(), 100_000, 2.0, selected, false).unwrap();
        assert!(draft.outputs.iter().any(|o| o.address == recipient && o.amount_sats == 100_000 && !o.is_change));
        assert!(draft.outputs.iter().any(|o| o.is_change));
        assert!(matches!(service.broadcast(account.id.clone(), draft.psbt_base64.clone(), vec![]).await, Err(WalletError::NotEnoughSignatures { .. })));

        let outgoing = support::qr_roundtrip(&service, draft.psbt_base64.clone());
        let mut signatures = Vec::new();
        for id in 1..=if script.is_multisig() { 2 } else { 1 } {
            let bytes = signers[id - 1].sign(&service.psbt_to_file(outgoing.clone()).unwrap());
            let encoded = service.psbt_from_file(bytes).unwrap();
            signatures.push(support::qr_roundtrip(&service, encoded));
            if script.is_multisig() && id == 1 {
                assert!(matches!(
                    service.broadcast(account.id.clone(), draft.psbt_base64.clone(), signatures.clone()).await,
                    Err(WalletError::NotEnoughSignatures { .. })
                ));
            }
        }
        let other = service.draft_transaction(account.id.clone(), recipient, 90_000, 2.0, vec![], false).unwrap();
        assert!(matches!(service.broadcast(account.id.clone(), other.psbt_base64, signatures.clone()).await, Err(WalletError::PsbtMismatch)));
        let txid = service.broadcast(account.id.clone(), draft.psbt_base64, signatures).await.unwrap();
        // Bitcoin Core's mempool acceptance validates scripts/signatures independently.
        assert!(node.rpc(&["getmempoolentry", &txid]).is_object());
        let expected = 1_000_000 - draft.total_sats;
        assert_eq!(service.accounts()[0].balance_sats, expected);
        assert_eq!(service.net_worth_history(None, TimeRange::Week).last().unwrap().balance_sats, expected);
        assert_eq!(service.transactions(Some(account.id.clone())).iter().find(|t| t.txid == txid).unwrap().confirmations, 0);
        // The change is spendable before it confirms, with a warning; the funded address is spent.
        let change = service.utxos(Some(account.id.clone()));
        assert_eq!(change.len(), 1);
        let pending = service.draft_transaction(account.id.clone(), receive_address.clone(), 10_000, 2.0, vec![], false).unwrap();
        assert!(pending.warnings.iter().any(|warning| warning.contains("aren't confirmed yet")));
        let spent = &service.addresses(account.id.clone(), Chain::Receive).unwrap()[25];
        assert_eq!((spent.tx_count, spent.balance_sats), (2, 0));
        assert!(service.addresses(account.id.clone(), Chain::Change).unwrap().iter().any(|a| a.balance_sats == change[0].value_sats));
        node.mine();
        for attempt in 0..60 {
            service.sync(Some(account.id.clone())).await.unwrap();
            if service.transactions(Some(account.id.clone())).iter().any(|t| t.txid == txid && t.confirmations > 0) {
                break;
            }
            assert!(attempt < 59, "broadcast did not become confirmed");
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        drop(service);
        let reopened = WalletService::open(path, Network::Regtest, Some(url.clone())).unwrap();
        assert_eq!(reopened.accounts()[0].balance_sats, expected);
        assert_eq!(reopened.net_worth_history(None, TimeRange::AllTime).last().unwrap().balance_sats, expected);
        assert_eq!(reopened.transactions(None).iter().find(|tx| tx.txid == coins[0].txid).unwrap().label.as_deref(), Some("Funding transaction"));
        assert_eq!(reopened.transactions(Some(account.id)).len(), 2);
    }
}
