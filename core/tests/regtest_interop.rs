//! Import/export boundaries through the public service API: every wallet file,
//! keystore, descriptor and PSBT here is untrusted input. Synthetic keys only.
#[allow(dead_code)]
mod support;

use bdk_wallet::bitcoin::{absolute, base58, transaction, Amount, Psbt, ScriptBuf, Transaction, TxIn, TxOut};
use northvault_core::{DeviceKind, ExportFormat, Keystore, Network, ScriptType, UrDecoder, WalletConfig, WalletError, WalletService};
use support::{config, Signer, SCRIPTS};

// BIP84 test vector (mnemonic "abandon … about"); public data only.
const ZPUB: &str = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs";
const XPRV: &str = "xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi";

fn regtest() -> (tempfile::TempDir, std::sync::Arc<WalletService>) {
    let dir = tempfile::tempdir().unwrap();
    let service = WalletService::open(dir.path().to_str().unwrap().into(), Network::Regtest, None).unwrap();
    (dir, service)
}

/// The sample backend validates setups for mainnet without touching storage.
fn mainnet() -> std::sync::Arc<WalletService> {
    WalletService::new_sample()
}

fn single(script: ScriptType, keystore: Keystore) -> WalletConfig {
    WalletConfig { name: "Fixture".into(), script_type: script, threshold: 1, keystores: vec![keystore] }
}

fn interop<T: std::fmt::Debug>(result: Result<T, WalletError>, expected: &str) {
    match result {
        Err(WalletError::Interop { message }) => assert!(message.contains(expected), "{message}"),
        other => panic!("expected an interop error containing {expected:?}, got {other:?}"),
    }
}

fn invalid<T: std::fmt::Debug>(result: Result<T, WalletError>, expected: &str) {
    match result {
        Err(WalletError::InvalidConfig { message }) => assert!(message.contains(expected), "{message}"),
        other => panic!("expected a setup error containing {expected:?}, got {other:?}"),
    }
}

fn psbt(outputs: usize) -> Psbt {
    Psbt::from_unsigned_tx(Transaction {
        version: transaction::Version::TWO,
        lock_time: absolute::LockTime::ZERO,
        input: vec![TxIn::default()],
        output: vec![TxOut { value: Amount::from_sat(1_000), script_pubkey: ScriptBuf::from_bytes(vec![0x51; 30]) }; outputs],
    })
    .unwrap()
}

#[test]
fn extended_keys_are_validated_for_format_secrecy_and_network() {
    let (_dir, service) = regtest();
    let key = Signer::new(1).keystore(ScriptType::P2wpkh);
    let with = |change: &dyn Fn(&mut Keystore)| {
        let mut keystore = key.clone();
        change(&mut keystore);
        service.preview_wallet(single(ScriptType::P2wpkh, keystore))
    };

    // Mainnet SLIP-132 keys are canonicalized and derive the published BIP84 address.
    let vector = Keystore { fingerprint: "73C5DA0A".into(), derivation_path: "84h/0h/0h".into(), xpub: ZPUB.into(), ..key.clone() };
    let preview = mainnet().preview_wallet(single(ScriptType::P2wpkh, vector.clone())).unwrap();
    assert!(preview[0].starts_with("wpkh([73c5da0a/84'/0'/0']xpub"), "{}", preview[0]);
    assert_eq!(preview[1], "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu");
    assert!(matches!(service.preview_wallet(single(ScriptType::P2wpkh, vector)), Err(WalletError::WrongNetwork)));
    assert!(matches!(mainnet().preview_wallet(single(ScriptType::P2wpkh, key.clone())), Err(WalletError::WrongNetwork)));

    assert!(matches!(with(&|k| k.xpub = XPRV.into()), Err(WalletError::PrivateKeyNotAllowed)));
    invalid(with(&|k| k.xpub = "not base58".into()), "not a valid extended public key");
    // A checksummed payload of the wrong length (a legacy address).
    invalid(with(&|k| k.xpub = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2".into()), "not a valid extended public key");
    let mut unknown = base58::decode_check(&key.xpub).unwrap();
    unknown[..4].copy_from_slice(&[1, 2, 3, 4]);
    invalid(with(&|k| k.xpub = base58::encode_check(&unknown)), "unknown extended key version");
    // A recognized version over bytes that are not a valid public key.
    let mut corrupt = base58::decode_check(&key.xpub).unwrap();
    corrupt[45] = 0x07;
    invalid(with(&|k| k.xpub = base58::encode_check(&corrupt)), "");

    invalid(with(&|k| k.fingerprint = "abc".into()), "fingerprint must be 8 hex characters");
    invalid(with(&|k| k.fingerprint = "zzzzzzzz".into()), "fingerprint must be 8 hex characters");
    invalid(with(&|k| k.derivation_path = "m/84'/x".into()), "invalid derivation path");
    invalid(with(&|k| k.derivation_path = "m/84'/1'".into()), "doesn't match the key's depth");
}

#[test]
fn wallet_policies_reject_unsupported_shapes_before_saving() {
    let (_dir, service) = regtest();
    let key = |id| Signer::new(id).keystore(ScriptType::P2wsh);
    let multisig = |threshold, keys: Vec<Keystore>| WalletConfig { name: "Vault".into(), script_type: ScriptType::P2wsh, threshold, keystores: keys };

    let mut unnamed = config(ScriptType::P2wpkh);
    unnamed.name = "  ".into();
    invalid(service.create_wallet(unnamed), "give the wallet a name");
    invalid(service.create_wallet(multisig(1, vec![])), "multisig needs 1 to 20 keys");
    invalid(service.create_wallet(multisig(1, (1..=21).map(key).collect())), "multisig needs 1 to 20 keys");
    let mut legacy = config(ScriptType::P2sh);
    legacy.keystores = (1..=16).map(|id| Signer::new(id).keystore(ScriptType::P2sh)).collect();
    invalid(service.create_wallet(legacy), "multisig needs 1 to 15 keys");
    invalid(service.create_wallet(multisig(0, vec![key(1)])), "required signatures");
    invalid(service.create_wallet(multisig(3, vec![key(1), key(2)])), "required signatures");
    invalid(service.create_wallet(multisig(1, vec![key(1), key(1)])), "the same key was added twice");
    let mut two_keys = single(ScriptType::P2wpkh, Signer::new(1).keystore(ScriptType::P2wpkh));
    two_keys.keystores.push(Signer::new(2).keystore(ScriptType::P2wpkh));
    invalid(service.create_wallet(two_keys), "exactly one key");
    let mut threshold = config(ScriptType::P2wpkh);
    threshold.threshold = 2;
    invalid(service.create_wallet(threshold), "exactly one key");
    assert!(service.accounts().is_empty());

    // Paths may be written without `m/`, and unhardened steps are preserved.
    let unhardened = Signer::new(1).keystore_at("m/45'/7");
    let imported = service.import_keystore(format!("[{}/45h/7]{}/<0;1>/*", unhardened.fingerprint, unhardened.xpub).into_bytes(), ScriptType::P2wsh).unwrap();
    assert_eq!(imported.derivation_path, "m/45'/7");
    // A master key has an empty origin path, which a descriptor cannot express here.
    let master = Signer::new(1).keystore_at("m");
    for path in ["m", "M/", ""] {
        let keystore = Keystore { derivation_path: path.into(), ..master.clone() };
        assert!(service.preview_wallet(single(ScriptType::P2wpkh, keystore)).is_err());
    }
}

#[test]
fn keystore_imports_accept_public_exports_and_reject_everything_else() {
    let (_dir, service) = regtest();
    let import = |text: &str, script| service.import_keystore(text.as_bytes().to_vec(), script);
    let key = Signer::new(1).keystore(ScriptType::P2wpkh);
    let cosigner = Signer::new(1).keystore(ScriptType::P2wsh);

    let expression = format!("  [{}/84'/1'/0']{}\n", key.fingerprint.to_uppercase(), key.xpub);
    let imported = import(&expression, ScriptType::P2wpkh).unwrap();
    assert_eq!(
        (imported.fingerprint.as_str(), imported.derivation_path.as_str(), imported.xpub.as_str()),
        (key.fingerprint.as_str(), "m/84'/1'/0'", key.xpub.as_str())
    );
    assert_eq!(imported.device, None);
    assert!(import(&format!("[{}/48'/1'/0'/2']{}", cosigner.fingerprint, cosigner.xpub), ScriptType::P2wsh).is_ok());
    // The origin depth is checked at import, not only when the wallet is created.
    invalid(import(&format!("[{}/84'/1']{}", key.fingerprint, key.xpub), ScriptType::P2wpkh), "doesn't match the key's depth");
    invalid(import(&format!("[{}]{}", key.fingerprint, key.xpub), ScriptType::P2wpkh), "doesn't match the key's depth");

    assert!(matches!(service.import_keystore(vec![0xff, 0xfe], ScriptType::P2wpkh), Err(WalletError::Interop { .. })));
    assert!(matches!(import(XPRV, ScriptType::P2wpkh), Err(WalletError::PrivateKeyNotAllowed)));
    interop(import(&key.xpub, ScriptType::P2wpkh), "expected [fingerprint/path]xpub");
    interop(import(&format!("[{}/84'/1'/0'{}", key.fingerprint, key.xpub), ScriptType::P2wpkh), "expected [fingerprint/path]xpub");
    assert!(matches!(mainnet().import_keystore(expression.into_bytes(), ScriptType::P2wpkh), Err(WalletError::WrongNetwork)));

    // Coldcard generic export nests keys per BIP; its multisig export is flat.
    let generic = format!(r#"{{"xfp": "{}", "bip84": {{"xpub": "{}", "deriv": "m/84'/1'/0'"}}}}"#, key.fingerprint.to_uppercase(), key.xpub);
    let imported = import(&generic, ScriptType::P2wpkh).unwrap();
    assert_eq!((imported.fingerprint, imported.xpub, imported.device), (key.fingerprint.clone(), key.xpub.clone(), Some(DeviceKind::Coldcard)));
    for script in [ScriptType::P2pkh, ScriptType::P2shP2wpkh, ScriptType::P2tr, ScriptType::P2sh, ScriptType::P2shP2wsh, ScriptType::P2wsh] {
        interop(import(&generic, script), "no key for the selected script type");
    }
    let flat = format!(r#"{{"xfp": "{}", "p2wsh": "{}", "p2wsh_deriv": "m/48'/1'/0'/2'"}}"#, cosigner.fingerprint, cosigner.xpub);
    assert_eq!(import(&flat, ScriptType::P2wsh).unwrap().derivation_path, "m/48'/1'/0'/2'");
    interop(import(&flat, ScriptType::P2shP2wsh), "no key for the selected script type");
    interop(import(&flat, ScriptType::P2wpkh), "no key for the selected script type");
    interop(import(r#"{"bip84": {}}"#, ScriptType::P2wpkh), "missing xfp");
    interop(import("{not json", ScriptType::P2wpkh), "");
    invalid(import(&generic.replace(&key.fingerprint.to_uppercase(), "12"), ScriptType::P2wpkh), "fingerprint");
    invalid(import(&generic.replace("m/84'/1'/0'", "m/x"), ScriptType::P2wpkh), "invalid derivation path");
    assert!(matches!(mainnet().import_keystore(generic.into_bytes(), ScriptType::P2wpkh), Err(WalletError::WrongNetwork)));
}

/// Air-gapped single-sig key exports as each device writes them. Keys are the
/// public BIP39 "abandon … about" test vectors, never a real wallet.
#[test]
fn air_gapped_device_key_exports_import_for_their_own_script_only() {
    const XPUB: &str = "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V";
    let service = mainnet();
    let import = |text: &str, script| service.import_keystore(text.as_bytes().to_vec(), script);
    let abandon = |keystore: Keystore| {
        assert_eq!((keystore.fingerprint.as_str(), keystore.derivation_path.as_str(), keystore.xpub.as_str()), ("73c5da0a", "m/84'/0'/0'", XPUB));
        assert_eq!(keystore.device, None);
    };

    // Jade: checksummed descriptor with an xpub.
    let jade = format!("wpkh([73c5da0a/84'/0'/0']{XPUB}/0/*)#wc3n3van\n");
    abandon(import(&jade, ScriptType::P2wpkh).unwrap());
    for other in [ScriptType::P2tr, ScriptType::P2shP2wpkh, ScriptType::P2pkh, ScriptType::P2wsh] {
        interop(import(&jade, other), "different script type");
    }
    interop(import(&jade.replace("#wc3n3van", "#wc3n3vaq"), ScriptType::P2wpkh), "checksum doesn't match");
    interop(import(&jade.replace("73c5da0a", "73c5da0b"), ScriptType::P2wpkh), "checksum doesn't match");

    // Keystone: no checksum, upper-case fingerprint, SLIP-132 key, change branch.
    let keystone = format!("wpkh([73C5DA0A/84'/0'/0']{ZPUB}/1/*)");
    abandon(import(&keystone, ScriptType::P2wpkh).unwrap());
    abandon(import(&keystone.replace("/1/*", ""), ScriptType::P2wpkh).unwrap());
    interop(import(&keystone, ScriptType::P2shP2wpkh), "different script type");
    interop(import(&keystone.replace("wpkh(", "sh(wpkh(").replace("*)", "*))"), ScriptType::P2wpkh), "different script type");
    interop(import(&format!("wpkh({ZPUB}/0/*)"), ScriptType::P2wpkh), "different script type");

    // Cobo Vault and Keystone JSON.
    let cobo =
        format!(r#"{{"ExtPubKey": "{ZPUB}", "MasterFingerprint": "73C5DA0A", "AccountKeyPath": "84'/0'/0'", "CoboVaultFirmwareVersion": "1.7.1(BTC-Only)"}}"#);
    abandon(import(&cobo, ScriptType::P2wpkh).unwrap());
    for other in [ScriptType::P2shP2wpkh, ScriptType::P2tr, ScriptType::P2wsh] {
        interop(import(&cobo, other), "no key for the selected script type");
    }
    interop(import(&cobo.replace("MasterFingerprint", "Fingerprint"), ScriptType::P2wpkh), "missing MasterFingerprint");
    interop(import(&cobo.replace("AccountKeyPath", "Path"), ScriptType::P2wpkh), "missing AccountKeyPath");
    assert!(matches!(import(&cobo.replace(ZPUB, XPRV), ScriptType::P2wpkh), Err(WalletError::PrivateKeyNotAllowed)));

    // Specter DIY: bare key expression with `h` markers and a testnet SLIP-132 key.
    let (_dir, regtest) = regtest();
    let specter = "[b317ec86/84h/1h/0h]vpub5YHLPnkkpPW1ecL7Di7Gv2wDHDtBNqRdt17gMULpxJ27ZA1MmW7xbZjdg1S7d5JKaJ8CiZEmRUHrEB6CGuLomA6ioVa1Pcke6fEb5CzDBU1";
    let imported = regtest.import_keystore(specter.as_bytes().to_vec(), ScriptType::P2wpkh).unwrap();
    assert_eq!((imported.fingerprint.as_str(), imported.derivation_path.as_str()), ("b317ec86", "m/84'/1'/0'"));
    assert!(imported.xpub.starts_with("tpub"));
    assert!(matches!(import(specter, ScriptType::P2wpkh), Err(WalletError::WrongNetwork)));
    for device_export in [jade, keystone, cobo] {
        assert!(matches!(regtest.import_keystore(device_export.into_bytes(), ScriptType::P2wpkh), Err(WalletError::WrongNetwork)));
    }
}

#[test]
fn descriptor_imports_must_reproduce_the_same_addresses() {
    let (_dir, service) = regtest();
    let import = |text: &str| service.import_wallet(text.as_bytes().to_vec(), "/tmp/My wallet.txt".into());
    for script in SCRIPTS {
        let expected = service.preview_wallet(config(script)).unwrap();
        let descriptor = &expected[0];
        let imported = import(&format!("# exported elsewhere\n\nnot a descriptor\n{descriptor}\n")).unwrap();
        assert_eq!(imported.name, "My wallet");
        assert_eq!(service.preview_wallet(imported).unwrap(), expected);
        // A Bitcoin Core receive descriptor is widened to the same receive/change pair.
        let receive = descriptor.split('#').next().unwrap().replace("/<0;1>/*", "/0/*");
        assert_eq!(service.preview_wallet(import(&receive).unwrap()).unwrap(), expected);
        interop(import(&receive.replace("/0/*", "/1/*")), "descriptor must use /0/*");
        // Other branch numbers would silently watch different addresses.
        interop(import(&descriptor.split('#').next().unwrap().replace("/<0;1>/*", "/<2;3>/*")), "addresses don't match");
        invalid(import(&descriptor.split('#').next().unwrap().replace("/<0;1>/*", "/<0;1;2>/*")), "expected a receive and a change path");
        assert!(matches!(mainnet().import_wallet(descriptor.clone().into_bytes(), "wallet.txt".into()), Err(WalletError::WrongNetwork)));
    }

    let key = Signer::new(1).keystore(ScriptType::P2wsh);
    let origin = format!("[{}/48h/1h/0h/2h]{}/<0;1>/*", key.fingerprint, key.xpub);
    let bare = format!("{}/<0;1>/*", Signer::new(2).keystore(ScriptType::P2wsh).xpub);
    let single_key = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";
    interop(import(&format!("wpkh({bare})")), "every key needs its origin");
    interop(import(&format!("wsh(sortedmulti(1,{origin},{bare}))")), "every key needs its origin");
    interop(import(&format!("wsh(sortedmulti(1,{origin},{single_key}))")), "every key needs its origin");
    // `multi` has different address semantics from `sortedmulti` and is not substituted.
    interop(import(&format!("wsh(multi(1,{origin}))")), "only single-sig and sortedmulti");
    interop(import(&format!("wsh(pk({origin}))")), "only single-sig and sortedmulti");
    assert!(matches!(import(&format!("# comment\nwpkh({XPRV}/0/*)")), Err(WalletError::PrivateKeyNotAllowed)));
    interop(import("# only a comment\n\n"), "no descriptor found");
    interop(import("first bad line\nsecond bad line"), "not a descriptor");
    interop(service.import_wallet(vec![0xff, 0xfe], "wallet.txt".into()), "not a text file");
}

#[test]
fn multisig_setup_files_and_bsms_records_are_checked_field_by_field() {
    let (_dir, service) = regtest();
    let import = |text: &str| service.import_wallet(text.as_bytes().to_vec(), "vault.txt".into());
    for script in [ScriptType::P2sh, ScriptType::P2shP2wsh, ScriptType::P2wsh] {
        let mut named = config(script);
        named.name = "A multisig vault with a very long name".into();
        let account = service.create_wallet(named.clone()).unwrap();
        let expected = service.preview_wallet(named).unwrap();
        let setup = String::from_utf8(service.export_wallet(account.id.clone(), ExportFormat::ColdcardMultisig).unwrap()).unwrap();
        assert!(setup.contains("Name: A multisig vault wit\n"), "Coldcard names are limited to 20 characters");
        let imported = import(&setup).unwrap();
        assert_eq!((imported.name.as_str(), imported.threshold, imported.keystores.len()), ("A multisig vault wit", 2, 3));
        assert_eq!(service.preview_wallet(imported).unwrap()[1..], expected[1..]);
        // Other coordinators write the policy as "2/3", lowercase keys and unknown headers.
        let variant = setup.replace("Policy: 2 of 3", "policy: 2/3\nFirmware: ignored").replace("Name: A multisig vault wit\n", "");
        assert_eq!(import(&variant).unwrap().name, "Imported multisig");

        interop(import(&setup.replace("2 of 3", "2 of 4")), "Policy says 4 keys but the file has 3");
        interop(import(&setup.replace("2 of 3", "two of three")), "couldn't read Policy");
        interop(import(&setup.replace("Policy: 2 of 3", "Policy: 2")), "couldn't read Policy");
        invalid(import(&setup.replace("2 of 3", "4 of 3")), "required signatures");
        interop(import(&format!("{setup}\nthis line has no separator")), "unexpected line");
        let format = setup.lines().find(|line| line.starts_with("Format:")).unwrap();
        interop(import(&setup.replace(format, "Format: P2TR")), "unsupported Format");
        let without_derivation: String = setup.lines().filter(|line| !line.starts_with("Derivation:")).map(|line| format!("{line}\n")).collect();
        interop(import(&without_derivation), "missing Derivation line");
        // Without a Policy line the file is not recognized as a setup file at all.
        interop(import(&setup.replace("Policy: 2 of 3\n", "")), "");
        assert!(matches!(mainnet().import_wallet(setup.clone().into_bytes(), "vault.txt".into()), Err(WalletError::WrongNetwork)));

        let record = String::from_utf8(service.export_wallet(account.id.clone(), ExportFormat::Bsms).unwrap()).unwrap();
        let lines: Vec<&str> = record.lines().collect();
        assert_eq!(service.preview_wallet(import(&record).unwrap()).unwrap(), expected);
        assert_eq!(service.preview_wallet(import(&record.replace("/0/*,/1/*", "No path restrictions")).unwrap()).unwrap(), expected);
        // The descriptor checksum is optional in a record, but must be right when present.
        let (body, checksum) = lines[1].split_once('#').unwrap();
        assert!(import(&record.replace(lines[1], body)).is_ok());
        let wrong = if checksum.starts_with('q') { "p" } else { "q" };
        interop(import(&record.replace(lines[1], &format!("{body}#{wrong}{}", &checksum[1..]))), "checksum doesn't match");
        interop(import(&record.replace("/0/*,/1/*", "/2/*,/3/*")), "unsupported path restrictions");
        interop(import(&record.replace(lines[3], &expected[2])), "first address doesn't match");
        interop(import(&lines[..3].join("\n")), "expected a BSMS 1.0 descriptor record");
        interop(import(&record.replace("BSMS 1.0", "BSMS 2.0")), "expected a BSMS 1.0 descriptor record");
    }

    // A setup file with no Format line falls back to Coldcard's documented P2SH default.
    let legacy = service.create_wallet({
        let mut config = config(ScriptType::P2sh);
        config.keystores.truncate(2);
        config
    });
    let setup = String::from_utf8(service.export_wallet(legacy.unwrap().id, ExportFormat::ColdcardMultisig).unwrap()).unwrap();
    assert_eq!(import(&setup.replace("Format: P2SH\n", "")).unwrap().script_type, ScriptType::P2sh);

    let single = service.create_wallet(config(ScriptType::P2wpkh)).unwrap();
    assert!(matches!(service.export_wallet(single.id, ExportFormat::ColdcardMultisig), Err(WalletError::NotSupported { .. })));
}

#[test]
fn specter_diy_wallet_lines_export_and_import_the_same_wallet() {
    // A device-written line: `h` markers and keys without a branch suffix. Public sample keys.
    const LINE: &str = "addwallet Vault 2 of 3&wsh(sortedmulti(2,[7fd1bbf4/48h/0h/0h/2h]xpub6DnVFCXjZKhSAJw1oGzksdc1CtMxHxqG6DgNSjZHsymMSgcNEb2c3bz5N2bBMEEUFos98CeAWbh1pTMBcJrsKW63icdAQNGT6Aqv1WWrkxg,[8ff26349/48h/0h/0h/2h]xpub6ErPooPdSeBoXVZocBe8EWF9GXjFuV52kme35p4MtrP2SAFdUmgTJM1urrJzSuA44izrEuiQNNdmWEVRaBJcBDcPpnLBR8tP2Pcu2EiyeHu,[ff3305c2/48h/0h/0h/2h]xpub6Dpndp2xurqbfSGhxKVXzk3nJZgah3PdD3qD11KyPicYYBatRxfxqoN7s9tnWKXaz7zhyVqcvnJyak7BVKonW2wTXHd1zNDxJAu8jcxF59j))\n";
    let imported = mainnet().import_wallet(LINE.as_bytes().to_vec(), "file.txt".into()).unwrap();
    assert_eq!((imported.name.as_str(), imported.script_type, imported.threshold), ("Vault 2 of 3", ScriptType::P2wsh, 2));
    let origins: Vec<_> = imported.keystores.iter().map(|k| (k.fingerprint.as_str(), k.derivation_path.as_str())).collect();
    assert_eq!(origins, [("7fd1bbf4", "m/48'/0'/0'/2'"), ("8ff26349", "m/48'/0'/0'/2'"), ("ff3305c2", "m/48'/0'/0'/2'")]);

    let (_dir, service) = regtest();
    let import = |text: &str| service.import_wallet(text.as_bytes().to_vec(), "file.txt".into());
    assert!(matches!(import(LINE), Err(WalletError::WrongNetwork)));
    interop(import(&LINE.replace("&wsh(sortedmulti(", "&wsh(multi(")), "");
    interop(import("addwallet no descriptor"), "not a descriptor");
    for script in support::SCRIPTS {
        let mut named = config(script);
        named.name = "Cold & warm".into();
        let account = service.create_wallet(named.clone()).unwrap();
        let line = String::from_utf8(service.export_wallet(account.id, ExportFormat::SpecterDiy).unwrap()).unwrap();
        assert!(line.starts_with("addwallet Cold   warm&") && line.ends_with(")\n"), "the name must not contain the separator");
        assert!(!line.contains(['\'', '*', '#']), "Specter DIY expects h markers and keys without branches");
        let back = import(&line).unwrap();
        assert_eq!(back.name, "Cold   warm");
        assert_eq!(service.preview_wallet(back).unwrap(), service.preview_wallet(named).unwrap(), "{script:?}");
    }
}

#[test]
fn psbt_files_and_qr_frames_round_trip_and_reject_foreign_payloads() {
    let (_dir, service) = regtest();
    // Sizes cross every CBOR byte-string length encoding and the single/animated QR boundary.
    for outputs in [1, 4, 40, 2_000] {
        let psbt = psbt(outputs);
        let base64 = service.psbt_from_file(psbt.serialize()).unwrap();
        assert_eq!(service.psbt_to_file(base64.clone()).unwrap(), psbt.serialize());
        assert_eq!(service.psbt_from_file(format!("{}\n{}\n", &base64[..20], &base64[20..]).into_bytes()).unwrap(), base64);
        let frames = service.psbt_to_ur_parts(base64.clone()).unwrap();
        assert_eq!(frames.len() == 1, outputs == 1);
        assert_eq!(support::qr_roundtrip(&service, base64.clone()), base64);

        // Some signers show the PSBT as plain base64, or as raw bytes inside the UR.
        let plain = UrDecoder::new();
        assert_eq!(plain.receive(format!("  {base64}\n")).unwrap(), 1.0);
        assert_eq!(plain.result().unwrap(), Some(base64.clone()));
        if outputs == 1 {
            let raw = UrDecoder::new();
            assert_eq!(raw.receive(ur::encode(&psbt.serialize(), &ur::Type::Custom("psbt"))).unwrap(), 1.0);
            assert_eq!(raw.result().unwrap(), Some(base64.clone()));
        } else {
            let partial = UrDecoder::new();
            assert!(partial.receive(frames[0].clone()).unwrap() < 1.0);
            assert_eq!(partial.result().unwrap(), None);
        }
    }

    interop(service.psbt_from_file(vec![0xff, 0xfe]), "not a PSBT");
    interop(service.psbt_from_file(b"not base64!".to_vec()), "not a PSBT");
    interop(service.psbt_from_file(b"aGVsbG8=".to_vec()), "");
    interop(service.psbt_from_file(b"psbt\xfftruncated".to_vec()), "");
    interop(service.psbt_to_file("aGVsbG8=".into()), "");
    interop(service.psbt_to_ur_parts("aGVsbG8=".into()), "");

    let decoder = UrDecoder::new();
    interop(decoder.receive("hello".into()), "not a PSBT");
    interop(decoder.receive("UR:CRYPTO-ACCOUNT/AEAE".into()), "isn't a PSBT");
    interop(decoder.receive("ur:crypto-psbt/not-bytewords".into()), "");
    interop(decoder.receive("ur:crypto-psbt/1-3/not-bytewords".into()), "");
    assert_eq!(decoder.result().unwrap(), None);
    // Well-formed URs whose payload is not a CBOR byte string holding a PSBT.
    for payload in
        [vec![], vec![0x01], vec![0x58], vec![0x59, 0x01], vec![0x5a, 0, 0], vec![0x5b, 0, 0, 0, 0, 0, 0, 0, 1, 7], vec![0x45, 1, 2], vec![0x45, 1, 2, 3, 4, 5]]
    {
        let decoder = UrDecoder::new();
        decoder.receive(ur::encode(&payload, &ur::Type::Custom("crypto-psbt"))).unwrap();
        assert!(matches!(decoder.result(), Err(WalletError::Interop { .. })), "{payload:?}");
    }
}
