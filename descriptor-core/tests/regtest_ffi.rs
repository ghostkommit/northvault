//! Exercise the same allocated JSON C ABI used by Swift, using synthetic Regtest keys.
use std::ffi::{CStr, CString};

use miniscript::bitcoin::{
    bip32::{DerivationPath, Xpriv, Xpub},
    secp256k1::Secp256k1,
    NetworkKind,
};
use northvault_descriptor::{nv_descriptor_free, nv_descriptor_validate};
use serde_json::{json, Value};

fn call_bytes(bytes: &[u8]) -> Value {
    let request = CString::new(bytes).unwrap();
    unsafe {
        let pointer = nv_descriptor_validate(request.as_ptr());
        assert!(!pointer.is_null());
        let response = CStr::from_ptr(pointer).to_bytes().to_vec();
        nv_descriptor_free(pointer);
        serde_json::from_slice(&response).unwrap()
    }
}

fn validate(receive: &str, change: Option<&str>, network: &str) -> Value {
    call_bytes(json!({"receive": receive, "change": change, "network": network}).to_string().as_bytes())
}

fn key(id: u8) -> String {
    let secp = Secp256k1::new();
    let master = Xpriv::new_master(NetworkKind::Test, &[id; 32]).unwrap();
    let account = master.derive_priv(&secp, &"m/48'/1'/0'/2'".parse::<DerivationPath>().unwrap()).unwrap();
    format!("[{}/48h/1h/0h/2h]{}/<0;1>/*", master.fingerprint(&secp), Xpub::from_priv(&secp, &account))
}

#[test]
fn every_supported_policy_roundtrips_through_allocated_ffi_json() {
    let a = key(1);
    let b = key(2);
    for (descriptor, script, threshold) in [
        (format!("pkh({a})"), "pkh", 1),
        (format!("wpkh({a})"), "wpkh", 1),
        (format!("tr({a})"), "tr", 1),
        (format!("sh(wpkh({a}))"), "sh-wpkh", 1),
        (format!("wsh(sortedmulti(2,{a},{b}))"), "wsh", 2),
        (format!("wsh(multi(2,{a},{b}))"), "wsh", 2),
        (format!("sh(wsh(sortedmulti(2,{a},{b})))"), "sh-wsh", 2),
        (format!("sh(wsh(multi(2,{a},{b})))"), "sh-wsh", 2),
        (format!("sh(sortedmulti(2,{a},{b}))"), "sh", 2),
        (format!("sh(multi(2,{a},{b}))"), "sh", 2),
    ] {
        let result = validate(&descriptor, None, "regtest");
        let value = &result["value"];
        assert!(value.is_object(), "valid policy rejected");
        assert_eq!(value["network"], "regtest");
        assert_eq!(value["scriptType"], script);
        assert_eq!(value["threshold"], threshold);
        assert_eq!(value["sourceReceive"], descriptor);
        let receive = value["receive"].as_str().unwrap();
        let change = value["change"].as_str().unwrap();
        assert!(receive.contains("/0/*"));
        assert!(change.contains("/1/*"));
        let pair = validate(receive, Some(change), "regtest");
        assert_eq!(pair["value"]["canonicalIdentity"], value["canonicalIdentity"]);
        assert!(validate(&descriptor, None, "mainnet")["error"].is_string());
        // A test xpub must retain the explicitly requested test network identity.
        for network in ["testnet", "signet"] {
            let other = validate(&descriptor, None, network);
            assert_eq!(other["value"]["network"], network);
            assert_ne!(other["value"]["canonicalIdentity"], value["canonicalIdentity"]);
        }
    }
}

#[test]
fn sorted_order_is_canonical_but_ordered_multisig_order_is_preserved() {
    let (a, b) = (key(1), key(2));
    for (policy, equivalent) in [("sortedmulti", true), ("multi", false)] {
        let original = validate(&format!("wsh({policy}(2,{a},{b}))"), None, "regtest");
        let reverse = validate(&format!("wsh({policy}(2,{b},{a}))"), None, "regtest");
        assert_eq!(original["value"]["canonicalIdentity"] == reverse["value"]["canonicalIdentity"], equivalent);
    }
}

#[test]
fn malformed_requests_and_descriptor_boundaries_fail_closed() {
    for bytes in [b"".as_slice(), b"{}", b"null", b"not json", &[0xff]] {
        assert!(call_bytes(bytes)["error"].is_string());
    }
    unsafe {
        let pointer = nv_descriptor_validate(std::ptr::null());
        let response: Value = serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()).unwrap();
        nv_descriptor_free(pointer);
        nv_descriptor_free(std::ptr::null_mut());
        assert!(response["error"].is_string());
    }
    let a = key(1);
    let good = format!("wpkh({a})");
    let private = Xpriv::new_master(NetworkKind::Test, &[3; 32]).unwrap();
    let without_origin = a.split(']').nth(1).unwrap();
    for invalid in [
        format!("{good}#deadbeef"),
        format!("wpkh({private}/<0;1>/*)"),
        format!("wpkh({without_origin})"),
        good.replace("/*", "/*h"),
        good.replace("/<0;1>/*", "/0/*"),
        good.replace("/<0;1>/*", "/<0;1;2>/*"),
        format!("wsh(sortedmulti(0,{a}))"),
        format!("wsh(sortedmulti(2,{a}))"),
        format!("wsh(and_v(v:pk({a}),older(5)))"),
        format!("sh(and_v(v:pk({a}),older(5)))"),
        format!("tr({a},pk({}))", key(2)),
        " ".repeat(131073),
    ] {
        assert!(validate(&invalid, None, "regtest")["error"].is_string(), "invalid descriptor accepted");
    }
    assert!(validate(&good, None, "unknown")["error"].is_string());
    assert!(validate(&good, Some(&good), "regtest")["error"].is_string());
    let receive = good.replace("/<0;1>/*", "/0/*");
    let wrong_keys = format!("wpkh({})", key(2)).replace("/<0;1>/*", "/1/*");
    let wrong_policy = format!("pkh({a})").replace("/<0;1>/*", "/1/*");
    for change in [wrong_keys, wrong_policy, " ".repeat(131073)] {
        assert!(validate(&receive, Some(&change), "regtest")["error"].is_string());
    }
    // Recover after failures: no shared parser state or poisoned allocation state.
    assert!(validate(&good, None, "regtest")["value"].is_object());
}
