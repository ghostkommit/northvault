//! Firmware-emulator integration test: the production Trezor transport and
//! signing protocol against Trezor's own emulator, on Regtest. Run with
//! `make docker-test-hardware`. An emulator is not a physical device: USB,
//! screens, buttons and the macOS HID path stay on the DEVELOPMENT.md checklist.
#![cfg(feature = "emulator")]
#[allow(dead_code)]
mod support;

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

use bdk_wallet::bitcoin::hashes::{sha256, Hash};
use northvault_core::{Chain, DeviceKind, Network, OutPoint, ScriptType, WalletError, WalletService};
use trezor_client::client::handle_interaction;
use trezor_client::protos::{self, debug_link_decision::DebugButton};

/// Trezor's published all-zero-entropy test seed. Public: never for real funds.
const MNEMONIC: &str = "all all all all all all all all all all all all";

fn emulator(debug: bool) -> trezor_client::Trezor {
    trezor_client::find_devices(debug).into_iter().find(|d| d.model == trezor_client::Model::TrezorEmulator).expect("emulator running").connect().unwrap()
}

/// Answers every on-screen prompt for the rest of the process: confirm, or cancel while `decline` is set.
fn press_buttons(decline: Arc<AtomicBool>) {
    let mut link = emulator(true);
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_millis(50));
            let Ok(state) = link.call(protos::DebugLinkGetState::new(), Box::new(|_, m: protos::DebugLinkState| Ok(m))).and_then(handle_interaction) else {
                continue;
            };
            // Press only while a confirmation page is on screen.
            if !state.tokens.concat().contains("ButtonPage") {
                continue;
            }
            let mut decision = protos::DebugLinkDecision::new();
            decision.set_button(if decline.load(Ordering::Relaxed) { DebugButton::NO } else { DebugButton::YES });
            let _ = link.send_message(decision);
            // Let the page close before looking again, so one prompt gets one press.
            std::thread::sleep(Duration::from_millis(300));
        }
    });
}

fn load_seed() {
    let mut trezor = emulator(false);
    trezor.init_device(None).unwrap();
    if trezor.features().unwrap().initialized() {
        return;
    }
    let mut load = protos::LoadDevice::new();
    load.mnemonics.push(MNEMONIC.into());
    load.set_passphrase_protection(false);
    load.set_label("Northvault emulator".into());
    handle_interaction(trezor.call(load, Box::new(|_, _: protos::Success| Ok(()))).unwrap()).unwrap();
}

#[tokio::test]
#[ignore = "requires the Trezor emulator and Regtest services; run make docker-test-hardware"]
async fn trezor_emulator_verifies_addresses_and_signs_every_script() {
    let node = support::Node::from_env();
    let url = format!("tcp://127.0.0.1:{}", std::env::var("NORTHVAULT_TEST_ELECTRUM_PORT").unwrap());
    let decline = Arc::new(AtomicBool::new(false));
    press_buttons(decline.clone());
    load_seed();

    // Fresh cosigners per run: the Compose chain persists and must not rediscover old multisig coins.
    let run_id = node.rpc(&["getnewaddress"]);
    let cosigners: Vec<_> = (1..=2)
        .map(|id| {
            support::Signer::from_seed(sha256::Hash::hash(format!("northvault-emulator-only:{id}:{}", run_id.as_str().unwrap()).as_bytes()).as_byte_array())
        })
        .collect();

    for script in support::SCRIPTS {
        let dir = tempfile::tempdir().unwrap();
        let service = WalletService::open(dir.path().to_str().unwrap().to_owned(), Network::Regtest, Some(url.clone())).unwrap();
        let devices = service.list_devices().await.unwrap();
        let device = devices.iter().find(|d| d.kind == DeviceKind::Trezor).expect("emulator listed").clone();
        let own = service.device_keystore(device.id.clone(), script).await.unwrap();
        assert_eq!(device.fingerprint.as_deref(), Some(own.fingerprint.as_str()));

        let mut config = support::config(script);
        config.keystores = std::iter::once(own).chain(cosigners.iter().map(|c| c.keystore(script))).take(config.keystores.len()).collect();
        let account = service.create_wallet(config).unwrap();
        if script == ScriptType::P2sh {
            // Finding: with its default strict safety checks the firmware refuses the
            // m/45' account path used for legacy P2SH multisig. Pinned until that path changes.
            let refused = service.device_verify_address(device.id.clone(), account.id.clone(), Chain::Receive, 0).await;
            assert!(matches!(refused, Err(WalletError::Device { message }) if message.contains("Forbidden key path")));
            continue;
        }
        // The firmware derives each address itself; the service rejects any difference from ours.
        for chain in [Chain::Receive, Chain::Change] {
            let shown = service.device_verify_address(device.id.clone(), account.id.clone(), chain, 3).await.unwrap();
            assert_eq!(shown, service.addresses(account.id.clone(), chain).unwrap()[3].address, "{script:?}");
        }

        // The single-sig emulator wallets are the same every run, so measure from the current balance.
        service.sync(Some(account.id.clone())).await.unwrap();
        let before = service.accounts()[0].balance_sats;
        let receive = service.next_receive_address(account.id.clone(), 0).unwrap();
        let funding = node.rpc(&["sendtoaddress", &receive.address, "0.01000000"]);
        node.mine();
        support::wait_balance(&service, &account.id, before + 1_000_000).await;
        let coin = service.utxos(Some(account.id.clone())).into_iter().find(|u| u.txid == funding.as_str().unwrap()).unwrap();
        let recipient = node.rpc(&["getnewaddress"]);
        let selected = vec![OutPoint { txid: coin.txid, vout: coin.vout }];
        let draft = service.create_transaction(account.id.clone(), recipient.as_str().unwrap().into(), 100_000, 2.0, selected, false).unwrap();
        assert!(draft.outputs.iter().any(|o| o.is_change));

        if script == ScriptType::P2wpkh {
            decline.store(true, Ordering::Relaxed);
            let declined = service.device_sign(device.id.clone(), account.id.clone(), draft.psbt_base64.clone()).await;
            decline.store(false, Ordering::Relaxed);
            assert!(matches!(declined, Err(WalletError::Device { .. })), "a cancelled signing request must not produce a PSBT");
        }

        let mut signatures = vec![service.device_sign(device.id.clone(), account.id.clone(), draft.psbt_base64.clone()).await.unwrap()];
        if script.is_multisig() {
            let alone = service.broadcast(account.id.clone(), draft.psbt_base64.clone(), signatures.clone()).await;
            assert!(matches!(alone, Err(WalletError::NotEnoughSignatures { .. })));
            let bytes = cosigners[0].sign(&service.psbt_to_file(draft.psbt_base64.clone()).unwrap());
            signatures.push(service.psbt_from_file(bytes).unwrap());
        }
        let txid = service.broadcast(account.id.clone(), draft.psbt_base64, signatures).await.unwrap();
        // Bitcoin Core's mempool acceptance validates the emulator's signatures independently.
        assert!(node.rpc(&["getmempoolentry", &txid]).is_object(), "{script:?}");
        node.mine();
    }

    // A wallet the device has no key in: it must refuse to show addresses or sign.
    let dir = tempfile::tempdir().unwrap();
    let service = WalletService::open(dir.path().to_str().unwrap().to_owned(), Network::Regtest, Some(url)).unwrap();
    let device = service.list_devices().await.unwrap().remove(0);
    let mut config = support::config(ScriptType::P2wpkh);
    config.keystores = vec![cosigners[0].keystore(ScriptType::P2wpkh)];
    let foreign = service.create_wallet(config).unwrap();
    assert!(service.device_verify_address(device.id.clone(), foreign.id.clone(), Chain::Receive, 0).await.is_err());
    let receive = service.next_receive_address(foreign.id.clone(), 0).unwrap();
    node.rpc(&["sendtoaddress", &receive.address, "0.01000000"]);
    node.mine();
    support::wait_balance(&service, &foreign.id, 1_000_000).await;
    let draft = service.create_transaction(foreign.id.clone(), receive.address, 100_000, 2.0, vec![], false).unwrap();
    assert!(matches!(service.device_sign(device.id, foreign.id, draft.psbt_base64).await, Err(WalletError::Device { .. })));
}
