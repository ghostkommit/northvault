//! Test-only persisted Regtest data for the native Swift UI integration runner.
//! Uses simulated chain observations, not consensus-valid funding or real funds.
#[allow(dead_code)]
#[path = "../tests/support/mod.rs"]
mod support;

use std::{path::PathBuf, time::SystemTime};

use bdk_wallet::{
    bitcoin::{absolute, hashes::Hash, transaction, Amount, BlockHash, OutPoint, Transaction, TxIn, TxOut, Txid},
    chain::{BlockId, ConfirmationBlockTime},
    rusqlite::Connection,
    test_utils::{insert_anchor, insert_checkpoint, insert_tx},
    KeychainKind, Wallet,
};
use northvault_core::{Chain, LabelKind, Network, ScriptType, WalletService};

fn main() {
    let root = PathBuf::from(std::env::args_os().nth(1).expect("fresh fixture directory required"));
    // Refuse to open or alter any existing wallet directory.
    std::fs::create_dir(&root).expect("fixture directory must not already exist");
    let path = root.to_str().unwrap().to_owned();
    let service = WalletService::open(path.clone(), Network::Regtest, None).unwrap();
    let mut config = support::config(ScriptType::P2wpkh);
    config.name = "Regtest savings".into();
    let account = service.create_wallet(config).unwrap();
    let mut reserve = support::config(ScriptType::P2wsh);
    reserve.name = "Regtest reserve".into();
    let empty = service.create_wallet(reserve).unwrap();
    let descriptor = service.wallet_details(account.id.clone()).unwrap().descriptor;
    drop(service);

    let branch = |n| descriptor.split('#').next().unwrap().replace("/<0;1>/*", &format!("/{n}/*"));
    let mut connection = Connection::open(root.join("regtest").join(format!("{}.sqlite", account.id))).unwrap();
    let mut wallet = Wallet::load()
        .descriptor(KeychainKind::External, Some(branch(0)))
        .descriptor(KeychainKind::Internal, Some(branch(1)))
        .check_network(bdk_wallet::bitcoin::Network::Regtest)
        .load_wallet(&mut connection)
        .unwrap()
        .unwrap();
    let block = BlockId { height: 101, hash: BlockHash::from_byte_array([41; 32]) };
    insert_checkpoint(&mut wallet, block);
    let now = SystemTime::UNIX_EPOCH.elapsed().unwrap().as_secs();
    let amounts = [125_000_000, 12_500_000];
    let mut ids = Vec::new();
    for (index, amount) in amounts.into_iter().enumerate() {
        let address = wallet.peek_address(KeychainKind::External, index as u32).address;
        let transaction = Transaction {
            version: transaction::Version::TWO,
            lock_time: absolute::LockTime::ZERO,
            input: vec![TxIn { previous_output: OutPoint::new(Txid::from_byte_array([index as u8 + 5; 32]), 0), ..Default::default() }],
            output: vec![TxOut { value: Amount::from_sat(amount), script_pubkey: address.script_pubkey() }],
        };
        let txid = transaction.compute_txid();
        insert_tx(&mut wallet, transaction);
        if index == 0 {
            insert_anchor(&mut wallet, txid, ConfirmationBlockTime { block_id: block, confirmation_time: now - 86_400 });
        }
        ids.push(txid.to_string());
    }
    wallet.persist(&mut connection).unwrap();
    drop(wallet);
    drop(connection);

    let service = WalletService::open(path, Network::Regtest, None).unwrap();
    assert_eq!(service.total_balance_sats(), 137_500_000);
    assert_eq!(service.transactions(Some(account.id.clone())).len(), 2);
    assert_eq!(service.utxos(Some(account.id.clone())).len(), 2);
    for (index, txid) in ids.iter().enumerate() {
        let label = if index == 0 { "Confirmed fixture" } else { "Pending fixture" };
        service.set_label(account.id.clone(), LabelKind::Transaction, txid.clone(), label.into()).unwrap();
        service.set_label(account.id.clone(), LabelKind::Output, format!("{txid}:0"), label.into()).unwrap();
    }
    let addresses = service.addresses(account.id.clone(), Chain::Receive).unwrap();
    service.set_label(account.id.clone(), LabelKind::Address, addresses[0].address.clone(), "Used fixture address".into()).unwrap();
    let manifest = serde_json::json!({
        "fundedAccount": account.id, "emptyAccount": empty.id,
        "balanceSats": 137_500_000_u64, "confirmedSats": 125_000_000_u64, "pendingSats": 12_500_000_u64,
        "nextAddress": service.next_receive_address(account.id.clone(), 0).unwrap().address
    });
    std::fs::write(root.join("ui-fixture.json"), serde_json::to_vec(&manifest).unwrap()).unwrap();
}
