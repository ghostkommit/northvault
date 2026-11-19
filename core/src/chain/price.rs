//! Prices and FX. Only sample data for now: a real feed needs a privacy and
//! dependency review before it is added (see DEVELOPMENT.md).

use crate::mock;
use crate::models::FiatCurrency;

pub trait PriceSource: Send + Sync {
    /// Daily close in USD, oldest first, ending today. `days + 1` entries.
    fn daily_usd(&self, days: usize) -> Vec<f64>;
    fn fx_rate_from_usd(&self, currency: FiatCurrency) -> f64;
}

pub struct SamplePrices;

impl PriceSource for SamplePrices {
    fn daily_usd(&self, days: usize) -> Vec<f64> {
        let all = mock::sample_prices();
        // The demo feed only contains one year. Keep recent dates aligned and
        // extend its oldest sample for longer charts, rather than emitting zeros.
        let mut prices = vec![all[0]; (days + 1).saturating_sub(all.len())];
        prices.extend_from_slice(&all[all.len().saturating_sub(days + 1)..]);
        prices
    }

    fn fx_rate_from_usd(&self, currency: FiatCurrency) -> f64 {
        mock::fx_rate(currency)
    }
}
