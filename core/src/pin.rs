//! SECURITY-SENSITIVE: transient Trezor credentials, never persisted or logged.
#[cfg(any(feature = "hardware", test))]
use crate::models::WalletError;
use std::sync::{Arc, Mutex};

/// Called on the hardware worker. The UI returns matrix positions, not PIN digits.
/// None means cancel. Implementations must provide a bounded user interaction.
#[uniffi::export(callback_interface)]
pub trait TrezorPinProvider: Send + Sync {
    fn request_pin(&self) -> Option<String>;
    /// Some("") explicitly selects the standard wallet; None cancels.
    fn request_passphrase(&self) -> Option<String>;
}

#[cfg(feature = "hardware")]
pub fn request_passphrase() -> Result<String, WalletError> {
    let provider = PROVIDER
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .ok_or_else(|| WalletError::device("Trezor passphrase entry is unavailable in this client"))?;
    validate_passphrase(provider.request_passphrase())
}

#[cfg(any(feature = "hardware", test))]
fn validate_passphrase(value: Option<String>) -> Result<String, WalletError> {
    let value = value.ok_or_else(|| WalletError::device("Trezor passphrase entry cancelled or timed out"))?;
    if value.len() > 50 {
        return Err(WalletError::device("Trezor host passphrase exceeds 50 UTF-8 bytes"));
    }
    // Preserve the exact input: trimming or normalizing could select another wallet.
    Ok(value)
}

static PROVIDER: Mutex<Option<Arc<dyn TrezorPinProvider>>> = Mutex::new(None);

#[uniffi::export]
pub fn set_trezor_pin_provider(provider: Box<dyn TrezorPinProvider>) {
    *PROVIDER.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::from(provider));
}

#[cfg(feature = "hardware")]
pub fn request() -> Result<String, WalletError> {
    let provider =
        PROVIDER.lock().unwrap_or_else(|e| e.into_inner()).clone().ok_or_else(|| WalletError::device("Trezor PIN entry is unavailable in this client"))?;
    validate(provider.request_pin())
}

#[cfg(any(feature = "hardware", test))]
fn validate(positions: Option<String>) -> Result<String, WalletError> {
    let positions = positions.ok_or_else(|| WalletError::device("Trezor PIN entry cancelled or timed out"))?;
    if positions.is_empty() || positions.len() > 50 || !positions.bytes().all(|b| (b'1'..=b'9').contains(&b)) {
        return Err(WalletError::device("invalid Trezor PIN matrix positions"));
    }
    Ok(positions)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn passphrase_preserves_exact_input_and_distinguishes_cancel() {
        assert_eq!(validate_passphrase(Some("".into())).unwrap(), "");
        assert_eq!(validate_passphrase(Some(" Space é ".into())).unwrap(), " Space é ");
        assert!(validate_passphrase(None).is_err());
        assert!(validate_passphrase(Some("a".repeat(51))).is_err());
    }
    #[test]
    fn accepts_only_bounded_matrix_positions() {
        assert!(validate(Some("789456123".into())).is_ok());
        assert!(validate(Some("1".repeat(50))).is_ok());
        for value in ["", "0", "12 3", "123\n", "١٢٣"] {
            assert!(validate(Some(value.into())).is_err());
        }
        assert!(validate(Some("1".repeat(51))).is_err());
        assert!(validate(None).is_err());
    }

    #[test]
    fn protocol_trace_logging_is_compiled_out() {
        // trezor-client logs outbound protobufs at TRACE, including PinMatrixAck.
        assert!(tracing::level_filters::STATIC_MAX_LEVEL <= tracing::level_filters::LevelFilter::INFO);
    }
}
