//! BC-UR animated QR codes: PSBTs (`crypto-psbt`, read by Jade, Keystone,
//! Passport, SeedSigner), account keys scanned from a signer (`crypto-account`,
//! BCR-2020-015) and wallet descriptors shown to one (`crypto-output`, BCR-2020-010).

use std::sync::Mutex;

use bdk_wallet::bitcoin::bip32::{ChainCode, ChildNumber, Fingerprint, Xpub};
use bdk_wallet::bitcoin::{secp256k1, NetworkKind, Psbt};
use minicbor::data::{Tag, Type};

use crate::interop::psbt_io;
use crate::models::*;
use crate::wallet::descriptor::{self, fmt_path, parse_xpub, ParsedKey};

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
fn parts(payload: &[u8], ur_type: &'static str) -> Result<Vec<String>, WalletError> {
    let mut encoder = ur::Encoder::new(payload, FRAGMENT_LEN, ur_type).map_err(ur_error)?;
    let count = encoder.fragment_count();
    if count == 1 {
        return Ok(vec![ur::encode(payload, &ur::Type::Custom(ur_type)).to_uppercase()]);
    }
    (0..count * 3).map(|_| encoder.next_part().map(|p| p.to_uppercase()).map_err(ur_error)).collect()
}

pub fn psbt_to_parts(psbt: &Psbt) -> Result<Vec<String>, WalletError> {
    parts(&cbor_bytes(&psbt.serialize()), "crypto-psbt")
}

// Registry tags (BCR-2020-006) for keys, paths, networks and script expressions.
const HDKEY: u64 = 303;
const KEYPATH: u64 = 304;
const COIN_INFO: u64 = 305;
const SORTEDMULTI: u64 = 407;
/// A cosigner marker some signers add inside multisig account entries.
const COSIGNER: u64 = 410;

/// Script expression tags around the key, outermost first: sh 400, wsh 401, pkh 403, wpkh 404, tr 409.
fn script_tags(script: ScriptType) -> &'static [u64] {
    match script {
        ScriptType::P2pkh => &[403],
        ScriptType::P2shP2wpkh => &[400, 404],
        ScriptType::P2wpkh => &[404],
        ScriptType::P2tr => &[409],
        ScriptType::P2sh => &[400],
        ScriptType::P2shP2wsh => &[400, 401],
        ScriptType::P2wsh => &[401],
    }
}

/// The wallet as a `crypto-output` animated QR, so a stateless signer such as
/// SeedSigner can recognize its change. Keys carry their origin and `/0/*`;
/// readers widen that to the change branch themselves, as BCR-2020-010 expects.
pub fn descriptor_to_parts(config: &WalletConfig, network: Network) -> Result<Vec<String>, WalletError> {
    let keys = descriptor::validate(config, network)?;
    let mut e = minicbor::Encoder::new(Vec::new());
    let encoded = (|| {
        for tag in script_tags(config.script_type) {
            e.tag(Tag::new(*tag))?;
        }
        if config.script_type.is_multisig() {
            e.tag(Tag::new(SORTEDMULTI))?.map(2)?.u32(1)?.u32(config.threshold)?.u32(2)?.array(keys.len() as u64)?;
        }
        for key in &keys {
            write_hdkey(&mut e, key, network)?;
        }
        Ok::<_, minicbor::encode::Error<std::convert::Infallible>>(())
    })();
    encoded.expect("encoding into memory cannot fail");
    parts(&e.into_writer(), "crypto-output")
}

fn write_hdkey(e: &mut minicbor::Encoder<Vec<u8>>, key: &ParsedKey, network: Network) -> Result<(), minicbor::encode::Error<std::convert::Infallible>> {
    let test = network != Network::Bitcoin;
    e.tag(Tag::new(HDKEY))?.map(if test { 6 } else { 5 })?;
    e.u32(3)?.bytes(&key.xpub.public_key.serialize())?;
    e.u32(4)?.bytes(key.xpub.chain_code.as_bytes())?;
    if test {
        e.u32(5)?.tag(Tag::new(COIN_INFO))?.map(1)?.u32(2)?.u32(1)?;
    }
    e.u32(6)?.tag(Tag::new(KEYPATH))?.map(3)?.u32(1)?.array(2 * key.path.len() as u64)?;
    for child in key.path.into_iter() {
        e.u32(u32::from(*child) & 0x7fff_ffff)?.bool(child.is_hardened())?;
    }
    e.u32(2)?.u32(u32::from_be_bytes(key.fingerprint.to_bytes()))?.u32(3)?.u8(key.xpub.depth)?;
    e.u32(7)?.tag(Tag::new(KEYPATH))?.map(1)?.u32(1)?.array(4)?.u32(0)?.bool(false)?.array(0)?.bool(false)?;
    // Always written: without it, readers drop the origin of a depth-1 key.
    e.u32(8)?.u32(u32::from_be_bytes(key.xpub.parent_fingerprint.to_bytes()))?;
    Ok(())
}

/// Reads the key for `script` from a `crypto-account` payload. The signer
/// lists one entry per script type; only the matching one is accepted.
fn account_keystore(cbor: &[u8], script: ScriptType, network: Network) -> Result<Keystore, WalletError> {
    let mut d = minicbor::Decoder::new(cbor);
    let mut master = None;
    let mut found = None;
    for _ in 0..map_len(&mut d)? {
        match d.u32().map_err(unreadable)? {
            1 => master = Some(d.u32().map_err(unreadable)?),
            2 => {
                for _ in 0..array_len(&mut d)? {
                    let mut tags = Vec::new();
                    while d.datatype().map_err(unreadable)? == Type::Tag {
                        tags.push(d.tag().map_err(unreadable)?.as_u64());
                    }
                    tags.retain(|t| *t != COSIGNER);
                    if found.is_none() && tags.split_last() == Some((&HDKEY, script_tags(script))) {
                        found = Some(read_hdkey(&mut d)?);
                    } else {
                        d.skip().map_err(unreadable)?;
                    }
                }
            }
            _ => d.skip().map_err(unreadable)?,
        }
    }
    let master = Fingerprint::from(master.ok_or(WalletError::interop("the account QR has no master fingerprint"))?.to_be_bytes());
    let key = found.ok_or(WalletError::interop("this account QR has no key for the selected script type"))?;
    if key.source.is_some_and(|source| source != master) {
        return Err(WalletError::interop("the key's origin doesn't match the account fingerprint"));
    }
    let depth = key.depth.unwrap_or(key.path.len());
    if depth != key.path.len() {
        return Err(WalletError::interop("the key's depth doesn't match its derivation path"));
    }
    let parent = match (key.parent, depth) {
        (Some(parent), _) => parent,
        (None, 1) => master,
        (None, _) => return Err(WalletError::interop("the key is missing its parent fingerprint")),
    };
    let xpub = Xpub {
        network: if key.test { NetworkKind::Test } else { NetworkKind::Main },
        depth: depth as u8,
        parent_fingerprint: parent,
        child_number: key.path.last().copied().unwrap_or(ChildNumber::Normal { index: 0 }),
        public_key: secp256k1::PublicKey::from_slice(&key.public_key).map_err(|_| WalletError::interop("the account QR has an invalid public key"))?,
        chain_code: ChainCode::from(
            <[u8; 32]>::try_from(key.chain_code.as_slice()).map_err(|_| WalletError::interop("the account QR has an invalid chain code"))?,
        ),
    };
    let keystore = Keystore {
        label: "Keystore".into(),
        fingerprint: master.to_string(),
        derivation_path: fmt_path(&key.path.into()),
        // Rejects a key whose declared network isn't the wallet's.
        xpub: parse_xpub(&xpub.to_string(), network)?.to_string(),
        device: None,
    };
    super::checked(keystore, script, network)
}

struct HdKey {
    public_key: Vec<u8>,
    chain_code: Vec<u8>,
    test: bool,
    path: Vec<ChildNumber>,
    source: Option<Fingerprint>,
    depth: Option<usize>,
    parent: Option<Fingerprint>,
}

fn read_hdkey(d: &mut minicbor::Decoder) -> Result<HdKey, WalletError> {
    let mut key = HdKey { public_key: Vec::new(), chain_code: Vec::new(), test: false, path: Vec::new(), source: None, depth: None, parent: None };
    let mut origin = false;
    for _ in 0..map_len(d)? {
        match d.u32().map_err(unreadable)? {
            1 => return Err(WalletError::interop("the account QR holds a master key, not an account key")),
            2 => return Err(WalletError::PrivateKeyNotAllowed),
            3 => key.public_key = d.bytes().map_err(unreadable)?.to_vec(),
            4 => key.chain_code = d.bytes().map_err(unreadable)?.to_vec(),
            5 => {
                expect_tag(d, COIN_INFO)?;
                for _ in 0..map_len(d)? {
                    match d.u32().map_err(unreadable)? {
                        2 => key.test = d.u32().map_err(unreadable)? != 0,
                        _ => d.skip().map_err(unreadable)?,
                    }
                }
            }
            6 => {
                expect_tag(d, KEYPATH)?;
                origin = true;
                for _ in 0..map_len(d)? {
                    match d.u32().map_err(unreadable)? {
                        1 => {
                            let n = array_len(d)?;
                            if n % 2 != 0 {
                                return Err(WalletError::interop("unreadable account QR (odd path)"));
                            }
                            for _ in 0..n / 2 {
                                if d.datatype().map_err(unreadable)? == Type::Array {
                                    return Err(WalletError::interop("the key's origin can't contain a wildcard"));
                                }
                                let index = d.u32().map_err(unreadable)?;
                                let child =
                                    if d.bool().map_err(unreadable)? { ChildNumber::from_hardened_idx(index) } else { ChildNumber::from_normal_idx(index) };
                                key.path.push(child.map_err(|_| WalletError::interop("the key's origin has an invalid index"))?);
                            }
                        }
                        2 => key.source = Some(Fingerprint::from(d.u32().map_err(unreadable)?.to_be_bytes())),
                        3 => key.depth = Some(d.u8().map_err(unreadable)? as usize),
                        _ => d.skip().map_err(unreadable)?,
                    }
                }
            }
            8 => key.parent = Some(Fingerprint::from(d.u32().map_err(unreadable)?.to_be_bytes())),
            _ => d.skip().map_err(unreadable)?,
        }
    }
    if !origin {
        return Err(WalletError::interop("the key has no derivation path"));
    }
    Ok(key)
}

fn unreadable(e: minicbor::decode::Error) -> WalletError {
    WalletError::interop(format!("unreadable account QR ({e})"))
}

fn expect_tag(d: &mut minicbor::Decoder, tag: u64) -> Result<(), WalletError> {
    if d.tag().map_err(unreadable)?.as_u64() != tag {
        return Err(WalletError::interop("unreadable account QR (unexpected tag)"));
    }
    Ok(())
}

/// Lengths are untrusted: indefinite lengths are refused and every element is
/// still read through the decoder, which fails at the end of the input.
fn map_len(d: &mut minicbor::Decoder) -> Result<u64, WalletError> {
    d.map().map_err(unreadable)?.ok_or(WalletError::interop("unreadable account QR (indefinite map)"))
}

fn array_len(d: &mut minicbor::Decoder) -> Result<u64, WalletError> {
    d.array().map_err(unreadable)?.ok_or(WalletError::interop("unreadable account QR (indefinite array)"))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Psbt,
    Account,
    /// A static key QR: plain `[fingerprint/path]xpub` text.
    Text,
}

/// Collects scanned QR frames until a PSBT is complete.
#[derive(uniffi::Object)]
pub struct UrDecoder {
    inner: Mutex<ur::Decoder>,
    single: Mutex<Option<Vec<u8>>>,
    kind: Mutex<Option<Kind>>,
}

#[uniffi::export]
impl UrDecoder {
    #[uniffi::constructor]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self { inner: Mutex::new(ur::Decoder::default()), single: Mutex::new(None), kind: Mutex::new(None) })
    }

    /// Feeds one scanned frame. Returns progress from 0 to 1.
    pub fn receive(&self, part: String) -> Result<f64, WalletError> {
        let original = part.trim();
        let part = original.to_lowercase();
        let kind = if !part.starts_with("ur:") {
            if original.starts_with('[') {
                Kind::Text
            } else {
                Kind::Psbt
            }
        } else if part.starts_with("ur:crypto-psbt/") || part.starts_with("ur:psbt/") {
            Kind::Psbt
        } else if part.starts_with("ur:crypto-account/") {
            Kind::Account
        } else {
            return Err(WalletError::interop("this QR code isn't a PSBT or an account key"));
        };
        // One scan is one payload: frames of another code type are refused.
        let mut current = self.kind.lock().unwrap();
        if current.is_some_and(|k| k != kind) {
            return Err(WalletError::interop("a different QR code was scanned; start again"));
        }
        let progress = self.feed(original, &part)?;
        // Recorded only once a frame is accepted, so a misread frame doesn't fix the type.
        *current = Some(kind);
        Ok(progress)
    }

    /// The scanned PSBT as base64 once complete.
    pub fn result(&self) -> Result<Option<String>, WalletError> {
        if matches!(self.kind(), Some(Kind::Account | Kind::Text)) {
            return Err(WalletError::interop("this QR code is an account key, not a PSBT"));
        }
        let Some(payload) = self.payload()? else { return Ok(None) };
        // CBOR byte-string prefixes 0x58/0x59 are ASCII X/Y, not base64.
        // Non-UR input was already parsed and stored as binary above.
        if payload.starts_with(b"psbt\xff") {
            return Ok(Some(psbt_io::to_base64(&psbt_io::decode(&payload)?)));
        }
        let psbt = psbt_io::decode(cbor_unwrap_bytes(&payload)?)?;
        Ok(Some(psbt_io::to_base64(&psbt)))
    }
}

impl UrDecoder {
    fn feed(&self, original: &str, part: &str) -> Result<f64, WalletError> {
        if !part.starts_with("ur:") {
            if original.starts_with('[') {
                *self.single.lock().unwrap() = Some(original.as_bytes().to_vec());
                return Ok(1.0);
            }
            // Some devices show a plain base64 PSBT.
            // Base64 is case-sensitive; normalize only the UR envelope.
            let psbt = psbt_io::from_base64(original)?;
            *self.single.lock().unwrap() = Some(psbt.serialize());
            return Ok(1.0);
        }
        let is_multipart = part.split('/').count() > 2;
        if !is_multipart {
            let (_, payload) = ur::decode(part).map_err(ur_error)?;
            *self.single.lock().unwrap() = Some(payload);
            return Ok(1.0);
        }
        // "ur:crypto-psbt/7-35/…": 35 fragments in total.
        let total: f64 = part.split('/').nth(1).and_then(|seq| seq.split('-').nth(1)).and_then(|n| n.parse().ok()).unwrap_or(1.0);
        let mut dec = self.inner.lock().unwrap();
        dec.receive(part).map_err(ur_error)?;
        let resolved = dec.resolved_fragment_count().unwrap_or(0) as f64;
        Ok(if dec.complete() { 1.0 } else { (resolved / total).min(0.99) })
    }

    fn kind(&self) -> Option<Kind> {
        *self.kind.lock().unwrap()
    }

    fn payload(&self) -> Result<Option<Vec<u8>>, WalletError> {
        if let Some(p) = self.single.lock().unwrap().clone() {
            return Ok(Some(p));
        }
        let dec = self.inner.lock().unwrap();
        if !dec.complete() {
            return Ok(None);
        }
        Ok(Some(dec.message().map_err(ur_error)?.unwrap_or_default()))
    }

    /// The scanned account key for `script`, once every frame is in.
    pub(crate) fn keystore(&self, script: ScriptType, network: Network) -> Result<Option<Keystore>, WalletError> {
        let kind = self.kind();
        if kind == Some(Kind::Psbt) {
            return Err(WalletError::interop("this QR code is a PSBT, not an account key"));
        }
        let Some(payload) = self.payload()? else { return Ok(None) };
        match kind {
            Some(Kind::Text) => super::import_keystore(&payload, script, network).map(Some),
            _ => account_keystore(&payload, script, network).map(Some),
        }
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
