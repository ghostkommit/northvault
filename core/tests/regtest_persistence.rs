//! Real temporary Regtest persistence failures through the public wallet API.
#[allow(dead_code)]
mod support;

use northvault_core::{Chain, ExportFormat, LabelKind, Network, ScriptType, WalletError, WalletService};
use std::{fs, path::Path};

#[derive(Clone, Copy)]
enum WriteFault {
    TemporaryWrite,
    AtomicReplace,
}
const FAULTS: [WriteFault; 2] = [WriteFault::TemporaryWrite, WriteFault::AtomicReplace];

// A directory blocks either temporary-file creation or atomic replacement. Restore
// the prior file before checking the public API and a separately reopened service.
fn failed_write<T>(path: &Path, fault: WriteFault, action: impl FnOnce() -> Result<T, WalletError>) -> Result<T, WalletError> {
    let before = fs::read(path).ok();
    let backup = path.with_extension("test-backup");
    let blocker = match fault {
        WriteFault::TemporaryWrite => path.with_extension("tmp"),
        WriteFault::AtomicReplace => {
            if before.is_some() {
                fs::rename(path, &backup).unwrap();
            }
            path.to_owned()
        }
    };
    fs::create_dir(&blocker).unwrap();
    let result = action();
    fs::remove_dir(&blocker).unwrap();
    if matches!(fault, WriteFault::AtomicReplace) && before.is_some() {
        fs::rename(backup, path).unwrap();
    }
    assert_eq!(fs::read(path).ok(), before, "failed write changed persisted data");
    result
}
fn open(path: &Path) -> std::sync::Arc<WalletService> {
    WalletService::open(path.to_str().unwrap().into(), Network::Regtest, None).unwrap()
}

#[test]
fn failed_creation_preserves_accounts_and_allows_retry() {
    for fault in FAULTS {
        let root = tempfile::tempdir().unwrap();
        let service = open(root.path());
        let existing = service.create_wallet(support::config(ScriptType::P2wpkh)).unwrap();
        let config = support::config(ScriptType::P2wsh);
        assert!(failed_write(&root.path().join("regtest/wallets.json"), fault, || service.create_wallet(config.clone())).is_err());
        assert_eq!(service.accounts().len(), 1, "failed creation must not publish an account");
        assert_eq!(service.accounts()[0].id, existing.id);
        assert_eq!(open(root.path()).accounts().len(), 1);
        let created = service.create_wallet(config).expect("retry after write recovery");
        drop(service);
        let reopened = open(root.path());
        assert_eq!(reopened.accounts().len(), 2);
        assert!(reopened.wallet_details(created.id).is_ok());
    }
}

#[test]
fn failed_rename_preserves_live_and_persisted_name() {
    for fault in FAULTS {
        let root = tempfile::tempdir().unwrap();
        let service = open(root.path());
        let account = service.create_wallet(support::config(ScriptType::P2wpkh)).unwrap();
        assert!(
            failed_write(&root.path().join("regtest/wallets.json"), fault, || service.rename_wallet(account.id.clone(), "Uncommitted name".into())).is_err()
        );
        assert_eq!(service.wallet_details(account.id.clone()).unwrap().account.name, account.name);
        assert_eq!(open(root.path()).accounts()[0].name, account.name);
        service.rename_wallet(account.id.clone(), "Recovered name".into()).unwrap();
        drop(service);
        assert_eq!(open(root.path()).accounts()[0].name, "Recovered name");
    }
}

#[test]
fn failed_deletion_preserves_account_order_labels_and_database() {
    for fault in FAULTS {
        let root = tempfile::tempdir().unwrap();
        let service = open(root.path());
        let account = service.create_wallet(support::config(ScriptType::P2wpkh)).unwrap();
        let other = service.create_wallet(support::config(ScriptType::P2wsh)).unwrap();
        let address = service.next_receive_address(account.id.clone(), 0).unwrap().address;
        service.set_label(account.id.clone(), LabelKind::Address, address, "Keep this label".into()).unwrap();
        let labels = service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap();
        let database = root.path().join("regtest").join(format!("{}.sqlite", account.id));
        assert!(failed_write(&root.path().join("regtest/wallets.json"), fault, || service.delete_wallet(account.id.clone())).is_err());
        assert_eq!(service.accounts().iter().map(|a| &a.id).collect::<Vec<_>>(), vec![&account.id, &other.id]);
        assert!(database.is_file(), "failed removal must retain BDK state");
        assert_eq!(service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap(), labels);
        assert_eq!(open(root.path()).export_wallet(account.id.clone(), ExportFormat::Labels).unwrap(), labels);
        service.delete_wallet(account.id.clone()).unwrap();
        assert!(!database.exists());
        drop(service);
        let reopened = open(root.path());
        assert_eq!(reopened.accounts().len(), 1);
        assert_eq!(reopened.accounts()[0].id, other.id);
    }
}

#[test]
fn failed_label_edits_and_imports_preserve_previous_labels() {
    for fault in FAULTS {
        let root = tempfile::tempdir().unwrap();
        let service = open(root.path());
        let account = service.create_wallet(support::config(ScriptType::P2wpkh)).unwrap();
        let address = service.next_receive_address(account.id.clone(), 0).unwrap().address;
        service.set_label(account.id.clone(), LabelKind::Address, address.clone(), "Original label".into()).unwrap();
        let original = service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap();
        let path = root.path().join("regtest").join(format!("{}.labels.jsonl", account.id));
        for replacement in ["Uncommitted label", ""] {
            assert!(failed_write(&path, fault, || service.set_label(account.id.clone(), LabelKind::Address, address.clone(), replacement.into())).is_err());
            assert_eq!(service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap(), original);
        }
        let imported = serde_json::to_vec(&serde_json::json!({"type":"addr", "ref":address, "label":"Imported label"})).unwrap();
        assert!(failed_write(&path, fault, || service.import_labels(account.id.clone(), imported.clone())).is_err());
        assert_eq!(service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap(), original);
        assert_eq!(open(root.path()).export_wallet(account.id.clone(), ExportFormat::Labels).unwrap(), original);
        assert_eq!(service.import_labels(account.id.clone(), imported).unwrap(), 1);
        drop(service);
        assert_eq!(open(root.path()).addresses(account.id, Chain::Receive).unwrap()[0].label.as_deref(), Some("Imported label"));
    }
}

#[test]
fn malformed_label_import_does_not_apply_valid_prefix() {
    let root = tempfile::tempdir().unwrap();
    let service = open(root.path());
    let account = service.create_wallet(support::config(ScriptType::P2wpkh)).unwrap();
    let address = service.next_receive_address(account.id.clone(), 0).unwrap().address;
    service.set_label(account.id.clone(), LabelKind::Address, address.clone(), "Original label".into()).unwrap();
    let original = service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap();
    let prefix = serde_json::to_string(&serde_json::json!({"type":"addr", "ref":address, "label":"Rejected prefix"})).unwrap();
    for suffix in ["not JSON", r#"{"type":"unknown","ref":"fixture","label":"bad"}"#, r#"{"type":"addr","label":"missing reference"}"#] {
        assert!(service.import_labels(account.id.clone(), format!("{prefix}\n{suffix}\n").into_bytes()).is_err());
        assert_eq!(service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap(), original);
    }
    // An unrelated later write must not commit the rejected import's valid prefix.
    service.set_label(account.id.clone(), LabelKind::Output, "synthetic-output:0".into(), "Independent label".into()).unwrap();
    drop(service);
    assert_eq!(open(root.path()).addresses(account.id, Chain::Receive).unwrap()[0].label.as_deref(), Some("Original label"));
}

#[test]
fn first_writes_fail_without_publishing_and_can_be_retried() {
    for fault in FAULTS {
        let root = tempfile::tempdir().unwrap();
        let service = open(root.path());
        let config = support::config(ScriptType::P2wpkh);
        let registry = root.path().join("regtest/wallets.json");
        assert!(failed_write(&registry, fault, || service.create_wallet(config.clone())).is_err());
        assert!(!registry.exists());
        assert!(service.accounts().is_empty());
        assert!(open(root.path()).accounts().is_empty());
        let account = service.create_wallet(config).unwrap();
        let address = service.next_receive_address(account.id.clone(), 0).unwrap().address;
        let labels = root.path().join("regtest").join(format!("{}.labels.jsonl", account.id));
        assert!(failed_write(&labels, fault, || service.set_label(account.id.clone(), LabelKind::Address, address.clone(), "First label".into())).is_err());
        assert!(!labels.exists());
        assert!(service.export_wallet(account.id.clone(), ExportFormat::Labels).unwrap().is_empty());
        service.set_label(account.id.clone(), LabelKind::Address, address, "First label".into()).unwrap();
        drop(service);
        assert_eq!(open(root.path()).addresses(account.id, Chain::Receive).unwrap()[0].label.as_deref(), Some("First label"));
    }
}

#[test]
fn test_networks_with_identical_public_keys_have_isolated_persistence() {
    let root = tempfile::tempdir().unwrap();
    let networks = [Network::Regtest, Network::Signet, Network::Testnet, Network::Testnet4];
    let mut shared_id = None;
    for network in networks {
        let service = WalletService::open(root.path().to_str().unwrap().into(), network, None).unwrap();
        assert!(service.accounts().is_empty());
        let mut config = support::config(ScriptType::P2wpkh);
        config.name = format!("Synthetic {network:?}");
        let account = service.create_wallet(config).unwrap();
        if let Some(id) = &shared_id {
            assert_eq!(&account.id, id);
        }
        shared_id = Some(account.id.clone());
        let address = service.next_receive_address(account.id.clone(), 0).unwrap().address;
        assert_eq!(address.starts_with("bcrt1"), network == Network::Regtest);
        service.set_label(account.id, LabelKind::Address, address, format!("Label {network:?}")).unwrap();
    }
    let regtest = open(root.path());
    regtest.delete_wallet(shared_id.clone().unwrap()).unwrap();
    drop(regtest);
    assert!(open(root.path()).accounts().is_empty());
    for network in [Network::Signet, Network::Testnet, Network::Testnet4] {
        let service = WalletService::open(root.path().to_str().unwrap().into(), network, None).unwrap();
        assert_eq!(service.network(), network);
        assert_eq!(service.accounts().len(), 1);
        assert_eq!(service.accounts()[0].name, format!("Synthetic {network:?}"));
        assert_eq!(service.addresses(shared_id.clone().unwrap(), Chain::Receive).unwrap()[0].label, Some(format!("Label {network:?}")));
    }
}
