#[allow(dead_code)]
mod support;

use bdk_wallet::{bitcoin::Network as BitcoinNetwork, KeychainKind, Wallet};
use northvault_core::{Chain, ExportFormat, LabelKind, Network, WalletError, WalletService};
use support::{config, SCRIPTS};

#[test]
fn regtest_wallet_lifecycle_for_every_supported_script() {
    for script in SCRIPTS {
        let dir = tempfile::tempdir().unwrap();
        let service = WalletService::open(dir.path().to_str().unwrap().into(), Network::Regtest, None).unwrap();
        assert!(!service.is_sample());
        assert_eq!(service.network(), Network::Regtest);
        let config = config(script);
        assert_eq!(service.default_derivation_path(script), config.keystores[0].derivation_path);
        let preview = service.preview_wallet(config.clone()).unwrap();
        let account = service.create_wallet(config.clone()).unwrap();
        assert_eq!(account.is_multisig, script.is_multisig());
        assert_eq!(service.accounts().len(), 1);
        assert_eq!(service.total_balance_sats(), 0);
        assert!(service.create_wallet(config.clone()).is_err());
        let details = service.wallet_details(account.id.clone()).unwrap();
        assert_eq!(details.descriptor, preview[0]);
        assert_eq!(details.first_receive_address, preview[1]);

        // A separately loaded BDK watch-only wallet agrees with public API addresses.
        let receive = details.descriptor.replace("/<0;1>/*", "/0/*");
        let change = details.descriptor.replace("/<0;1>/*", "/1/*");
        // Replacing the branches invalidates the original checksum.
        let independent = Wallet::create(receive.split('#').next().unwrap().to_owned(), change.split('#').next().unwrap().to_owned())
            .network(BitcoinNetwork::Regtest)
            .create_wallet_no_persist()
            .unwrap();
        for (chain, keychain) in [(Chain::Receive, KeychainKind::External), (Chain::Change, KeychainKind::Internal)] {
            let addresses = service.addresses(account.id.clone(), chain).unwrap();
            assert!(!addresses.is_empty());
            for address in addresses {
                assert_eq!(address.address, independent.peek_address(keychain, address.index).address.to_string());
            }
        }
        for offset in [0, 1, 19, 25] {
            let address = service.next_receive_address(account.id.clone(), offset).unwrap();
            assert_eq!(address.index, offset);
            assert_eq!(address.address, independent.peek_address(KeychainKind::External, offset).address.to_string());
        }
        for format in [ExportFormat::Descriptor, ExportFormat::Bsms] {
            let exported = service.export_wallet(account.id.clone(), format).unwrap();
            let imported = service.import_wallet(exported, "fixture.txt".into()).unwrap();
            assert_eq!(service.preview_wallet(imported).unwrap(), preview);
        }
        if script.is_multisig() {
            let exported = service.export_wallet(account.id.clone(), ExportFormat::ColdcardMultisig).unwrap();
            let imported = service.import_wallet(exported, "fixture.txt".into()).unwrap();
            assert_eq!(service.preview_wallet(imported).unwrap(), preview);
        }
        let address = details.first_receive_address;
        service.set_label(account.id.clone(), LabelKind::Address, address.clone(), "Regtest receive".into()).unwrap();
        let labels = service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap();
        service.set_label(account.id.clone(), LabelKind::Address, address.clone(), "".into()).unwrap();
        assert_eq!(service.import_labels(account.id.clone(), labels).unwrap(), 1);
        service.rename_wallet(account.id.clone(), "  Renamed fixture  ".into()).unwrap();
        assert!(service.rename_wallet(account.id.clone(), "   ".into()).is_err());
        assert!(service.import_labels(account.id.clone(), vec![0xff]).is_err());
        drop(service);
        let reopened = WalletService::open(dir.path().to_str().unwrap().into(), Network::Regtest, None).unwrap();
        assert_eq!(reopened.accounts()[0].name, "Renamed fixture");
        assert_eq!(reopened.addresses(account.id.clone(), Chain::Receive).unwrap()[0].label.as_deref(), Some("Regtest receive"));
        reopened.delete_wallet(account.id.clone()).unwrap();
        assert!(reopened.accounts().is_empty());
        assert!(matches!(reopened.wallet_details(account.id.clone()), Err(WalletError::UnknownAccount)));
        assert!(matches!(reopened.delete_wallet(account.id), Err(WalletError::UnknownAccount)));
        drop(reopened);
        assert!(WalletService::open(dir.path().to_str().unwrap().into(), Network::Regtest, None).unwrap().accounts().is_empty());
    }
}

#[test]
fn air_gapped_signer_roundtrip_for_every_supported_script() {
    use bdk_wallet::{
        bitcoin::{hashes::Hash, Amount, BlockHash, Psbt},
        chain::BlockId,
        test_utils::{insert_checkpoint, receive_output_in_latest_block},
        SignOptions,
    };
    for script in SCRIPTS {
        let dir = tempfile::tempdir().unwrap();
        let service = WalletService::open(dir.path().to_str().unwrap().into(), Network::Regtest, None).unwrap();
        let account = service.create_wallet(config(script)).unwrap();
        let descriptor = service.wallet_details(account.id.clone()).unwrap().descriptor;
        let branch = |n: u8| descriptor.split('#').next().unwrap().replace("/<0;1>/*", &format!("/{n}/*"));
        let mut source = Wallet::create(branch(0), branch(1)).network(BitcoinNetwork::Regtest).create_wallet_no_persist().unwrap();
        insert_checkpoint(&mut source, BlockId { height: 101, hash: BlockHash::from_byte_array([17; 32]) });
        // Two coins and an amount neither covers alone: every input must be signed by the same signer.
        receive_output_in_latest_block(&mut source, Amount::from_sat(600_000));
        receive_output_in_latest_block(&mut source, Amount::from_sat(600_000));
        let recipient = source.peek_address(KeychainKind::External, 10).address.script_pubkey();
        let mut builder = source.build_tx();
        builder.add_recipient(recipient, Amount::from_sat(700_000));
        let unsigned = builder.finish().unwrap();
        assert_eq!(unsigned.unsigned_tx.input.len(), 2);
        let original = service.psbt_from_file(unsigned.serialize()).unwrap();
        let outgoing = support::qr_roundtrip(&service, original.clone());
        let wrong = support::Signer::new(99).sign(&service.psbt_to_file(outgoing.clone()).unwrap());
        let wrong = service.psbt_from_file(wrong).unwrap();
        assert_eq!(service.signature_status(account.id.clone(), original.clone(), vec![wrong]).unwrap().signatures, 0);
        let mut signed_copies = Vec::new();
        let mut merged = unsigned.clone();
        let required = if script.is_multisig() { 2 } else { 1 };
        for id in 1..=required {
            let signed = support::Signer::new(id).sign(&service.psbt_to_file(outgoing.clone()).unwrap());
            let incoming = support::qr_roundtrip(&service, service.psbt_from_file(signed).unwrap());
            merged.combine(Psbt::deserialize(&service.psbt_to_file(incoming.clone()).unwrap()).unwrap()).unwrap();
            signed_copies.push(incoming);
            let status = service.signature_status(account.id.clone(), original.clone(), signed_copies.clone()).unwrap();
            assert_eq!(status.signatures, u32::from(id));
            assert_eq!(status.required, u32::from(required));
            let mut candidate = merged.clone();
            assert_eq!(source.finalize_psbt(&mut candidate, SignOptions::default()).unwrap(), id == required);
            if id == required {
                // A copy the signer already finalized counts as fully signed.
                let finalized = service.psbt_from_file(candidate.serialize()).unwrap();
                assert_eq!(service.signature_status(account.id.clone(), original.clone(), vec![finalized]).unwrap().signatures, u32::from(required));
                let tx = candidate.extract_tx().unwrap();
                assert_eq!(tx.output, unsigned.unsigned_tx.output);
                assert!(tx.input.iter().all(|i| !i.witness.is_empty() || !i.script_sig.is_empty()));
            }
        }
        // Duplicate QR scans must not count as another signer.
        signed_copies.push(signed_copies[0].clone());
        assert_eq!(service.signature_status(account.id.clone(), original.clone(), signed_copies).unwrap().signatures, u32::from(required));
        let mut substituted = unsigned.clone();
        substituted.unsigned_tx.output[0].value = Amount::from_sat(1);
        let substituted = service.psbt_from_file(substituted.serialize()).unwrap();
        assert!(matches!(service.signature_status(account.id, original, vec![substituted]), Err(WalletError::PsbtMismatch)));
    }
}

#[tokio::test]
async fn regtest_rejects_invalid_setup_and_unavailable_network_without_mutation() {
    let dir = tempfile::tempdir().unwrap();
    let service = WalletService::open(dir.path().to_str().unwrap().into(), Network::Regtest, None).unwrap();
    let valid = config(northvault_core::ScriptType::P2wsh);
    for threshold in [0, 4] {
        let mut invalid = valid.clone();
        invalid.threshold = threshold;
        assert!(service.create_wallet(invalid).is_err());
    }
    let mut duplicate = valid.clone();
    duplicate.keystores[1] = duplicate.keystores[0].clone();
    assert!(service.create_wallet(duplicate).is_err());
    assert!(service.accounts().is_empty());
    let account = service.create_wallet(valid).unwrap();
    assert!(matches!(service.sync(None).await, Err(WalletError::Server { .. })));
    service.set_electrum_server(Some("https://invalid.invalid".into())).unwrap();
    assert!(matches!(service.sync(Some(account.id.clone())).await, Err(WalletError::Server { .. })));
    assert_eq!(service.total_balance_sats(), 0);
    assert!(service.transactions(None).is_empty());
    assert!(service.utxos(None).is_empty());
    assert_eq!(service.max_sendable_sats(account.id.clone(), 1.0, vec![]).unwrap(), 0);
    let address = service.next_receive_address(account.id.clone(), 0).unwrap().address;
    for rate in [0.0, -1.0, f64::NAN, f64::INFINITY, 1001.0] {
        assert!(service.create_transaction(account.id.clone(), address.clone(), 1000, rate, vec![], false).is_err());
    }
    assert!(matches!(service.create_transaction(account.id.clone(), address.clone(), 0, 1.0, vec![], false), Err(WalletError::ZeroAmount)));
    // An output below the dust limit is refused before coin selection.
    assert!(matches!(service.create_transaction(account.id.clone(), address.clone(), 100, 1.0, vec![], false), Err(WalletError::Backend { .. })));
    assert!(service.max_sendable_sats(account.id.clone(), 0.0, vec![]).is_err(), "an invalid fee rate is not a zero balance");
    let unknown = northvault_core::OutPoint { txid: "11".repeat(32), vout: 0 };
    assert!(service.draft_transaction(account.id.clone(), address.clone(), 1000, 1.0, vec![unknown], false).is_err());
    let malformed = northvault_core::OutPoint { txid: "not a txid".into(), vout: 0 };
    assert!(service.draft_transaction(account.id.clone(), address.clone(), 1000, 1.0, vec![malformed], false).is_err());
    // A PSBT without inputs has nobody's signature.
    let empty = bdk_wallet::bitcoin::Psbt::from_unsigned_tx(bdk_wallet::bitcoin::Transaction {
        version: bdk_wallet::bitcoin::transaction::Version::TWO,
        lock_time: bdk_wallet::bitcoin::absolute::LockTime::ZERO,
        input: vec![],
        output: vec![],
    })
    .unwrap();
    let status = service.signature_status(account.id.clone(), service.psbt_from_file(empty.serialize()).unwrap(), vec![]).unwrap();
    assert_eq!((status.signatures, status.required), (0, 2));
    assert!(matches!(service.create_transaction(account.id, address, 1000, 1.0, vec![], false), Err(WalletError::InsufficientFunds { .. })));
}
