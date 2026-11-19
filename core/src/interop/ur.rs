//! BC-UR animated QR codes for PSBTs (`crypto-psbt`, read by Jade, Sparrow,
//! Keystone, Passport, SeedSigner). The payload is a CBOR byte string.

use std::sync::Mutex;

use bdk_wallet::bitcoin::Psbt;

use crate::interop::psbt_io;
use crate::models::WalletError;

/// Characters per QR frame. Small enough for reliable webcam scanning.
const FRAGMENT_LEN: usize = 200;

/// The `ur` crate's errors implement only `Debug`.
fn ur_error(e: impl std::fmt::Debug) -> WalletError {
    WalletError::interop(format!("{e:?}"))
}

fn cbor_bytes(data: &[u8]) -> Vec<u8> {
    let n = data.len();
    let mut out = match n {
        0..=23 => vec![0x40 | n as u8],
        24..=0xff => vec![0x58, n as u8],
        0x100..=0xffff => vec![0x59, (n >> 8) as u8, n as u8],
        _ => {
            let mut v = vec![0x5a];
            v.extend_from_slice(&(n as u32).to_be_bytes());
            v
        }
    };
    out.extend_from_slice(data);
    out
}

fn cbor_unwrap_bytes(data: &[u8]) -> Result<&[u8], WalletError> {
    let err = || WalletError::interop("unexpected QR payload");
    let first = *data.first().ok_or_else(err)?;
    if first >> 5 != 2 {
        return Err(err());
    }
    let (len, start) = match first & 0x1f {
        n @ 0..=23 => (n as usize, 1),
        24 => (*data.get(1).ok_or_else(err)? as usize, 2),
        25 => (u16::from_be_bytes(data.get(1..3).ok_or_else(err)?.try_into().unwrap()) as usize, 3),
        26 => (u32::from_be_bytes(data.get(1..5).ok_or_else(err)?.try_into().unwrap()) as usize, 5),
        _ => return Err(err()),
    };
    data.get(start..start + len).ok_or_else(err)
}

/// QR frames for an animated code. Includes extra fountain frames so a missed
/// frame doesn't mean waiting a whole cycle.
pub fn psbt_to_parts(psbt: &Psbt) -> Result<Vec<String>, WalletError> {
    let payload = cbor_bytes(&psbt.serialize());
    let mut encoder = ur::Encoder::new(&payload, FRAGMENT_LEN, "crypto-psbt").map_err(ur_error)?;
    let count = encoder.fragment_count();
    if count == 1 {
        return Ok(vec![ur::encode(&payload, &ur::Type::Custom("crypto-psbt")).to_uppercase()]);
    }
    (0..count * 3).map(|_| encoder.next_part().map(|p| p.to_uppercase()).map_err(ur_error)).collect()
}

/// Collects scanned QR frames until a PSBT is complete.
#[derive(uniffi::Object)]
pub struct UrDecoder {
    inner: Mutex<ur::Decoder>,
    single: Mutex<Option<Vec<u8>>>,
}

#[uniffi::export]
impl UrDecoder {
    #[uniffi::constructor]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self { inner: Mutex::new(ur::Decoder::default()), single: Mutex::new(None) })
    }

    /// Feeds one scanned frame. Returns progress from 0 to 1.
    pub fn receive(&self, part: String) -> Result<f64, WalletError> {
        let original = part.trim();
        if !original.get(..3).is_some_and(|prefix| prefix.eq_ignore_ascii_case("ur:")) {
            // Some devices show a plain base64 PSBT.
            // Base64 is case-sensitive; normalize only the UR envelope below.
            let psbt = psbt_io::from_base64(original)?;
            *self.single.lock().unwrap() = Some(psbt.serialize());
            return Ok(1.0);
        }
        let part = original.to_lowercase();
        let type_ok = part.starts_with("ur:crypto-psbt/") || part.starts_with("ur:psbt/");
        if !type_ok {
            return Err(WalletError::interop("this QR code isn't a PSBT"));
        }
        let is_multipart = part.split('/').count() > 2;
        if !is_multipart {
            let (_, payload) = ur::decode(&part).map_err(ur_error)?;
            *self.single.lock().unwrap() = Some(payload);
            return Ok(1.0);
        }
        // "ur:crypto-psbt/7-35/…": 35 fragments in total.
        let total: f64 = part.split('/').nth(1).and_then(|seq| seq.split('-').nth(1)).and_then(|n| n.parse().ok()).unwrap_or(1.0);
        let mut dec = self.inner.lock().unwrap();
        dec.receive(&part).map_err(ur_error)?;
        let resolved = dec.resolved_fragment_count().unwrap_or(0) as f64;
        Ok(if dec.complete() { 1.0 } else { (resolved / total).min(0.99) })
    }

    /// The scanned PSBT as base64 once complete.
    pub fn result(&self) -> Result<Option<String>, WalletError> {
        let payload = if let Some(p) = self.single.lock().unwrap().clone() {
            p
        } else {
            let dec = self.inner.lock().unwrap();
            if !dec.complete() {
                return Ok(None);
            }
            dec.message().map_err(ur_error)?.unwrap_or_default()
        };
        // CBOR byte-string prefixes 0x58/0x59 are ASCII X/Y, not base64.
        // Non-UR input was already parsed and stored as binary above.
        if payload.starts_with(b"psbt\xff") {
            return Ok(Some(psbt_io::to_base64(&psbt_io::decode(&payload)?)));
        }
        let psbt = psbt_io::decode(cbor_unwrap_bytes(&payload)?)?;
        Ok(Some(psbt_io::to_base64(&psbt)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bdk_wallet::bitcoin::{absolute, transaction, Amount, ScriptBuf, Transaction, TxIn, TxOut};

    fn synthetic_psbt(inputs: usize) -> Psbt {
        Psbt::from_unsigned_tx(Transaction {
            version: transaction::Version::TWO,
            lock_time: absolute::LockTime::ZERO,
            input: vec![TxIn::default(); inputs],
            output: vec![TxOut { value: Amount::from_sat(1000), script_pubkey: ScriptBuf::new() }],
        })
        .unwrap()
    }

    #[test]
    fn qr_psbt_round_trips_preserve_case_and_cbor() {
        for inputs in [1, 10] {
            let psbt = synthetic_psbt(inputs);
            let expected = psbt_io::to_base64(&psbt);
            let plain = UrDecoder::new();
            assert_eq!(plain.receive(format!("  {expected}\n")).unwrap(), 1.0);
            assert_eq!(plain.result().unwrap(), Some(expected.clone()));

            let parts = psbt_to_parts(&psbt).unwrap();
            assert_eq!(parts.len() == 1, inputs == 1);
            let decoder = UrDecoder::new();
            for part in parts.iter().rev() {
                decoder.receive(part.clone()).unwrap();
            }
            assert_eq!(decoder.result().unwrap(), Some(expected));
        }
    }

    #[test]
    fn qr_rejects_invalid_psbt_and_incomplete_fragments() {
        let decoder = UrDecoder::new();
        assert!(decoder.receive("not a psbt".into()).is_err());
        assert!(decoder.receive("UR:CRYPTO-ACCOUNT/INVALID".into()).is_err());
        assert_eq!(decoder.result().unwrap(), None);
        let parts = psbt_to_parts(&synthetic_psbt(10)).unwrap();
        decoder.receive(parts[0].clone()).unwrap();
        assert_eq!(decoder.result().unwrap(), None);
    }

    #[test]
    fn cbor_round_trip() {
        for n in [0usize, 5, 23, 24, 255, 256, 70_000] {
            let data = vec![7u8; n];
            assert_eq!(cbor_unwrap_bytes(&cbor_bytes(&data)).unwrap(), &data[..]);
        }
    }
}
