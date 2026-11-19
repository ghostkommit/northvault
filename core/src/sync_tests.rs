//! End-to-end sync against a in-memory Electrum protocol fixture. No real wallet data.
use std::{
    collections::{HashMap, VecDeque},
    io::{Read, Write},
};

use bdk_wallet::{
    bitcoin::{
        self, absolute,
        consensus::encode::serialize_hex,
        hashes::{sha256, Hash},
        transaction, Amount, OutPoint, ScriptBuf, Transaction, TxIn, TxOut,
    },
    KeychainKind,
};
use serde_json::{json, Value};

use crate::{wallet::test_keys, Network, ScriptType, WalletConfig, WalletService};

fn script_hash(script: &ScriptBuf) -> String {
    let mut bytes = sha256::Hash::hash(script.as_bytes()).to_byte_array();
    bytes.reverse();
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn discovery_persists_receive_and_change_history_when_fee_rpc_fails() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_str().unwrap().to_owned();
    let service = WalletService::open(path.clone(), Network::Regtest, None).unwrap();
    let account = service
        .create_wallet(WalletConfig {
            name: "Discovery fixture".into(),
            script_type: ScriptType::P2wpkh,
            threshold: 1,
            keystores: vec![test_keys::keystore_on_network(42, ScriptType::P2wpkh, Network::Regtest)],
        })
        .unwrap();
    let (receive, change) = service
        .live()
        .unwrap()
        .with_account(&account.id, |a| {
            Ok((
                a.wallet.peek_address(KeychainKind::External, 3).address.script_pubkey(),
                a.wallet.peek_address(KeychainKind::Internal, 2).address.script_pubkey(),
            ))
        })
        .unwrap();
    let funding = Transaction {
        version: transaction::Version::TWO,
        lock_time: absolute::LockTime::ZERO,
        input: vec![TxIn::default()],
        output: vec![TxOut { value: Amount::from_sat(100_000), script_pubkey: ScriptBuf::new() }],
    };
    let received = Transaction {
        input: vec![TxIn { previous_output: OutPoint::new(funding.compute_txid(), 0), ..TxIn::default() }],
        output: vec![TxOut { value: Amount::from_sat(90_000), script_pubkey: receive.clone() }],
        ..funding.clone()
    };
    let spent = Transaction {
        input: vec![TxIn { previous_output: OutPoint::new(received.compute_txid(), 0), ..TxIn::default() }],
        output: vec![TxOut { value: Amount::from_sat(30_000), script_pubkey: change.clone() }],
        ..funding.clone()
    };
    let expected = [received.compute_txid().to_string(), spent.compute_txid().to_string()];
    let histories = HashMap::from([
        (script_hash(&receive), json!([{"tx_hash": expected[0], "height": 1}, {"tx_hash": expected[1], "height": 0}])),
        (script_hash(&change), json!([{"tx_hash": expected[1], "height": 0}])),
    ]);
    let genesis = bitcoin::blockdata::constants::genesis_block(bitcoin::Network::Regtest).header;
    let confirmed_header = bitcoin::block::Header {
        prev_blockhash: genesis.block_hash(),
        merkle_root: bitcoin::TxMerkleNode::from_raw_hash(received.compute_txid().to_raw_hash()),
        time: genesis.time + 600,
        ..genesis
    };
    let headers = [serialize_hex(&genesis), serialize_hex(&confirmed_header)];
    let txs: HashMap<_, _> = [funding, received, spent].into_iter().map(|tx| (tx.compute_txid().to_string(), serialize_hex(&tx))).collect();
    let client = bdk_electrum::BdkElectrumClient::new(bdk_electrum::electrum_client::raw_client::RawClient::from(Fixture {
        histories,
        txs,
        headers,
        pending: Vec::new(),
        responses: VecDeque::new(),
    }));
    let requests = service
        .live()
        .unwrap()
        .accounts()
        .iter()
        .map(|a| (a.id().to_owned(), a.wallet.start_full_scan().build(), a.wallet.start_sync_with_revealed_spks().build()))
        .collect();
    let discovery = crate::chain::electrum::discover(&client, requests).unwrap();
    assert!(discovery.fees.is_err());
    service.live().unwrap().apply_discovery(discovery).unwrap();
    let history = service.transactions(Some(account.id.clone()));
    assert_eq!(history.len(), 2);
    assert_eq!(history.iter().find(|tx| tx.txid == expected[0]).unwrap().confirmations, 1);
    assert_eq!(history.iter().find(|tx| tx.txid == expected[1]).unwrap().confirmations, 0);
    for txid in expected {
        assert!(history.iter().any(|tx| tx.txid == txid));
    }
    assert_eq!(service.accounts()[0].balance_sats, 30_000);
    let all = service.net_worth_history(Some(account.id.clone()), crate::TimeRange::AllTime);
    let oldest = history.iter().map(|tx| tx.timestamp).min().unwrap();
    assert_eq!(all.first().unwrap().timestamp.div_euclid(86_400), oldest.div_euclid(86_400));
    assert_eq!(all.last().unwrap().balance_sats, 30_000);
    assert_eq!(all.last().unwrap().btc_price_usd, service.btc_price_usd());
    assert!(all.iter().all(|point| point.btc_price_usd > 0.0));
    drop(service);
    let reopened = WalletService::open(path, Network::Regtest, None).unwrap();
    assert_eq!(reopened.transactions(Some(account.id)).len(), 2);
    assert_eq!(reopened.accounts()[0].balance_sats, 30_000);
}

// Real electrum-client parsing and BDK scanning, with deterministic RPC responses.
struct Fixture {
    histories: HashMap<String, Value>,
    txs: HashMap<String, String>,
    headers: [String; 2],
    pending: Vec<u8>,
    responses: VecDeque<u8>,
}
impl Read for Fixture {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        let n = output.len().min(self.responses.len());
        for byte in &mut output[..n] {
            *byte = self.responses.pop_front().unwrap();
        }
        Ok(n)
    }
}
impl Write for Fixture {
    fn write(&mut self, input: &[u8]) -> std::io::Result<usize> {
        self.pending.extend_from_slice(input);
        while let Some(end) = self.pending.iter().position(|b| *b == b'\n') {
            let line: Vec<_> = self.pending.drain(..=end).collect();
            let request: Value = serde_json::from_slice(&line).unwrap();
            let requests = request.as_array().cloned().unwrap_or_else(|| vec![request]);
            for request in requests {
                let result = match request["method"].as_str().unwrap() {
                    "server.version" => json!(["fixture", "1.4"]),
                    "blockchain.headers.subscribe" => json!({"height": 1, "hex": self.headers[1]}),
                    "blockchain.block.headers" => {
                        json!({"count": 2, "hex": self.headers.concat(), "max": 2016})
                    }
                    "blockchain.scripthash.get_history" => self.histories.get(request["params"][0].as_str().unwrap()).cloned().unwrap_or(json!([])),
                    "blockchain.transaction.get" => {
                        json!(self.txs[request["params"][0].as_str().unwrap()])
                    }
                    "blockchain.block.header" => {
                        json!(self.headers[request["params"][0].as_u64().unwrap() as usize])
                    }
                    "blockchain.transaction.get_merkle" => {
                        json!({"block_height": 1, "pos": 0, "merkle": []})
                    }
                    "blockchain.relayfee" => json!(0.00001),
                    "blockchain.estimatefee" => {
                        self.responses.extend(
                            format!("{}\n", json!({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "fee estimation unavailable"}}))
                                .bytes(),
                        );
                        continue;
                    }
                    other => panic!("unexpected Electrum RPC: {other}"),
                };
                self.responses.extend(format!("{}\n", json!({"jsonrpc": "2.0", "id": request["id"], "result": result})).bytes());
            }
        }
        Ok(input.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
