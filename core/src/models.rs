//! Types shared with Swift. uniffi turns snake_case fields into camelCase.

use serde::{Deserialize, Serialize};

/// Supported script types. Single-sig: P2pkh, P2shP2wpkh, P2wpkh, P2tr.
/// Multisig: P2sh, P2shP2wsh, P2wsh.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum ScriptType {
    P2pkh,
    P2shP2wpkh,
    P2wpkh,
    P2tr,
    P2sh,
    P2shP2wsh,
    P2wsh,
}

impl ScriptType {
    pub fn is_multisig(self) -> bool {
        matches!(self, Self::P2sh | Self::P2shP2wsh | Self::P2wsh)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum Network {
    Bitcoin,
    Testnet,
    Testnet4,
    Signet,
    Regtest,
}

impl From<Network> for bdk_wallet::bitcoin::Network {
    fn from(n: Network) -> Self {
        use bdk_wallet::bitcoin::Network as N;
        match n {
            Network::Bitcoin => N::Bitcoin,
            Network::Testnet => N::Testnet,
            Network::Testnet4 => N::Testnet4,
            Network::Signet => N::Signet,
            Network::Regtest => N::Regtest,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Chain {
    Receive,
    Change,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TimeRange {
    Week,
    Month,
    Quarter,
    Year,
    AllTime,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FiatCurrency {
    Usd,
    Eur,
    Gbp,
    Chf,
    Jpy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FeeLevel {
    Economy,
    Standard,
    Priority,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum DeviceKind {
    Coldcard,
    Trezor,
    Jade,
    Ledger,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Account {
    pub id: String,
    pub name: String,
    /// Human label, e.g. "Native SegWit" or "Multisig 2-of-3".
    pub policy: String,
    pub script_type: ScriptType,
    /// e.g. "BIP84"
    pub standard: String,
    pub derivation_path: String,
    pub is_multisig: bool,
    pub balance_sats: u64,
}

/// One cosigner (or the only signer) of a wallet. Public data only.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Keystore {
    pub label: String,
    /// Master key fingerprint, 8 lowercase hex chars.
    pub fingerprint: String,
    /// Account path, e.g. "m/48'/0'/0'/2'".
    pub derivation_path: String,
    /// Account xpub (tpub on test networks). SLIP-132 forms are converted on input.
    pub xpub: String,
    /// Device this key lives on, when known. Used for USB verification and signing.
    pub device: Option<DeviceKind>,
}

/// Everything needed to create a watch-only wallet. Also what imports return,
/// so the user can review the keys before the wallet is saved.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WalletConfig {
    pub name: String,
    pub script_type: ScriptType,
    /// Signatures required. 1 for single-sig.
    pub threshold: u32,
    pub keystores: Vec<Keystore>,
}

/// A wallet's public setup, for review and export screens.
#[derive(Debug, Clone, uniffi::Record)]
pub struct WalletDetails {
    pub account: Account,
    pub threshold: u32,
    pub keystores: Vec<Keystore>,
    // Keep "slash-star" out of exported doc comments: Swift block comments nest.
    /// BIP389 multipath descriptor (receive and change in one) with checksum.
    pub descriptor: String,
    pub first_receive_address: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct WalletTransaction {
    pub txid: String,
    pub account_id: String,
    /// Unix seconds.
    pub timestamp: i64,
    pub label: Option<String>,
    /// Positive = received, negative = sent (fee included).
    pub amount_sats: i64,
    /// Account balance after this transaction.
    pub balance_after_sats: u64,
    /// 0 = in mempool.
    pub confirmations: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Utxo {
    pub txid: String,
    pub vout: u32,
    pub account_id: String,
    pub address: String,
    pub value_sats: u64,
    pub timestamp: i64,
    pub label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct OutPoint {
    pub txid: String,
    pub vout: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AddressInfo {
    pub chain: Chain,
    pub index: u32,
    pub address: String,
    /// Full path, e.g. "m/84'/0'/0'/0/7".
    pub derivation_path: String,
    pub label: Option<String>,
    pub tx_count: u32,
    pub balance_sats: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NetWorthPoint {
    pub timestamp: i64,
    pub balance_sats: u64,
    /// BTC price at that time, in USD. Convert with `fx_rate_from_usd`.
    pub btc_price_usd: f64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FeeEstimate {
    pub level: FeeLevel,
    pub sat_per_vb: f64,
    pub target_blocks: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TxOutput {
    pub address: String,
    pub amount_sats: u64,
    /// Pays back to this wallet's change chain.
    pub is_change: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DraftTransaction {
    pub amount_sats: u64,
    pub fee_sats: u64,
    /// Estimated size once signed.
    pub vbytes: u32,
    pub total_sats: u64,
    pub balance_after_sats: u64,
    /// Unsigned PSBT, base64. Empty for the sample backend.
    pub psbt_base64: String,
    pub outputs: Vec<TxOutput>,
    pub effective_fee_rate: f64,
    /// Things the user should look at before signing (high fee, sending to self, …).
    pub warnings: Vec<String>,
}

/// How far a PSBT is from being broadcastable.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SignatureStatus {
    /// Signatures present on every input (minimum across inputs).
    pub signatures: u32,
    pub required: u32,
    /// Fingerprints of keystores that have signed.
    pub signed_by: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ExportFormat {
    /// Output descriptor text file.
    Descriptor,
    /// Coldcard multisig setup file (also read by Jade, Keystone, Passport).
    ColdcardMultisig,
    /// BIP129 descriptor record.
    Bsms,
    /// Specter DIY `addwallet` line, for its SD card or QR import.
    SpecterDiy,
    /// BIP329 labels (JSON lines).
    Labels,
}

/// A hardware wallet connected over USB.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HardwareDevice {
    /// Opaque handle for the `device_*` calls.
    pub id: String,
    pub kind: DeviceKind,
    pub model: String,
    /// None when the device is locked and has to be unlocked first.
    pub fingerprint: Option<String>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum WalletError {
    #[error("Unknown account")]
    UnknownAccount,
    #[error("That doesn't look like a valid Bitcoin address")]
    InvalidAddress,
    #[error("That address is for a different network")]
    WrongNetwork,
    #[error("Amount must be greater than zero")]
    ZeroAmount,
    #[error("Amount plus fee is more than the spendable balance")]
    InsufficientFunds { needed_sats: u64, available_sats: u64 },
    #[error("Fee rate is unreasonably high")]
    FeeTooHigh,
    #[error("Private keys can't be imported. Northvault is watch-only")]
    PrivateKeyNotAllowed,
    #[error("Invalid wallet setup: {message}")]
    InvalidConfig { message: String },
    #[error("Couldn't read this file: {message}")]
    Interop { message: String },
    #[error("The signed transaction doesn't match the one that was created")]
    PsbtMismatch,
    #[error("{signatures} of {required} signatures")]
    NotEnoughSignatures { signatures: u32, required: u32 },
    #[error("The device showed a different address ({device_address}). Don't use this address")]
    AddressMismatch { device_address: String },
    #[error("Hardware wallet: {message}")]
    Device { message: String },
    #[error("Server: {message}")]
    Server { message: String },
    #[error("Not available: {message}")]
    NotSupported { message: String },
    #[error("Wallet backend error: {message}")]
    Backend { message: String },
}

impl WalletError {
    pub fn backend(e: impl std::fmt::Display) -> Self {
        Self::Backend { message: e.to_string() }
    }
    pub fn config(m: impl Into<String>) -> Self {
        Self::InvalidConfig { message: m.into() }
    }
    pub fn interop(m: impl Into<String>) -> Self {
        Self::Interop { message: m.into() }
    }
    pub fn device(e: impl std::fmt::Display) -> Self {
        Self::Device { message: e.to_string() }
    }
    pub fn server(e: impl std::fmt::Display) -> Self {
        Self::Server { message: e.to_string() }
    }
}

/// What a label is attached to (BIP329 types used by the UI).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LabelKind {
    Transaction,
    Address,
    Output,
}
