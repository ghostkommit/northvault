use miniscript::bitcoin::{
    bip32::{DerivationPath, Xpriv, Xpub},
    secp256k1::Secp256k1,
    NetworkKind,
};
use std::str::FromStr;
fn main() {
    let network = std::env::args().nth(1).unwrap_or_else(|| "mainnet".into());
    let (kind, coin) = match network.as_str() {
        "mainnet" => (NetworkKind::Main, 0),
        "regtest" => (NetworkKind::Test, 1),
        _ => panic!("expected mainnet or regtest"),
    };
    let secp = Secp256k1::new();
    let mut keys = Vec::new();
    for seed in 1..=3u8 {
        let master = Xpriv::new_master(kind, &[seed; 32]).unwrap();
        let path = DerivationPath::from_str(&format!("m/48h/{coin}h/0h/2h")).unwrap();
        let xpub = Xpub::from_priv(&secp, &master.derive_priv(&secp, &path).unwrap());
        keys.push(format!("[{}/48h/{coin}h/0h/2h]{}/<0;1>/*", master.fingerprint(&secp), xpub));
    }
    let multi = format!("wsh(sortedmulti(2,{}))", keys.join(","));
    let single = format!("wpkh({})", keys[0]);
    let reordered = format!("wsh(sortedmulti(2,{}))", keys.iter().rev().cloned().collect::<Vec<_>>().join(","));
    let ordered = format!("wsh(multi(2,{}))", keys.join(","));
    let ordered_reversed = format!("wsh(multi(2,{}))", keys.iter().rev().cloned().collect::<Vec<_>>().join(","));
    println!("{}", serde_json::json!({"multi":multi,"single":single,"reordered":reordered,"ordered":ordered,"orderedReversed":ordered_reversed}));
}
