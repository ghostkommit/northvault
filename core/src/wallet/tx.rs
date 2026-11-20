//! SECURITY-SENSITIVE — requires human review before merge.
//!
//! Builds unsigned PSBTs (with coin control), estimates fees, collects
//! signatures from hardware devices and finalizes. Nothing here signs: the
//! app has no private keys.

use std::str::FromStr;

use bdk_wallet::bitcoin::{Amount, FeeRate, OutPoint as BtcOutPoint, Psbt, Transaction, Txid, Weight};
use bdk_wallet::error::CreateTxError;
use bdk_wallet::{KeychainKind, SignOptions};

use crate::models::*;
use crate::wallet::address::parse_recipient;
use crate::wallet::descriptor::parse_fingerprint;
use crate::wallet::live::LiveAccount;

/// Above this the request is refused outright (likely a typo).
const MAX_FEE_RATE: f64 = 1_000.0;
const WARN_FEE_RATE: f64 = 500.0;
const WARN_FEE_SHARE: f64 = 0.10;

pub struct DraftRequest<'a> {
    pub address: &'a str,
    pub amount_sats: u64,
    pub sat_per_vb: f64,
    pub selected: &'a [OutPoint],
    /// Send everything (all selected coins, or the whole wallet) minus the fee.
    pub send_max: bool,
}

pub fn to_outpoints(selected: &[OutPoint]) -> Result<Vec<BtcOutPoint>, WalletError> {
    selected.iter().map(|o| Ok(BtcOutPoint { txid: Txid::from_str(&o.txid).map_err(|_| WalletError::backend("invalid txid"))?, vout: o.vout })).collect()
}

pub(crate) fn fee_rate(sat_per_vb: f64) -> Result<FeeRate, WalletError> {
    if !sat_per_vb.is_finite() || sat_per_vb < 1.0 {
        return Err(WalletError::backend("fee rate must be at least 1 sat/vB"));
    }
    if sat_per_vb > MAX_FEE_RATE {
        return Err(WalletError::FeeTooHigh);
    }
    Ok(FeeRate::from_sat_per_kwu((sat_per_vb * 250.0).ceil() as u64))
}

impl LiveAccount {
    /// Builds an unsigned PSBT. With `commit = false` (live previews) the change
    /// address isn't marked used, so typing doesn't burn change addresses.
    pub fn draft(&mut self, req: &DraftRequest, commit: bool) -> Result<(DraftTransaction, Psbt), WalletError> {
        let recipient = parse_recipient(req.address, self.network)?;
        if req.amount_sats == 0 && !req.send_max {
            return Err(WalletError::ZeroAmount);
        }
        let rate = fee_rate(req.sat_per_vb)?;
        let outpoints = to_outpoints(req.selected)?;
        let multisig = self.record.script_type.is_multisig();
        let available = self.spendable(&outpoints);

        let mut builder = self.wallet.build_tx();
        if !outpoints.is_empty() {
            builder.add_utxos(&outpoints).map_err(|e| WalletError::backend(e.to_string()))?;
            builder.manually_selected_only();
        }
        if req.send_max {
            builder.drain_to(recipient.script_pubkey());
            if outpoints.is_empty() {
                builder.drain_wallet();
            }
        } else {
            builder.add_recipient(recipient.script_pubkey(), Amount::from_sat(req.amount_sats));
        }
        builder.fee_rate(rate);
        if multisig {
            // Coldcard (and others) need the cosigner xpubs to verify change.
            builder.add_global_xpubs();
        }
        let psbt = builder.finish().map_err(|e| match e {
            CreateTxError::CoinSelection(f) => WalletError::InsufficientFunds { needed_sats: f.needed.to_sat(), available_sats: f.available.to_sat() },
            other => WalletError::backend(other.to_string()),
        })?;

        let draft = self.summarize(&psbt, &recipient.script_pubkey(), available)?;
        if !commit {
            for out in &psbt.unsigned_tx.output {
                if let Some((KeychainKind::Internal, index)) = self.wallet.derivation_of_spk(out.script_pubkey.clone()) {
                    self.wallet.unmark_used(KeychainKind::Internal, index);
                }
            }
        }
        Ok((draft, psbt))
    }

    fn spendable(&self, selected: &[BtcOutPoint]) -> u64 {
        self.wallet.list_unspent().filter(|u| selected.is_empty() || selected.contains(&u.outpoint)).map(|u| u.txout.value.to_sat()).sum()
    }

    /// Weight of the signed transaction, from each input's worst-case satisfaction.
    fn signed_weight(&self, psbt: &Psbt) -> Result<Weight, WalletError> {
        let mut weight = psbt.unsigned_tx.weight();
        let mut segwit = false;
        for input in &psbt.unsigned_tx.input {
            let utxo = self.wallet.get_utxo(input.previous_output).ok_or(WalletError::backend("input isn't in this wallet"))?;
            let desc = self.wallet.public_descriptor(utxo.keychain);
            weight += desc.max_weight_to_satisfy().map_err(WalletError::backend)?;
            segwit |= desc.desc_type().segwit_version().is_some();
        }
        if segwit {
            weight += Weight::from_wu(2); // marker + flag
        }
        Ok(weight)
    }

    fn summarize(&self, psbt: &Psbt, recipient: &bdk_wallet::bitcoin::ScriptBuf, available: u64) -> Result<DraftTransaction, WalletError> {
        let fee = psbt.fee().map_err(WalletError::backend)?.to_sat();
        let vbytes = self.signed_weight(psbt)?.to_vbytes_ceil() as u32;
        let outputs: Vec<TxOutput> = psbt
            .unsigned_tx
            .output
            .iter()
            .map(|o| TxOutput {
                address: self.address_string(&o.script_pubkey),
                amount_sats: o.value.to_sat(),
                is_change: matches!(self.wallet.derivation_of_spk(o.script_pubkey.clone()), Some((KeychainKind::Internal, _))),
            })
            .collect();
        let amount: u64 = outputs.iter().filter(|o| !o.is_change).map(|o| o.amount_sats).sum();
        let effective = fee as f64 / f64::from(vbytes.max(1));

        let mut warnings = Vec::new();
        if amount > 0 && fee as f64 >= amount as f64 * WARN_FEE_SHARE {
            warnings.push(format!("The fee is {:.0}% of the amount sent.", fee as f64 / amount as f64 * 100.0));
        }
        if effective > WARN_FEE_RATE {
            warnings.push(format!("The fee rate ({effective:.0} sat/vB) is very high."));
        }
        if self.wallet.is_mine(recipient.clone()) {
            warnings.push("The recipient address belongs to this wallet.".into());
        }
        let unconfirmed = psbt.unsigned_tx.input.iter().any(|i| self.wallet.get_utxo(i.previous_output).is_some_and(|u| !u.chain_position.is_confirmed()));
        if unconfirmed {
            warnings.push("Spends coins that aren't confirmed yet.".into());
        }

        Ok(DraftTransaction {
            amount_sats: amount,
            fee_sats: fee,
            vbytes,
            total_sats: amount + fee,
            balance_after_sats: available.saturating_sub(amount + fee),
            psbt_base64: crate::interop::psbt_io::to_base64(psbt),
            outputs,
            effective_fee_rate: effective,
            warnings,
        })
    }

    /// Largest amount that can be sent at this fee rate (from the selected coins, if any).
    pub fn max_sendable(&mut self, sat_per_vb: f64, selected: &[OutPoint]) -> Result<u64, WalletError> {
        let own = self.wallet.peek_address(KeychainKind::External, 0).address.to_string();
        let req = DraftRequest { address: &own, amount_sats: 0, sat_per_vb, selected, send_max: true };
        match self.draft(&req, false) {
            Ok((d, _)) => Ok(d.amount_sats),
            Err(WalletError::InsufficientFunds { .. }) => Ok(0),
            Err(e) => Err(e),
        }
    }

    /// Merges device-signed PSBTs into the draft. Every one must be for exactly
    /// the transaction that was created.
    pub fn combine(&self, draft: &Psbt, signed: &[Psbt]) -> Result<Psbt, WalletError> {
        let txid = draft.unsigned_tx.compute_txid();
        let mut psbt = draft.clone();
        for s in signed {
            if s.unsigned_tx.compute_txid() != txid {
                return Err(WalletError::PsbtMismatch);
            }
            psbt.combine(s.clone()).map_err(|_| WalletError::PsbtMismatch)?;
        }
        Ok(psbt)
    }

    pub fn signature_status(&self, psbt: &Psbt) -> SignatureStatus {
        let required = self.record.threshold;
        let fingerprints: Vec<_> = self.record.keystores.iter().filter_map(|k| parse_fingerprint(&k.fingerprint).ok()).collect();
        let mut per_input = Vec::new();
        for input in &psbt.inputs {
            let mut signers: Vec<String> = input
                .partial_sigs
                .keys()
                .filter_map(|pk| input.bip32_derivation.get(&pk.inner).map(|(fp, _)| *fp))
                .filter(|fp| fingerprints.contains(fp))
                .map(|fp| fp.to_string())
                .collect();
            if input.tap_key_sig.is_some() {
                signers.extend(input.tap_key_origins.values().map(|(_, (fp, _))| fp.to_string()));
            }
            if input.final_script_sig.is_some() || input.final_script_witness.is_some() {
                signers = self.record.keystores.iter().take(required as usize).map(|k| k.fingerprint.clone()).collect();
            }
            signers.sort();
            signers.dedup();
            per_input.push(signers);
        }
        let signed_by: Vec<String> = match per_input.split_first() {
            Some((first, rest)) => first.iter().filter(|fp| rest.iter().all(|s| s.contains(fp))).cloned().collect(),
            None => Vec::new(),
        };
        SignatureStatus { signatures: signed_by.len() as u32, required, signed_by }
    }

    /// Finalizes and extracts the transaction. Fails unless every input has
    /// enough signatures.
    pub fn finalize(&self, mut psbt: Psbt) -> Result<Transaction, WalletError> {
        let status = self.signature_status(&psbt);
        let done = self.wallet.finalize_psbt(&mut psbt, SignOptions::default()).map_err(WalletError::backend)?;
        if !done {
            return Err(WalletError::NotEnoughSignatures { signatures: status.signatures, required: status.required });
        }
        // extract_tx also refuses absurd fee rates.
        psbt.extract_tx().map_err(WalletError::backend)
    }
}

#[cfg(test)]
mod tests {
    use bdk_wallet::bitcoin::hashes::Hash;
    use bdk_wallet::bitcoin::secp256k1::Secp256k1;
    use bdk_wallet::bitcoin::{BlockHash, Network as BtcNetwork};
    use bdk_wallet::chain::BlockId;
    use bdk_wallet::test_utils::{insert_checkpoint, receive_output_in_latest_block};

    use super::*;
    use crate::store::{Store, WalletRecord};
    use crate::wallet::{descriptor, test_keys};

    const RECIPIENT: &str = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu";

    fn funded_vault(dir: &std::path::Path) -> (LiveAccount, Vec<BtcOutPoint>) {
        let config = test_keys::multisig_config(ScriptType::P2wsh, 2, 3);
        let desc = descriptor::build(&config, Network::Bitcoin).unwrap();
        let record = WalletRecord {
            id: WalletRecord::id_for(&desc),
            name: config.name.clone(),
            script_type: config.script_type,
            threshold: 2,
            keystores: config.keystores.clone(),
            descriptor: desc,
            created_at: 0,
            ledger_registrations: Vec::new(),
        };
        let store = Store::open(dir, Network::Bitcoin).unwrap();
        let mut acc = LiveAccount::open(&store, record, Network::Bitcoin).unwrap();
        insert_checkpoint(&mut acc.wallet, BlockId { height: 1_000, hash: BlockHash::all_zeros() });
        let coins = [100_000, 200_000, 300_000].map(|v| receive_output_in_latest_block(&mut acc.wallet, Amount::from_sat(v))).to_vec();
        (acc, coins)
    }

    fn req<'a>(amount: u64, selected: &'a [OutPoint]) -> DraftRequest<'a> {
        DraftRequest { address: RECIPIENT, amount_sats: amount, sat_per_vb: 2.0, selected, send_max: false }
    }

    fn ours(o: &BtcOutPoint) -> OutPoint {
        OutPoint { txid: o.txid.to_string(), vout: o.vout }
    }

    #[test]
    fn coin_control_uses_only_selected_inputs() {
        let dir = tempfile::tempdir().unwrap();
        let (mut acc, coins) = funded_vault(dir.path());
        let selected = [ours(&coins[0])];
        let (draft, psbt) = acc.draft(&req(50_000, &selected), false).unwrap();
        assert_eq!(psbt.unsigned_tx.input.len(), 1);
        assert_eq!(psbt.unsigned_tx.input[0].previous_output, coins[0]);
        assert_eq!(draft.amount_sats, 50_000);
        assert!(draft.outputs.iter().any(|o| o.is_change));
        assert_eq!(draft.total_sats, 50_000 + draft.fee_sats);
        // Selected coin can't cover more than its value.
        assert!(matches!(acc.draft(&req(150_000, &selected), false), Err(WalletError::InsufficientFunds { .. })));
        assert!(matches!(acc.draft(&req(700_000, &[]), false), Err(WalletError::InsufficientFunds { .. })));
    }

    #[test]
    fn previews_do_not_burn_change_addresses() {
        let dir = tempfile::tempdir().unwrap();
        let (mut acc, _) = funded_vault(dir.path());
        let change = |d: &DraftTransaction| d.outputs.iter().find(|o| o.is_change).unwrap().address.clone();
        let (a, _) = acc.draft(&req(10_000, &[]), false).unwrap();
        let (b, _) = acc.draft(&req(20_000, &[]), false).unwrap();
        assert_eq!(change(&a), change(&b));
    }

    #[test]
    fn rejects_bad_fee_rates_and_addresses() {
        let dir = tempfile::tempdir().unwrap();
        let (mut acc, _) = funded_vault(dir.path());
        let mut r = req(10_000, &[]);
        r.sat_per_vb = 5_000.0;
        assert!(matches!(acc.draft(&r, false), Err(WalletError::FeeTooHigh)));
        r.sat_per_vb = 2.0;
        r.address = "tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu";
        assert!(acc.draft(&r, false).is_err());
    }

    #[test]
    fn signatures_are_collected_checked_and_finalized() {
        let dir = tempfile::tempdir().unwrap();
        let (mut acc, _) = funded_vault(dir.path());
        let (_, draft) = acc.draft(&req(250_000, &[]), true).unwrap();
        assert!(!draft.xpub.is_empty(), "multisig PSBTs carry global xpubs for Coldcard");

        // Stand-ins for two hardware devices (test keys only).
        let secp = Secp256k1::new();
        let mut first = draft.clone();
        first.sign(&test_keys::xpriv(1), &secp).unwrap();
        let mut second = draft.clone();
        second.sign(&test_keys::xpriv(3), &secp).unwrap();

        let one = acc.combine(&draft, &[first.clone()]).unwrap();
        assert_eq!(acc.signature_status(&one).signatures, 1);
        assert!(matches!(acc.finalize(one), Err(WalletError::NotEnoughSignatures { signatures: 1, required: 2 })));

        // A PSBT for some other transaction is refused.
        let (_, other) = acc.draft(&req(1_000, &[]), false).unwrap();
        assert!(matches!(acc.combine(&draft, &[other]), Err(WalletError::PsbtMismatch)));

        let both = acc.combine(&draft, &[first, second]).unwrap();
        assert_eq!(acc.signature_status(&both).signatures, 2);
        let tx = acc.finalize(both).unwrap();
        assert!(tx.input.iter().all(|i| !i.witness.is_empty()));
        assert_eq!(BtcNetwork::from(Network::Bitcoin), BtcNetwork::Bitcoin);
    }
}
