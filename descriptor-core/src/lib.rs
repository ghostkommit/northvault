//! Public-only descriptor validation. No wallet persistence, network or signing.
use miniscript::descriptor::{ShInner, WshInner};
use miniscript::{Descriptor, DescriptorPublicKey as Key, ForEachKey, Terminal};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{c_char, CStr, CString},
    str::FromStr,
};
type Desc = Descriptor<Key>;
#[derive(Deserialize)]
struct Request {
    receive: String,
    change: Option<String>,
    network: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Cosigner {
    xpub: String,
    fingerprint: String,
    origin: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Validated {
    receive: String,
    change: String,
    source_receive: String,
    source_change: Option<String>,
    network: String,
    threshold: usize,
    script_type: String,
    cosigners: Vec<Cosigner>,
    canonical_identity: String,
}
fn wsh(w: &miniscript::descriptor::Wsh<Key>) -> Result<(usize, bool), String> {
    match w.as_inner() {
        WshInner::SortedMulti(m) => Ok((m.k(), true)),
        WshInner::Ms(m) => match &m.node {
            Terminal::Multi(t) => Ok((t.k(), false)),
            _ => Err("Unsupported script policy".into()),
        },
    }
}
fn policy(d: &Desc) -> Result<(String, usize, bool), String> {
    let (kind, m, sorted) = match d {
        Descriptor::Pkh(_) => ("pkh", 1, false),
        Descriptor::Wpkh(_) => ("wpkh", 1, false),
        Descriptor::Tr(t) if t.tap_tree().is_none() => ("tr", 1, false),
        Descriptor::Wsh(w) => {
            let (m, s) = wsh(w)?;
            ("wsh", m, s)
        }
        Descriptor::Sh(s) => match s.as_inner() {
            ShInner::Wpkh(_) => ("sh-wpkh", 1, false),
            ShInner::Wsh(w) => {
                let (m, s) = wsh(w)?;
                ("sh-wsh", m, s)
            }
            ShInner::SortedMulti(m) => ("sh", m.k(), true),
            ShInner::Ms(m) => match &m.node {
                Terminal::Multi(t) => ("sh", t.k(), false),
                _ => return Err("Unsupported script policy".into()),
            },
        },
        _ => return Err("Unsupported script policy".into()),
    };
    Ok((kind.into(), m, sorted))
}
fn keys(d: &Desc, main: bool) -> Result<Vec<Cosigner>, String> {
    let mut keys = Vec::new();
    let mut valid = true;
    d.for_each_key(|k| {
        match k {
            Key::XPub(x) if x.wildcard == miniscript::descriptor::Wildcard::Unhardened => {
                if let Some((fp, path)) = &x.origin {
                    if x.xkey.network.is_mainnet() != main {
                        valid = false;
                    }
                    keys.push(Cosigner { xpub: x.xkey.to_string(), fingerprint: fp.to_string().to_uppercase(), origin: path.to_string() });
                } else {
                    valid = false;
                }
            }
            _ => valid = false,
        };
        true
    });
    if !valid || keys.is_empty() {
        return Err("Expected public extended keys with origins, network and unhardened wildcard".into());
    }
    Ok(keys)
}
fn canonical(d: &Desc) -> Result<String, String> {
    let (kind, m, sorted) = policy(d)?;
    let mut keys = Vec::new();
    d.for_each_key(|k| {
        keys.push(k.to_string());
        true
    });
    if sorted {
        keys.sort();
    }
    serde_json::to_string(&(kind, m, sorted, keys)).map_err(|_| "Invalid descriptor".into())
}
fn validate(r: Request) -> Result<Validated, String> {
    if r.receive.len() > 131072 || r.change.as_ref().is_some_and(|s| s.len() > 131072) {
        return Err("Descriptor too large".into());
    }
    let main = match r.network.as_str() {
        "mainnet" => true,
        "testnet" | "signet" | "regtest" => false,
        _ => return Err("Unsupported network".into()),
    };
    let parse = |s: &str| Desc::from_str(s.trim()).map_err(|_| "Invalid public descriptor or checksum".to_string());
    let input = parse(&r.receive)?;
    let (receive, change) = if let Some(s) = &r.change {
        let change = parse(s)?;
        if input.is_multipath() || change.is_multipath() {
            return Err("Separate descriptors must each have one branch".into());
        }
        (input, change)
    } else {
        let mut branches = input.into_single_descriptors().map_err(|_| "Invalid multipath descriptor")?;
        if branches.len() != 2 {
            return Err("Supply both receive and change descriptors, or a two-branch multipath descriptor".into());
        }
        let change = branches.pop().unwrap();
        (branches.pop().unwrap(), change)
    };
    receive.sanity_check().map_err(|_| "Unsafe descriptor")?;
    change.sanity_check().map_err(|_| "Unsafe descriptor")?;
    let (kind, threshold, _) = policy(&receive)?;
    if policy(&receive)? != policy(&change)? {
        return Err("Receive/change policies differ".into());
    }
    let cosigners = keys(&receive, main)?;
    let other = keys(&change, main)?;
    let identities = |ks: &Vec<Cosigner>| {
        let mut v: Vec<_> = ks.iter().map(|k| format!("{}:{}:{}", k.xpub, k.fingerprint, k.origin)).collect();
        v.sort();
        v
    };
    if identities(&cosigners) != identities(&other) {
        return Err("Receive/change cosigners differ".into());
    }
    let identity = serde_json::to_string(&(r.network.clone(), canonical(&receive)?, canonical(&change)?)).unwrap();
    Ok(Validated {
        receive: receive.to_string(),
        change: change.to_string(),
        source_receive: r.receive,
        source_change: r.change,
        network: r.network,
        threshold,
        script_type: kind,
        cosigners,
        canonical_identity: identity,
    })
}
/// Caller owns the returned UTF-8 JSON string and must free it with nv_descriptor_free.
///
/// # Safety
/// `input` must be null or point to a NUL-terminated string that stays valid for the call.
#[no_mangle]
pub unsafe extern "C" fn nv_descriptor_validate(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if input.is_null() {
            return serde_json::json!({"error":"Missing input"});
        }
        let result =
            CStr::from_ptr(input).to_str().ok().and_then(|s| serde_json::from_str::<Request>(s).ok()).ok_or("Invalid request".to_string()).and_then(validate);
        match result {
            Ok(v) => serde_json::json!({"value":v}),
            Err(e) => serde_json::json!({"error":e}),
        }
    })
    .unwrap_or_else(|_| serde_json::json!({"error":"Validation failed"}));
    CString::new(result.to_string()).unwrap().into_raw()
}
/// # Safety
/// `s` must be null or a pointer returned by `nv_descriptor_validate` that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn nv_descriptor_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
