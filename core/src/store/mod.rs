//! On-disk layout: `<data_dir>/<network>/wallets.json` (public wallet setups),
//! `<id>.sqlite` (BDK chain data) and `<id>.labels.jsonl` (BIP329 labels).
//! Nothing secret is stored: the app never has private keys.

use std::fs;
use std::path::{Path, PathBuf};

use bdk_wallet::bitcoin::hashes::{sha256, Hash};
use serde::{Deserialize, Serialize};

use crate::interop::labels::Labels;
use crate::models::*;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WalletRecord {
    pub id: String,
    pub name: String,
    pub script_type: ScriptType,
    pub threshold: u32,
    pub keystores: Vec<Keystore>,
    /// Multipath descriptor with checksum.
    pub descriptor: String,
    pub created_at: i64,
    /// Multisig registrations on Ledger devices. Older files have none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ledger_registrations: Vec<LedgerRegistration>,
}

/// What a Ledger returned when it registered this wallet's policy. The HMAC
/// isn't secret: it lets the device skip re-approving the same policy, and a
/// device rejects a policy or name it didn't register.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LedgerRegistration {
    pub fingerprint: String,
    /// The policy name shown on the device, part of what the HMAC covers.
    pub name: String,
    pub hmac: String,
}

impl WalletRecord {
    /// Same keys and policy always give the same id, so re-importing is detected.
    pub fn id_for(descriptor: &str) -> String {
        let hash = sha256::Hash::hash(descriptor.as_bytes()).to_string();
        hash[..12].to_string()
    }

    pub fn config(&self) -> WalletConfig {
        WalletConfig { name: self.name.clone(), script_type: self.script_type, threshold: self.threshold, keystores: self.keystores.clone() }
    }
}

#[derive(Serialize, Deserialize, Default)]
struct Registry {
    version: u32,
    wallets: Vec<WalletRecord>,
}

pub struct Store {
    dir: PathBuf,
}

impl Store {
    pub fn open(data_dir: &Path, network: Network) -> Result<Self, WalletError> {
        let name = match network {
            Network::Bitcoin => "bitcoin",
            Network::Testnet => "testnet",
            Network::Testnet4 => "testnet4",
            Network::Signet => "signet",
            Network::Regtest => "regtest",
        };
        let dir = data_dir.join(name);
        fs::create_dir_all(&dir).map_err(WalletError::backend)?;
        Ok(Self { dir })
    }

    pub fn load(&self) -> Result<Vec<WalletRecord>, WalletError> {
        match fs::read(self.dir.join("wallets.json")) {
            Ok(bytes) => Ok(serde_json::from_slice::<Registry>(&bytes).map_err(WalletError::backend)?.wallets),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(e) => Err(WalletError::backend(e)),
        }
    }

    pub fn save(&self, wallets: &[WalletRecord]) -> Result<(), WalletError> {
        let json = serde_json::to_vec_pretty(&Registry { version: 1, wallets: wallets.to_vec() }).map_err(WalletError::backend)?;
        write_atomic(&self.dir.join("wallets.json"), &json)
    }

    pub fn db_path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.sqlite"))
    }

    pub fn load_labels(&self, id: &str) -> Labels {
        let mut labels = Labels::default();
        if let Ok(text) = fs::read_to_string(self.labels_path(id)) {
            let _ = labels.merge_jsonl(&text);
        }
        labels
    }

    pub fn save_labels(&self, id: &str, labels: &Labels) -> Result<(), WalletError> {
        write_atomic(&self.labels_path(id), labels.to_jsonl(None).as_bytes())
    }

    pub fn remove(&self, id: &str) {
        let _ = fs::remove_file(self.db_path(id));
        let _ = fs::remove_file(self.labels_path(id));
    }

    fn labels_path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.labels.jsonl"))
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), WalletError> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes).map_err(WalletError::backend)?;
    fs::rename(&tmp, path).map_err(WalletError::backend)
}
