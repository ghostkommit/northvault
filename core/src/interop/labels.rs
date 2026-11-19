//! BIP329 wallet labels (JSON lines).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::models::WalletError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LabelType {
    Tx,
    Addr,
    Pubkey,
    Input,
    Output,
    Xpub,
}

#[derive(Debug, Serialize, Deserialize)]
struct Record {
    #[serde(rename = "type")]
    kind: LabelType,
    #[serde(rename = "ref")]
    reference: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    origin: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    spendable: Option<bool>,
}

#[derive(Debug, Default, Clone)]
pub struct Labels(BTreeMap<(LabelType, String), String>);

impl Labels {
    pub fn get(&self, kind: LabelType, reference: &str) -> Option<String> {
        self.0.get(&(kind, reference.to_string())).cloned()
    }

    /// Empty label removes it.
    pub fn set(&mut self, kind: LabelType, reference: &str, label: &str) {
        let label = label.trim();
        if label.is_empty() {
            self.0.remove(&(kind, reference.to_string()));
        } else {
            self.0.insert((kind, reference.to_string()), label.to_string());
        }
    }

    pub fn to_jsonl(&self, origin: Option<&str>) -> String {
        self.0
            .iter()
            .map(|((kind, reference), label)| {
                let record =
                    Record { kind: *kind, reference: reference.clone(), label: Some(label.clone()), origin: origin.map(String::from), spendable: None };
                serde_json::to_string(&record).expect("labels serialize") + "\n"
            })
            .collect()
    }

    /// Merges records from a BIP329 file; returns how many labels were imported.
    pub fn merge_jsonl(&mut self, text: &str) -> Result<usize, WalletError> {
        let mut count = 0;
        for (i, line) in text.lines().enumerate().filter(|(_, l)| !l.trim().is_empty()) {
            let r: Record = serde_json::from_str(line).map_err(|e| WalletError::interop(format!("line {}: {e}", i + 1)))?;
            if let Some(label) = r.label {
                self.set(r.kind, &r.reference, &label);
                count += 1;
            }
        }
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let mut l = Labels::default();
        l.set(LabelType::Tx, "f91d0a8a78462bc59398f2c5d7a84fcff491c26ba54c4833478b202796c8aafd", "Rent");
        l.set(LabelType::Addr, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", "Donations");
        let text = l.to_jsonl(Some("wpkh([73c5da0a/84h/0h/0h])"));
        let mut back = Labels::default();
        assert_eq!(back.merge_jsonl(&text).unwrap(), 2);
        assert_eq!(back.get(LabelType::Addr, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu").as_deref(), Some("Donations"));
        // A record with spendable flag and no label is accepted.
        assert_eq!(back.merge_jsonl(r#"{"type":"output","ref":"abc:0","spendable":false}"#).unwrap(), 0);
    }
}
