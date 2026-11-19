//! SECURITY-SENSITIVE — requires human review before merge.
//!
//! Trezor over USB. trezor-client's built-in PSBT flow has no multisig or
//! taproot support, so the input/output acks are built here, with the
//! multisig redeem-script info Trezor needs to verify inputs and change.
//! PIN entry: on-device for newer models; transient matrix positions for Model One.
//! Prefer on-device passphrase entry when supported; otherwise use a transient UI prompt.

use std::str::FromStr;

use bdk_wallet::bitcoin::bip32::{ChildNumber, DerivationPath, Fingerprint, Xpub};
use bdk_wallet::bitcoin::hashes::Hash;
use bdk_wallet::bitcoin::{ecdsa, secp256k1, taproot, EcdsaSighashType, Psbt, Transaction};
use protobuf::MessageField;
use trezor_client::client::common::TrezorResponse;
use trezor_client::protos::{
    self,
    multisig_redeem_script_type::HDNodePathType,
    tx_ack::transaction_type::{TxInputType, TxOutputBinType, TxOutputType},
    tx_ack::TransactionType,
    tx_request::RequestType,
    HDNodeType, InputScriptType, MultisigRedeemScriptType, OutputScriptType,
};
use trezor_client::{Trezor, TrezorMessage};

use super::util;
use crate::models::*;
use crate::store::WalletRecord;
use crate::wallet::descriptor::{parse_path, parse_xpub};

fn err(e: impl std::fmt::Display) -> WalletError {
    WalletError::device(format!("Trezor: {e}"))
}

fn btc_network(network: Network) -> bdk_wallet::bitcoin::Network {
    network.into()
}

fn devices() -> Vec<trezor_client::AvailableDevice> {
    trezor_client::find_devices(false)
        .into_iter()
        .filter(|d| !d.debug && d.model != trezor_client::Model::TrezorBootloader)
        // A local UDP emulator is not a signer; only the test-only `emulator` feature admits it.
        .filter(|d| cfg!(feature = "emulator") || d.model != trezor_client::Model::TrezorEmulator)
        .collect()
}

fn connect(handle: &str) -> Result<Trezor, WalletError> {
    let index: usize = handle.strip_prefix("usb").and_then(|i| i.parse().ok()).ok_or_else(|| err("unknown device"))?;
    let device = devices().into_iter().nth(index).ok_or_else(|| err("not connected"))?;
    let mut trezor = device.connect().map_err(err)?;
    trezor.init_device(None).map_err(err)?;
    Ok(trezor)
}

/// Drives button / PIN / passphrase prompts until the device answers.
fn interact<T, R: TrezorMessage>(response: TrezorResponse<'_, T, R>) -> Result<T, WalletError> {
    interact_with_pin(response, &mut crate::pin::request)
}

fn interact_with_pin<T, R: TrezorMessage>(
    response: TrezorResponse<'_, T, R>,
    request_pin: &mut dyn FnMut() -> Result<String, WalletError>,
) -> Result<T, WalletError> {
    interact_with_credentials(response, request_pin, &mut crate::pin::request_passphrase)
}

fn interact_with_credentials<T, R: TrezorMessage>(
    mut response: TrezorResponse<'_, T, R>,
    request_pin: &mut dyn FnMut() -> Result<String, WalletError>,
    request_passphrase: &mut dyn FnMut() -> Result<String, WalletError>,
) -> Result<T, WalletError> {
    loop {
        response = match response {
            TrezorResponse::Ok(value) => return Ok(value),
            TrezorResponse::Failure(f) => return Err(err(f.message())),
            TrezorResponse::ButtonRequest(b) => b.ack().map_err(err)?,
            TrezorResponse::PinMatrixRequest(p) => {
                use trezor_client::protos::pin_matrix_request::PinMatrixRequestType;
                if p.request_type() != PinMatrixRequestType::PinMatrixRequestType_Current {
                    let _ = p.client.call_raw(protos::Cancel::new());
                    return Err(err("PIN changes and recovery are not supported; use Trezor Suite"));
                }
                let positions = match request_pin() {
                    Ok(positions) => positions,
                    Err(error) => {
                        let _ = p.client.call_raw(protos::Cancel::new());
                        return Err(error);
                    }
                };
                p.ack_pin(positions).map_err(err)?
            }
            TrezorResponse::PassphraseRequest(p) => {
                if p.on_device() {
                    // Legacy firmware already chose on-device entry: empty ack.
                    p.ack(false).map_err(err)?
                } else if p
                    .client
                    .features()
                    .is_some_and(|f| f.capabilities.iter().any(|c| c.enum_value_or_default() == protos::features::Capability::Capability_PassphraseEntry))
                {
                    p.ack(true).map_err(err)?
                } else {
                    let passphrase = match request_passphrase() {
                        Ok(value) => value,
                        Err(error) => {
                            let _ = p.client.call_raw(protos::Cancel::new());
                            return Err(error);
                        }
                    };
                    p.ack_passphrase(passphrase).map_err(err)?
                }
            }
        }
    }
}

fn master_fingerprint(trezor: &mut Trezor, network: Network) -> Result<Fingerprint, WalletError> {
    let path = DerivationPath::from_str("m/0'").expect("valid path");
    let xpub = interact(trezor.get_public_key(&path, btc_network(network), false).map_err(err)?)?;
    Ok(xpub.parent_fingerprint)
}

pub fn list(network: Network) -> Vec<HardwareDevice> {
    (0..devices().len())
        .filter_map(|i| {
            let handle = format!("usb{i}");
            let mut trezor = connect(&handle).ok()?;
            let features = trezor.features()?.clone();
            let fingerprint = if features.unlocked() { master_fingerprint(&mut trezor, network).ok().map(|f| f.to_string()) } else { None };
            let model = format!("Trezor {}", features.model()).trim().to_string();
            Some(HardwareDevice { id: format!("trezor:{handle}"), kind: DeviceKind::Trezor, model, fingerprint })
        })
        .collect()
}

pub fn keystore(handle: &str, path: &str, network: Network) -> Result<Keystore, WalletError> {
    let mut trezor = connect(handle)?;
    let fingerprint = master_fingerprint(&mut trezor, network)?.to_string();
    let parsed = parse_path(path)?;
    let xpub = interact(trezor.get_public_key(&parsed, btc_network(network), false).map_err(err)?)?;
    let xpub = parse_xpub(&xpub.to_string(), network)?;
    Ok(Keystore { label: "Trezor".into(), fingerprint, derivation_path: path.into(), xpub: xpub.to_string(), device: Some(DeviceKind::Trezor) })
}

fn input_script_type(script: ScriptType) -> InputScriptType {
    match script {
        ScriptType::P2pkh => InputScriptType::SPENDADDRESS,
        ScriptType::P2shP2wpkh | ScriptType::P2shP2wsh => InputScriptType::SPENDP2SHWITNESS,
        ScriptType::P2wpkh | ScriptType::P2wsh => InputScriptType::SPENDWITNESS,
        ScriptType::P2tr => InputScriptType::SPENDTAPROOT,
        ScriptType::P2sh => InputScriptType::SPENDMULTISIG,
    }
}

fn output_script_type(script: ScriptType) -> OutputScriptType {
    match script {
        ScriptType::P2pkh => OutputScriptType::PAYTOADDRESS,
        ScriptType::P2shP2wpkh | ScriptType::P2shP2wsh => OutputScriptType::PAYTOP2SHWITNESS,
        ScriptType::P2wpkh | ScriptType::P2wsh => OutputScriptType::PAYTOWITNESS,
        ScriptType::P2tr => OutputScriptType::PAYTOTAPROOT,
        ScriptType::P2sh => OutputScriptType::PAYTOMULTISIG,
    }
}

fn hd_node(xpub: &Xpub) -> HDNodeType {
    let mut node = HDNodeType::new();
    node.set_depth(u32::from(xpub.depth));
    node.set_fingerprint(u32::from_be_bytes(xpub.parent_fingerprint.to_bytes()));
    node.set_child_num(u32::from(xpub.child_number));
    node.set_chain_code(xpub.chain_code.to_bytes().to_vec());
    node.set_public_key(xpub.public_key.serialize().to_vec());
    node
}

/// Multisig description for one address, keys in `sortedmulti` order.
fn multisig(record: &WalletRecord, network: Network, chain: Chain, index: u32) -> Result<MultisigRedeemScriptType, WalletError> {
    let keys = util::keys_at(record, network, chain, index)?;
    let mut ms = MultisigRedeemScriptType::new();
    ms.set_m(record.threshold);
    for k in &keys {
        let mut p = HDNodePathType::new();
        p.node = MessageField::some(hd_node(&k.account_xpub));
        p.address_n = k.child.iter().map(|c| u32::from(*c)).collect();
        ms.pubkeys.push(p);
    }
    ms.signatures = vec![Vec::new(); keys.len()];
    Ok(ms)
}

fn chain_and_index(path: &DerivationPath) -> Option<(Chain, u32)> {
    let v = path.to_u32_vec();
    let (c, i) = (v.get(v.len().checked_sub(2)?)?, v.last()?);
    let chain = match c {
        0 => Chain::Receive,
        1 => Chain::Change,
        _ => return None,
    };
    Some((chain, *i))
}

pub fn display_address(handle: &str, record: &WalletRecord, network: Network, chain: Chain, index: u32) -> Result<String, WalletError> {
    let mut trezor = connect(handle)?;
    let fp = master_fingerprint(&mut trezor, network)?;
    let own = util::own_keystore(record, &fp)?;
    let path = parse_path(&own.derivation_path)?.extend([ChildNumber::from(util::chain_index(chain)), ChildNumber::from(index)]);

    let mut req = protos::GetAddress::new();
    req.address_n = path.to_u32_vec();
    req.set_coin_name(trezor_client::utils::coin_name(btc_network(network)).map_err(err)?);
    req.set_show_display(true);
    req.set_script_type(input_script_type(record.script_type));
    if record.script_type.is_multisig() {
        req.multisig = MessageField::some(multisig(record, network, chain, index)?);
    }
    let response = trezor.call(req, Box::new(|_, m: protos::Address| Ok(m.address().to_string()))).map_err(err)?;
    interact(response)
}

/// Our key's derivation path for a PSBT input/output, if the device's key is in it.
fn own_path(
    derivations: &std::collections::BTreeMap<secp256k1::PublicKey, (Fingerprint, DerivationPath)>,
    tap: &std::collections::BTreeMap<secp256k1::XOnlyPublicKey, (Vec<taproot::TapLeafHash>, (Fingerprint, DerivationPath))>,
    fp: &Fingerprint,
) -> Option<(Option<secp256k1::PublicKey>, DerivationPath)> {
    derivations
        .iter()
        .find(|(_, (f, _))| f == fp)
        .map(|(pk, (_, path))| (Some(*pk), path.clone()))
        .or_else(|| tap.values().find(|(_, (f, _))| f == fp).map(|(_, (_, path))| (None, path.clone())))
}

fn find_prev_tx<'a>(psbt: &'a Psbt, hash: &[u8]) -> Result<&'a Transaction, WalletError> {
    let mut rev = hash.to_vec();
    rev.reverse();
    psbt.inputs
        .iter()
        .filter_map(|i| i.non_witness_utxo.as_ref())
        .find(|tx| tx.compute_txid().to_byte_array().as_slice() == rev.as_slice())
        .ok_or_else(|| err("the PSBT is missing a previous transaction"))
}

struct Signing<'a> {
    psbt: &'a Psbt,
    record: &'a WalletRecord,
    network: Network,
    fp: Fingerprint,
}

impl Signing<'_> {
    fn ack(&self, req: &protos::TxRequest) -> Result<protos::TxAck, WalletError> {
        let details = req.details.as_ref().ok_or_else(|| err("malformed request"))?;
        let mut txdata = TransactionType::new();
        let index = details.request_index() as usize;
        match req.request_type() {
            RequestType::TXMETA => {
                let tx = if details.has_tx_hash() { find_prev_tx(self.psbt, details.tx_hash())? } else { &self.psbt.unsigned_tx };
                txdata.set_version(tx.version.0 as u32);
                txdata.set_lock_time(tx.lock_time.to_consensus_u32());
                txdata.set_inputs_cnt(tx.input.len() as u32);
                txdata.set_outputs_cnt(tx.output.len() as u32);
            }
            RequestType::TXINPUT if details.has_tx_hash() => {
                let tx = find_prev_tx(self.psbt, details.tx_hash())?;
                let input = tx.input.get(index).ok_or_else(|| err("bad input index"))?;
                let mut i = TxInputType::new();
                i.set_prev_hash(input.previous_output.txid.to_byte_array().iter().rev().copied().collect());
                i.set_prev_index(input.previous_output.vout);
                i.set_script_sig(input.script_sig.to_bytes());
                i.set_sequence(input.sequence.to_consensus_u32());
                txdata.inputs.push(i);
            }
            RequestType::TXINPUT => txdata.inputs.push(self.signing_input(index)?),
            RequestType::TXOUTPUT if details.has_tx_hash() => {
                let tx = find_prev_tx(self.psbt, details.tx_hash())?;
                let out = tx.output.get(index).ok_or_else(|| err("bad output index"))?;
                let mut bin = TxOutputBinType::new();
                bin.set_amount(out.value.to_sat());
                bin.set_script_pubkey(out.script_pubkey.to_bytes());
                txdata.bin_outputs.push(bin);
            }
            RequestType::TXOUTPUT => txdata.outputs.push(self.signing_output(index)?),
            other => return Err(err(format!("unsupported request {other:?}"))),
        }
        let mut ack = protos::TxAck::new();
        ack.tx = MessageField::some(txdata);
        Ok(ack)
    }

    fn signing_input(&self, index: usize) -> Result<TxInputType, WalletError> {
        let txin = self.psbt.unsigned_tx.input.get(index).ok_or_else(|| err("bad input index"))?;
        let pin = self.psbt.inputs.get(index).ok_or_else(|| err("bad input index"))?;
        let amount = match (&pin.witness_utxo, &pin.non_witness_utxo) {
            (Some(o), _) => o.value,
            (None, Some(tx)) => tx.output.get(txin.previous_output.vout as usize).ok_or_else(|| err("bad prevout"))?.value,
            _ => return Err(err("the PSBT is missing input amounts")),
        };
        let (_, path) = own_path(&pin.bip32_derivation, &pin.tap_key_origins, &self.fp).ok_or_else(|| err("an input isn't from this wallet"))?;

        let mut i = TxInputType::new();
        i.set_prev_hash(txin.previous_output.txid.to_byte_array().iter().rev().copied().collect());
        i.set_prev_index(txin.previous_output.vout);
        i.set_sequence(txin.sequence.to_consensus_u32());
        i.set_amount(amount.to_sat());
        i.address_n = path.to_u32_vec();
        i.set_script_type(input_script_type(self.record.script_type));
        if self.record.script_type.is_multisig() {
            let (chain, idx) = chain_and_index(&path).ok_or_else(|| err("unexpected input path"))?;
            i.multisig = MessageField::some(multisig(self.record, self.network, chain, idx)?);
        }
        Ok(i)
    }

    fn signing_output(&self, index: usize) -> Result<TxOutputType, WalletError> {
        let out = self.psbt.unsigned_tx.output.get(index).ok_or_else(|| err("bad output index"))?;
        let pout = self.psbt.outputs.get(index).ok_or_else(|| err("bad output index"))?;
        let mut o = TxOutputType::new();
        o.set_amount(out.value.to_sat());

        // Only our change chain is sent as a path, so the device can verify and hide it.
        let change = own_path(&pout.bip32_derivation, &pout.tap_key_origins, &self.fp)
            .and_then(|(_, path)| chain_and_index(&path).filter(|(c, _)| *c == Chain::Change).map(|(c, i)| (path, c, i)));
        if let Some((path, chain, idx)) = change {
            o.address_n = path.to_u32_vec();
            o.set_script_type(output_script_type(self.record.script_type));
            if self.record.script_type.is_multisig() {
                o.multisig = MessageField::some(multisig(self.record, self.network, chain, idx)?);
            }
        } else if out.script_pubkey.is_op_return() {
            o.set_script_type(OutputScriptType::PAYTOOPRETURN);
            o.set_op_return_data(out.script_pubkey.as_bytes()[1..].to_vec());
        } else {
            let address =
                trezor_client::utils::address_from_script(&out.script_pubkey, btc_network(self.network)).ok_or_else(|| err("unsupported output script"))?;
            o.set_address(address.to_string());
            o.set_script_type(OutputScriptType::PAYTOADDRESS);
        }
        Ok(o)
    }
}

/// Puts a device signature into the PSBT input for our key.
fn apply_signature(psbt: &mut Psbt, index: usize, sig: &[u8], fp: &Fingerprint) -> Result<(), WalletError> {
    let input = psbt.inputs.get_mut(index).ok_or_else(|| err("bad signature index"))?;
    let (pubkey, _) = own_path(&input.bip32_derivation, &input.tap_key_origins, fp).ok_or_else(|| err("signature for an unknown key"))?;
    match pubkey {
        Some(pk) => {
            let signature = secp256k1::ecdsa::Signature::from_der(sig).map_err(err)?;
            input.partial_sigs.insert(bdk_wallet::bitcoin::PublicKey::new(pk), ecdsa::Signature { signature, sighash_type: EcdsaSighashType::All });
        }
        None => input.tap_key_sig = Some(taproot::Signature::from_slice(sig).map_err(err)?),
    }
    Ok(())
}

pub fn sign(handle: &str, record: &WalletRecord, network: Network, mut psbt: Psbt) -> Result<Psbt, WalletError> {
    let mut trezor = connect(handle)?;
    let fp = master_fingerprint(&mut trezor, network)?;
    util::own_keystore(record, &fp)?;
    let unsigned = psbt.clone();
    let signing = Signing { psbt: &unsigned, record, network, fp };

    let mut response = trezor.sign_tx(&unsigned, btc_network(network)).map_err(err)?;
    loop {
        let progress = interact(response)?;
        if let Some((index, sig)) = progress.get_signature() {
            apply_signature(&mut psbt, index, sig, &fp)?;
        }
        if progress.finished() {
            break;
        }
        let ack = signing.ack(progress.tx_request())?;
        response = progress.ack_msg(ack).map_err(err)?;
    }
    Ok(psbt)
}

#[cfg(test)]
mod pin_tests {
    use super::*;
    use std::{
        collections::VecDeque,
        sync::{Arc, Mutex},
    };
    use trezor_client::protos::pin_matrix_request::PinMatrixRequestType;
    use trezor_client::transport::{error::Error, ProtoMessage, Transport};

    struct FakeTransport {
        replies: VecDeque<ProtoMessage>,
        sent: Arc<Mutex<Vec<ProtoMessage>>>,
    }
    impl Transport for FakeTransport {
        fn session_begin(&mut self) -> Result<(), Error> {
            Ok(())
        }
        fn session_end(&mut self) -> Result<(), Error> {
            Ok(())
        }
        fn write_message(&mut self, message: ProtoMessage) -> Result<(), Error> {
            self.sent.lock().unwrap().push(message);
            Ok(())
        }
        fn read_message(&mut self) -> Result<ProtoMessage, Error> {
            Ok(self.replies.pop_front().expect("unexpected extra device request"))
        }
    }
    fn message<M: TrezorMessage>(value: M) -> ProtoMessage {
        ProtoMessage(M::MESSAGE_TYPE, value.write_to_bytes().unwrap())
    }
    fn fixture(kind: PinMatrixRequestType, accepted: bool) -> (Trezor, Arc<Mutex<Vec<ProtoMessage>>>) {
        let mut request = protos::PinMatrixRequest::new();
        request.set_type(kind);
        let result = if accepted { message(protos::Success::new()) } else { message(protos::Failure::new()) };
        let sent = Arc::new(Mutex::new(Vec::new()));
        let transport = FakeTransport { replies: VecDeque::from([message(request), result]), sent: sent.clone() };
        (trezor_client::client::trezor_with_transport(trezor_client::Model::TrezorLegacy, Box::new(transport)), sent)
    }

    #[test]
    fn pin_ack_resumes_the_same_request() {
        let (mut device, sent) = fixture(PinMatrixRequestType::PinMatrixRequestType_Current, true);
        let response = device.ping("test").unwrap();
        interact_with_pin(response, &mut || Ok("789".into())).unwrap();
        let sent = sent.lock().unwrap();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[1].message_type(), protos::MessageType::MessageType_PinMatrixAck);
        let ack: protos::PinMatrixAck = protobuf::Message::parse_from_bytes(sent[1].payload()).unwrap();
        assert_eq!(ack.pin(), "789");
    }

    #[test]
    fn cancelled_pin_sends_cancel_instead_of_ack() {
        let (mut device, sent) = fixture(PinMatrixRequestType::PinMatrixRequestType_Current, false);
        let response = device.ping("test").unwrap();
        assert!(interact_with_pin(response, &mut || Err(err("cancelled"))).is_err());
        let sent = sent.lock().unwrap();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[1].message_type(), protos::MessageType::MessageType_Cancel);
    }

    #[test]
    fn pin_changes_are_cancelled_without_prompting() {
        let (mut device, sent) = fixture(PinMatrixRequestType::PinMatrixRequestType_NewFirst, false);
        let response = device.ping("test").unwrap();
        assert!(interact_with_pin(response, &mut || panic!("must not ask for a new PIN")).is_err());
        assert_eq!(sent.lock().unwrap()[1].message_type(), protos::MessageType::MessageType_Cancel);
    }

    #[test]
    fn wrong_pin_is_not_retried() {
        let (mut device, sent) = fixture(PinMatrixRequestType::PinMatrixRequestType_Current, false);
        let mut prompts = 0;
        let response = device.ping("test").unwrap();
        assert!(interact_with_pin(response, &mut || {
            prompts += 1;
            Ok("123".into())
        })
        .is_err());
        assert_eq!(prompts, 1);
        assert_eq!(sent.lock().unwrap().len(), 2);
    }
    fn passphrase_fixture(on_device: bool, legacy: bool, cancelled: bool) -> (Trezor, Arc<Mutex<Vec<ProtoMessage>>>) {
        let mut features = protos::Features::new();
        features.set_major_version(1);
        features.set_minor_version(9);
        features.set_patch_version(0);
        if on_device {
            features.capabilities.push(protobuf::EnumOrUnknown::new(protos::features::Capability::Capability_PassphraseEntry));
        }
        let mut request = protos::PassphraseRequest::new();
        if legacy {
            request.set__on_device(true);
        }
        let sent = Arc::new(Mutex::new(Vec::new()));
        let result = if cancelled { message(protos::Failure::new()) } else { message(protos::Success::new()) };
        let transport = FakeTransport { replies: VecDeque::from([message(features), message(request), result]), sent: sent.clone() };
        let mut device = trezor_client::client::trezor_with_transport(trezor_client::Model::TrezorLegacy, Box::new(transport));
        device.init_device(None).unwrap();
        (device, sent)
    }

    #[test]
    fn model_one_sends_explicit_standard_or_exact_host_passphrase() {
        for value in ["", " Exact Case "] {
            let (mut device, sent) = passphrase_fixture(false, false, false);
            interact_with_credentials(device.ping("test").unwrap(), &mut || panic!("unexpected PIN"), &mut || Ok(value.into())).unwrap();
            let sent = sent.lock().unwrap();
            let ack: protos::PassphraseAck = protobuf::Message::parse_from_bytes(sent[2].payload()).unwrap();
            assert!(ack.has_passphrase());
            assert_eq!(ack.passphrase(), value);
            assert!(!ack.on_device());
        }
    }

    #[test]
    fn cancelling_passphrase_does_not_select_standard_wallet() {
        let (mut device, sent) = passphrase_fixture(false, false, true);
        assert!(interact_with_credentials(device.ping("test").unwrap(), &mut || panic!("unexpected PIN"), &mut || Err(err("cancelled"))).is_err());
        let sent = sent.lock().unwrap();
        assert_eq!(sent[2].message_type(), protos::MessageType::MessageType_Cancel);
    }

    #[test]
    fn capable_device_uses_on_device_entry_without_host_prompt() {
        let (mut device, sent) = passphrase_fixture(true, false, false);
        interact_with_credentials(device.ping("test").unwrap(), &mut || panic!("unexpected PIN"), &mut || panic!("must stay on device")).unwrap();
        let sent = sent.lock().unwrap();
        let ack: protos::PassphraseAck = protobuf::Message::parse_from_bytes(sent[2].payload()).unwrap();
        assert!(ack.on_device());
        assert!(!ack.has_passphrase());
    }

    #[test]
    fn legacy_on_device_request_gets_empty_ack() {
        let (mut device, sent) = passphrase_fixture(false, true, false);
        interact_with_credentials(device.ping("test").unwrap(), &mut || panic!("unexpected PIN"), &mut || panic!("must stay on device")).unwrap();
        let sent = sent.lock().unwrap();
        let ack: protos::PassphraseAck = protobuf::Message::parse_from_bytes(sent[2].payload()).unwrap();
        assert!(!ack.has_on_device());
        assert!(!ack.has_passphrase());
    }
}
