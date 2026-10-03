//! State shared between the watch loop, which proposes rebalances, and the
//! executor, which acts on them.
//!
//! Without it the two sides could not see each other: the sweep re-proposed
//! every out-of-range position on every pass, including ones the hook would
//! refuse forever, and 64 such positions filled the intent queue so that every
//! position indexed after them was dropped on every pass (re-audit DS-4).

use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use dashmap::{DashMap, DashSet};

/// What the executor does after the hook refuses a preflight.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefusalAction {
    /// The price reference is behind spot or still settling. Poke it; the next
    /// sweep retries.
    Poke,
    /// The hook will refuse this position until its owner or the hook's owner
    /// changes something: automation off, a different rebalancer scoped, the
    /// requested range outside the owner's bounds, or the position closed.
    Terminal,
    /// The cooldown has not elapsed; it will on its own.
    Cooldown,
    /// Anything else. Retried with exponential backoff.
    Retry,
}

/// Suppression after a terminal refusal. Long, not permanent: an owner can
/// re-scope a position or widen its bounds.
pub const TERMINAL_SUPPRESS: Duration = Duration::from_secs(6 * 3600);
pub const COOLDOWN_SUPPRESS: Duration = Duration::from_secs(60);
const RETRY_BASE: Duration = Duration::from_secs(60);
const RETRY_MAX: Duration = Duration::from_secs(3600);
/// Entries untouched this long are dropped, so the maps do not grow with every
/// position that ever existed (re-audit DS-8).
const STALE_AFTER: Duration = Duration::from_secs(24 * 3600);

#[derive(Default)]
pub struct AutomationState {
    /// Positions with an intent queued but not yet taken by the executor. At
    /// most one each, so one position can never occupy more than one slot.
    in_flight: DashSet<String>,
    /// Positions not to be proposed before the given instant.
    suppressed: DashMap<String, Instant>,
    /// Consecutive retryable failures per position, for the backoff.
    strikes: DashMap<String, (u32, Instant)>,
}

pub fn automation() -> &'static AutomationState {
    static STATE: OnceLock<AutomationState> = OnceLock::new();
    STATE.get_or_init(Default::default)
}

impl AutomationState {
    /// Whether the sweep should skip proposing this position right now.
    pub fn is_blocked(&self, position_id: &str, now: Instant) -> bool {
        if self.in_flight.contains(position_id) {
            return true;
        }
        self.suppressed
            .get(position_id)
            .is_some_and(|until| now < *until)
    }

    /// Records a queued intent. False if one is already queued.
    pub fn mark_queued(&self, position_id: &str) -> bool {
        self.in_flight.insert(position_id.to_string())
    }

    pub fn mark_dequeued(&self, position_id: &str) {
        self.in_flight.remove(position_id);
    }

    /// Applies the outcome of a refusal or failure, returning how long the
    /// position is now suppressed for.
    pub fn on_refusal(&self, position_id: &str, action: RefusalAction, now: Instant) -> Duration {
        let wait = match action {
            RefusalAction::Poke => Duration::ZERO,
            RefusalAction::Terminal => TERMINAL_SUPPRESS,
            RefusalAction::Cooldown => COOLDOWN_SUPPRESS,
            RefusalAction::Retry => self.strike(position_id, now),
        };
        if wait > Duration::ZERO {
            self.suppressed.insert(position_id.to_string(), now + wait);
        }
        wait
    }

    /// A failure that warrants backing off: 60 s, doubling, capped at an hour.
    pub fn strike(&self, position_id: &str, now: Instant) -> Duration {
        let mut e = self
            .strikes
            .entry(position_id.to_string())
            .or_insert((0, now));
        e.0 = e.0.saturating_add(1);
        e.1 = now;
        let wait = RETRY_BASE
            .saturating_mul(1u32 << (e.0 - 1).min(16))
            .min(RETRY_MAX);
        drop(e);
        self.suppressed.insert(position_id.to_string(), now + wait);
        wait
    }

    pub fn on_success(&self, position_id: &str) {
        self.strikes.remove(position_id);
        self.suppressed.remove(position_id);
    }

    pub fn forget(&self, position_id: &str) {
        self.in_flight.remove(position_id);
        self.suppressed.remove(position_id);
        self.strikes.remove(position_id);
    }

    pub fn prune(&self, now: Instant) {
        self.suppressed.retain(|_, until| *until > now);
        self.strikes
            .retain(|_, (_, at)| now.duration_since(*at) < STALE_AFTER);
    }
}

/// Rolling one-hour cap on what the daemon spends across rebalances and pokes.
/// The per-transaction cap bounds one transaction; without this, anything that
/// can make the daemon send many cheap ones drains the wallet (re-audit DS-3).
pub struct SpendBudget {
    limit_usd_per_hour: f64,
    spent: Mutex<VecDeque<(Instant, f64)>>,
}

pub const DEFAULT_SPEND_USD_PER_HOUR: f64 = 100.0;
const BUDGET_WINDOW: Duration = Duration::from_secs(3600);

impl SpendBudget {
    pub fn new(limit_usd_per_hour: f64) -> Self {
        Self {
            limit_usd_per_hour,
            spent: Mutex::new(VecDeque::new()),
        }
    }

    pub fn from_env() -> Self {
        Self::new(
            std::env::var("LPA_MAX_SPEND_USD_PER_HOUR")
                .ok()
                .and_then(|v| v.parse().ok())
                .filter(|v: &f64| *v > 0.0)
                .unwrap_or(DEFAULT_SPEND_USD_PER_HOUR),
        )
    }

    /// Reserves `usd` if it fits in the last hour's budget.
    pub fn try_spend(&self, usd: f64, now: Instant) -> bool {
        let mut q = self.spent.lock().unwrap();
        while q
            .front()
            .is_some_and(|(t, _)| now.duration_since(*t) >= BUDGET_WINDOW)
        {
            q.pop_front();
        }
        let used: f64 = q.iter().map(|(_, c)| c).sum();
        if used + usd > self.limit_usd_per_hour {
            return false;
        }
        q.push_back((now, usd));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_refusal_suppresses_and_in_flight_dedupes() {
        let s = AutomationState::default();
        let t = Instant::now();
        assert!(s.mark_queued("p"));
        assert!(!s.mark_queued("p"), "one in-flight intent per position");
        assert!(s.is_blocked("p", t));
        s.mark_dequeued("p");
        assert!(!s.is_blocked("p", t));

        assert_eq!(
            s.on_refusal("p", RefusalAction::Terminal, t),
            TERMINAL_SUPPRESS
        );
        assert!(s.is_blocked("p", t + Duration::from_secs(3600)));
        assert!(!s.is_blocked("p", t + TERMINAL_SUPPRESS));
        assert_eq!(s.on_refusal("p", RefusalAction::Poke, t), Duration::ZERO);
    }

    #[test]
    fn retry_backoff_doubles_and_resets_on_success() {
        let s = AutomationState::default();
        let t = Instant::now();
        assert_eq!(
            s.on_refusal("p", RefusalAction::Retry, t),
            Duration::from_secs(60)
        );
        assert_eq!(
            s.on_refusal("p", RefusalAction::Retry, t),
            Duration::from_secs(120)
        );
        assert_eq!(
            s.on_refusal("p", RefusalAction::Retry, t),
            Duration::from_secs(240)
        );
        for _ in 0..20 {
            s.on_refusal("p", RefusalAction::Retry, t);
        }
        assert_eq!(s.on_refusal("p", RefusalAction::Retry, t), RETRY_MAX);
        s.on_success("p");
        assert!(!s.is_blocked("p", t));
        assert_eq!(
            s.on_refusal("p", RefusalAction::Retry, t),
            Duration::from_secs(60)
        );
    }

    #[test]
    fn spend_budget_is_a_rolling_hour() {
        let b = SpendBudget::new(10.0);
        let t = Instant::now();
        assert!(b.try_spend(6.0, t));
        assert!(!b.try_spend(6.0, t), "over the hourly cap");
        assert!(b.try_spend(4.0, t));
        assert!(!b.try_spend(0.01, t + Duration::from_secs(3599)));
        assert!(
            b.try_spend(6.0, t + Duration::from_secs(3600)),
            "window rolled"
        );
    }
}
