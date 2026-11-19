//! SECURITY-SENSITIVE — requires human review before merge.
//!
//! Builds and parses the watch-only output descriptors behind every wallet.
//! Defaults follow Sparrow: BIP44/49/84/86 single-sig, BIP48 (and BIP45 for
//! P2SH) multisig with `sortedmulti`, change on `/1/*`. Only public keys are
//! ever accepted.

use std::str::FromStr;

use bdk_wallet::bitcoin::bip32::{ChildNumber, DerivationPath, Fingerprint, Xpub};
use bdk_wallet::bitcoin::{base58, Address, NetworkKind};
use bdk_wallet::miniscript::{Descriptor, DescriptorPublicKey, ForEachKey};

use crate::models::*;

pub type PubDescriptor = Descriptor<DescriptorPublicKey>;

// SLIP-132 version bytes. Public ones are mapped to plain xpub/tpub.
const XPUB: [u8; 4] = [0x04, 0x88, 0xb2, 0x1e];
const TPUB: [u8; 4] = [0x04, 0x35, 0x87, 0xcf];
const MAIN_PUBLIC: [[u8; 4]; 5] = [XPUB, [0x04, 0x9d, 0x7c, 0xb2], [0x04, 0xb2, 0x47, 0x46], [0x02, 0x95, 0xb4, 0x3f], [0x02, 0xaa, 0x7e, 0xd3]];
const TEST_PUBLIC: [[u8; 4]; 5] = [TPUB, [0x04, 0x4a, 0x52, 0x62], [0x04, 0x5f, 0x1c, 0xf6], [0x02, 0x42, 0x89, 0xef], [0x02, 0x57, 0x54, 0x83]];
const PRIVATE: [[u8; 4]; 10] = [
    [0x04, 0x88, 0xad, 0xe4],
    [0x04, 0x9d, 0x78, 0x78],
    [0x04, 0xb2, 0x43, 0x0c],
    [0x02, 0x95, 0xb0, 0x05],
    [0x02, 0xaa, 0x7a, 0x99],
    [0x04, 0x35, 0x83, 0x94],
    [0x04, 0x4a, 0x4e, 0x28],
    [0x04, 0x5f, 0x18, 0xbc],
    [0x02, 0x42, 0x85, 0xb5],
    [0x02, 0x57, 0x50, 0x48],
];

fn config_error(e: impl std::fmt::Display) -> WalletError {
    WalletError::config(e.to_string())
}

/// Parses an xpub in any SLIP-132 form (xpub, zpub, Zpub, tpub, vpub, …) for `network`.
pub fn parse_xpub(s: &str, network: Network) -> Result<Xpub, WalletError> {
    let mut data = base58::decode_check(s.trim()).map_err(|_| WalletError::config("not a valid extended public key"))?;
    if data.len() != 78 {
        return Err(WalletError::config("not a valid extended public key"));
    }
    let version: [u8; 4] = data[..4].try_into().expect("length checked");
    if PRIVATE.contains(&version) {
        return Err(WalletError::PrivateKeyNotAllowed);
    }
    let canonical = if MAIN_PUBLIC.contains(&version) {
        XPUB
    } else if TEST_PUBLIC.contains(&version) {
        TPUB
    } else {
        return Err(WalletError::config("unknown extended key version"));
    };
    data[..4].copy_from_slice(&canonical);
    let xpub = Xpub::decode(&data).map_err(config_error)?;
    if xpub.network != network_kind(network) {
        return Err(WalletError::WrongNetwork);
    }
    Ok(xpub)
}

pub fn parse_fingerprint(s: &str) -> Result<Fingerprint, WalletError> {
    let s = s.trim();
    if s.len() != 8 {
        return Err(WalletError::config("fingerprint must be 8 hex characters"));
    }
    Fingerprint::from_str(&s.to_lowercase()).map_err(|_| WalletError::config("fingerprint must be 8 hex characters"))
}

/// Accepts `m/84'/0'/0'`, `84h/0h/0h`, etc.
pub fn parse_path(s: &str) -> Result<DerivationPath, WalletError> {
    let s = s.trim();
    let s = s.strip_prefix("m/").or_else(|| s.strip_prefix("M/")).unwrap_or(if s == "m" { "" } else { s });
    if s.is_empty() {
        return Ok(DerivationPath::master());
    }
    DerivationPath::from_str(&format!("m/{s}")).map_err(|_| WalletError::config(format!("invalid derivation path: {s}")))
}

/// `m/48'/0'/0'/2'` (Sparrow / Coldcard style).
pub fn fmt_path(path: &DerivationPath) -> String {
    let mut out = String::from("m");
    for c in path {
        match c {
            ChildNumber::Hardened { index } => out += &format!("/{index}'"),
            ChildNumber::Normal { index } => out += &format!("/{index}"),
        }
    }
    out
}

pub fn network_kind(network: Network) -> NetworkKind {
    if network == Network::Bitcoin {
        NetworkKind::Main
    } else {
        NetworkKind::Test
    }
}

/// Sparrow's default account path for a script type.
pub fn default_path(script: ScriptType, network: Network) -> String {
    let c = if network == Network::Bitcoin { 0 } else { 1 };
    match script {
        ScriptType::P2pkh => format!("m/44'/{c}'/0'"),
        ScriptType::P2shP2wpkh => format!("m/49'/{c}'/0'"),
        ScriptType::P2wpkh => format!("m/84'/{c}'/0'"),
        ScriptType::P2tr => format!("m/86'/{c}'/0'"),
        ScriptType::P2sh => "m/45'".into(),
        ScriptType::P2shP2wsh => format!("m/48'/{c}'/0'/1'"),
        ScriptType::P2wsh => format!("m/48'/{c}'/0'/2'"),
    }
}

pub fn standard(script: ScriptType) -> &'static str {
    match script {
        ScriptType::P2pkh => "BIP44",
        ScriptType::P2shP2wpkh => "BIP49",
        ScriptType::P2wpkh => "BIP84",
        ScriptType::P2tr => "BIP86",
        ScriptType::P2sh => "BIP45",
        ScriptType::P2shP2wsh | ScriptType::P2wsh => "BIP48",
    }
}

pub fn policy_label(script: ScriptType, threshold: u32, keys: usize) -> String {
    match script {
        ScriptType::P2pkh => "Legacy".into(),
        ScriptType::P2shP2wpkh => "Nested SegWit".into(),
        ScriptType::P2wpkh => "Native SegWit".into(),
        ScriptType::P2tr => "Taproot".into(),
        _ => format!("Multisig {threshold}-of-{keys}"),
    }
}

const SCRIPTS: [ScriptType; 7] =
    [ScriptType::P2pkh, ScriptType::P2shP2wpkh, ScriptType::P2wpkh, ScriptType::P2tr, ScriptType::P2sh, ScriptType::P2shP2wsh, ScriptType::P2wsh];

/// Descriptor text around the key expression(s). The opening parts are
/// mutually exclusive prefixes, so `parse` can recognize the script type by them.
fn wrapper(script: ScriptType) -> (&'static str, &'static str) {
    match script {
        ScriptType::P2pkh => ("pkh(", ")"),
        ScriptType::P2shP2wpkh => ("sh(wpkh(", "))"),
        ScriptType::P2wpkh => ("wpkh(", ")"),
        ScriptType::P2tr => ("tr(", ")"),
        ScriptType::P2sh => ("sh(sortedmulti(", "))"),
        ScriptType::P2shP2wsh => ("sh(wsh(sortedmulti(", ")))"),
        ScriptType::P2wsh => ("wsh(sortedmulti(", "))"),
    }
}

/// A keystore with its parsed public data.
#[derive(Debug, Clone)]
pub struct ParsedKey {
    pub fingerprint: Fingerprint,
    pub path: DerivationPath,
    pub xpub: Xpub,
}

/// Checks a config and returns its parsed keys. Rejects anything that isn't
/// a plain single-sig or `sortedmulti` setup.
pub fn validate(config: &WalletConfig, network: Network) -> Result<Vec<ParsedKey>, WalletError> {
    if config.name.trim().is_empty() {
        return Err(WalletError::config("give the wallet a name"));
    }
    let n = config.keystores.len();
    let max = if config.script_type == ScriptType::P2sh { 15 } else { 20 };
    if config.script_type.is_multisig() {
        if n < 1 || n > max {
            return Err(WalletError::config(format!("multisig needs 1 to {max} keys")));
        }
        if config.threshold < 1 || config.threshold as usize > n {
            return Err(WalletError::config("required signatures must be between 1 and the number of keys"));
        }
    } else if n != 1 || config.threshold != 1 {
        return Err(WalletError::config("single-sig wallets have exactly one key"));
    }

    let mut keys: Vec<ParsedKey> = Vec::with_capacity(n);
    for ks in &config.keystores {
        let key = ParsedKey { fingerprint: parse_fingerprint(&ks.fingerprint)?, path: parse_path(&ks.derivation_path)?, xpub: parse_xpub(&ks.xpub, network)? };
        // A mismatch here usually means the wrong path was typed for this xpub.
        if usize::from(key.xpub.depth) != key.path.len() {
            return Err(WalletError::config(format!(
                "{}: derivation path {} doesn't match the key's depth ({})",
                ks.label, ks.derivation_path, key.xpub.depth
            )));
        }
        if keys.iter().any(|k| k.xpub == key.xpub) {
            return Err(WalletError::config(format!("{}: the same key was added twice", ks.label)));
        }
        keys.push(key);
    }
    Ok(keys)
}

/// Same config with canonical key data: lowercase fingerprint, `m/…'` path,
/// plain xpub/tpub instead of SLIP-132 forms. Stored records always use this.
pub fn normalize(config: &WalletConfig, network: Network) -> Result<WalletConfig, WalletError> {
    let keys = validate(config, network)?;
    let keystores = config
        .keystores
        .iter()
        .zip(keys)
        .map(|(ks, k)| Keystore {
            label: ks.label.trim().to_string(),
            fingerprint: k.fingerprint.to_string(),
            derivation_path: fmt_path(&k.path),
            xpub: k.xpub.to_string(),
            device: ks.device,
        })
        .collect();
    Ok(WalletConfig { name: config.name.trim().to_string(), script_type: config.script_type, threshold: config.threshold, keystores })
}

/// BIP389 multipath descriptor (`/<0;1>/*`) with checksum.
pub fn build(config: &WalletConfig, network: Network) -> Result<String, WalletError> {
    let keys = validate(config, network)?;
    let exprs: Vec<String> = keys.iter().map(|k| format!("[{}/{}]{}/<0;1>/*", k.fingerprint, k.path.to_string().replace('\'', "h"), k.xpub)).collect();
    let (open, close) = wrapper(config.script_type);
    let inner = if config.script_type.is_multisig() { format!("{},{}", config.threshold, exprs.join(",")) } else { exprs[0].clone() };
    let body = format!("{open}{inner}{close}");
    let desc = PubDescriptor::from_str(&body).map_err(config_error)?;
    Ok(desc.to_string())
}

/// Splits a multipath descriptor into (receive, change).
pub fn split(multipath: &str) -> Result<(PubDescriptor, PubDescriptor), WalletError> {
    let desc = PubDescriptor::from_str(multipath).map_err(config_error)?;
    let mut singles = desc.into_single_descriptors().map_err(config_error)?;
    if singles.len() != 2 {
        return Err(WalletError::config("expected a receive and a change path"));
    }
    let change = singles.pop().expect("len 2");
    let receive = singles.pop().expect("len 2");
    Ok((receive, change))
}

pub fn address_at(desc: &PubDescriptor, index: u32, network: Network) -> Result<Address, WalletError> {
    desc.at_derivation_index(index).map_err(WalletError::backend)?.address(network.into()).map_err(WalletError::backend)
}

/// Parses an output descriptor (multipath, or a receive-only `/0/*` one) into
/// a config the user can review. The result is rebuilt and compared address
/// by address, so anything Northvault can't reproduce exactly is rejected.
pub fn parse(text: &str, name: &str, network: Network) -> Result<WalletConfig, WalletError> {
    let raw = text.trim();
    if raw.contains("prv") {
        return Err(WalletError::PrivateKeyNotAllowed);
    }
    let not_descriptor = |e| WalletError::interop(format!("not a descriptor ({e})"));
    let parsed = PubDescriptor::from_str(raw).map_err(not_descriptor)?;
    // Accept Bitcoin Core style receive descriptors by widening /0/* to /<0;1>/*.
    let multipath = if parsed.is_multipath() {
        parsed
    } else {
        let body = parsed.to_string();
        let body = body.split('#').next().unwrap_or_default();
        if !body.contains("/0/*") {
            return Err(WalletError::interop("descriptor must use /0/* for receive or /<0;1>/*"));
        }
        PubDescriptor::from_str(&body.replace("/0/*", "/<0;1>/*")).map_err(not_descriptor)?
    };

    let body = multipath.to_string();
    let script_type = SCRIPTS
        .into_iter()
        .find(|s| body.starts_with(wrapper(*s).0))
        .ok_or_else(|| WalletError::interop("only single-sig and sortedmulti descriptors are supported"))?;
    let threshold = if script_type.is_multisig() {
        let after = body.split("sortedmulti(").nth(1).unwrap_or_default();
        after.split(',').next().and_then(|t| t.parse().ok()).ok_or(WalletError::interop("missing threshold"))?
    } else {
        1
    };

    let mut keystores = Vec::new();
    let mut missing_origin = false;
    multipath.for_each_key(|k| {
        match k {
            DescriptorPublicKey::MultiXPub(x) => match &x.origin {
                Some((fp, path)) => keystores.push(Keystore {
                    label: format!("Keystore {}", keystores.len() + 1),
                    fingerprint: fp.to_string(),
                    derivation_path: fmt_path(path),
                    xpub: x.xkey.to_string(),
                    device: None,
                }),
                None => missing_origin = true,
            },
            _ => missing_origin = true,
        }
        true
    });
    if missing_origin {
        return Err(WalletError::interop("every key needs its origin [fingerprint/path] and a /<0;1>/* path"));
    }

    let config = WalletConfig { name: name.trim().to_string(), script_type, threshold, keystores };
    let rebuilt = build(&config, network)?;
    ensure_same_addresses(&multipath.to_string(), &rebuilt, network)?;
    Ok(config)
}

/// Fails unless both descriptors produce the same first receive and change addresses.
pub fn ensure_same_addresses(a: &str, b: &str, network: Network) -> Result<(), WalletError> {
    let (ar, ac) = split(a)?;
    let (br, bc) = split(b)?;
    for i in 0..3 {
        if address_at(&ar, i, network)? != address_at(&br, i, network)? || address_at(&ac, i, network)? != address_at(&bc, i, network)? {
            return Err(WalletError::interop("descriptor layout isn't supported (addresses don't match)"));
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    // BIP84/BIP86/BIP49 test vectors (mnemonic "abandon … about", fingerprint 73c5da0a).
    pub const ZPUB: &str = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs";
    const BIP86_XPUB: &str = "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ";
    const YPUB: &str = "ypub6Ww3ibxVfGzLrAH1PNcjyAWenMTbbAosGNB6VvmSEgytSER9azLDWCxoJwW7Ke7icmizBMXrzBx9979FfaHxHcrArf3zbeJJJUZPf663zsP";
    pub const FP: &str = "73c5da0a";

    pub fn single(script: ScriptType, path: &str, xpub: &str) -> WalletConfig {
        WalletConfig {
            name: "Test".into(),
            script_type: script,
            threshold: 1,
            keystores: vec![Keystore { label: "A".into(), fingerprint: FP.into(), derivation_path: path.into(), xpub: xpub.into(), device: None }],
        }
    }

    fn first(config: &WalletConfig) -> (String, String) {
        let (r, c) = split(&build(config, Network::Bitcoin).unwrap()).unwrap();
        (address_at(&r, 0, Network::Bitcoin).unwrap().to_string(), address_at(&c, 0, Network::Bitcoin).unwrap().to_string())
    }

    #[test]
    fn bip84_vector() {
        let (r, c) = first(&single(ScriptType::P2wpkh, "m/84'/0'/0'", ZPUB));
        assert_eq!(r, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu");
        assert_eq!(c, "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el");
    }

    #[test]
    fn bip86_vector() {
        let (r, _) = first(&single(ScriptType::P2tr, "m/86'/0'/0'", BIP86_XPUB));
        assert_eq!(r, "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr");
    }

    #[test]
    fn bip49_vector() {
        let (r, _) = first(&single(ScriptType::P2shP2wpkh, "m/49'/0'/0'", YPUB));
        assert_eq!(r, "37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf");
    }

    #[test]
    fn rejects_private_keys_and_wrong_network() {
        let xprv = "xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi";
        assert!(matches!(parse_xpub(xprv, Network::Bitcoin), Err(WalletError::PrivateKeyNotAllowed)));
        assert!(matches!(parse_xpub(ZPUB, Network::Signet), Err(WalletError::WrongNetwork)));
        assert!(matches!(parse(&format!("wpkh({xprv}/0/*)"), "x", Network::Bitcoin), Err(WalletError::PrivateKeyNotAllowed)));
    }

    #[test]
    fn normalize_converts_slip132() {
        let config = single(ScriptType::P2wpkh, "84h/0h/0h", ZPUB);
        let n = normalize(&config, Network::Bitcoin).unwrap();
        assert!(n.keystores[0].xpub.starts_with("xpub"));
        assert_eq!(n.keystores[0].derivation_path, "m/84'/0'/0'");
        assert_eq!(build(&n, Network::Bitcoin).unwrap(), build(&config, Network::Bitcoin).unwrap());
    }

    #[test]
    fn path_depth_must_match() {
        let bad = single(ScriptType::P2wpkh, "m/84'/0'", ZPUB);
        assert!(matches!(validate(&bad, Network::Bitcoin), Err(WalletError::InvalidConfig { .. })));
    }

    #[test]
    fn descriptor_round_trip() {
        let config = single(ScriptType::P2wpkh, "m/84'/0'/0'", ZPUB);
        let desc = build(&config, Network::Bitcoin).unwrap();
        let back = parse(&desc, "Test", Network::Bitcoin).unwrap();
        assert_eq!(back.keystores[0].fingerprint, FP);
        assert_eq!(back.keystores[0].derivation_path, "m/84'/0'/0'");
        // Bitcoin Core style receive-only descriptor is widened to include change.
        let receive_only = split(&desc).unwrap().0.to_string();
        assert_eq!(build(&parse(&receive_only, "Test", Network::Bitcoin).unwrap(), Network::Bitcoin).unwrap(), desc);
    }
}
