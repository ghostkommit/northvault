//! PSBT files: binary (Coldcard default) or base64 text.

use base64::{engine::general_purpose::STANDARD, Engine};
use bdk_wallet::bitcoin::Psbt;

use crate::models::WalletError;

const MAGIC: &[u8] = b"psbt\xff";

pub fn decode(bytes: &[u8]) -> Result<Psbt, WalletError> {
    if bytes.starts_with(MAGIC) {
        return Psbt::deserialize(bytes).map_err(|e| WalletError::interop(e.to_string()));
    }
    let text = std::str::from_utf8(bytes).map_err(|_| WalletError::interop("not a PSBT"))?;
    from_base64(text)
}

pub fn from_base64(text: &str) -> Result<Psbt, WalletError> {
    let cleaned: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    let raw = STANDARD.decode(cleaned).map_err(|_| WalletError::interop("not a PSBT"))?;
    Psbt::deserialize(&raw).map_err(|e| WalletError::interop(e.to_string()))
}

pub fn to_base64(psbt: &Psbt) -> String {
    STANDARD.encode(psbt.serialize())
}
