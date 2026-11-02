//! Clock-independent delivery policy for a future authenticated push outbox.
//! This does not verify hosts/seen, persist jobs, or submit provider requests.
//! Callers must supply durable lifecycle/delivery state and recheck authority
//! immediately before each attempt. No notification decision closes a card.

pub const MOBILE_DELAY_MS: i64 = 60_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    DesktopInitial,
    DesktopReminder,
    Mobile,
}

#[derive(Clone, Copy)]
pub enum Preference {
    Desktop { reminder: bool },
    Mobile { immediate: bool },
    Disabled,
}

pub struct DeliveryState<'a> {
    pub authorized: bool,
    pub resolved: bool,
    pub actively_seen: bool,
    pub desktop_connected: bool,
    pub sent: &'a [Stage],
}

#[derive(Debug, PartialEq, Eq)]
pub enum Suppression {
    Unauthorized,
    Resolved,
    AlreadySent,
    NotSelected,
    Seen,
    DesktopConnected,
    DeliveryWindowClosed,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Send,
    WaitUntil(i64),
    Suppress(Suppression),
}

pub struct ApprovalWindow {
    created_at_ms: i64,
    stop_delivery_at_ms: i64,
}

impl ApprovalWindow {
    // The margin is supplied by the pinned contract; it is not an expiry for
    // the actionable approval. There is deliberately no receipt-time input.
    pub fn new(created_at_ms: i64, expires_at_ms: i64, margin_ms: i64) -> Option<Self> {
        if created_at_ms < 0 || expires_at_ms <= created_at_ms || margin_ms < 0 {
            return None;
        }
        created_at_ms.checked_add(MOBILE_DELAY_MS)?;
        Some(Self {
            created_at_ms,
            stop_delivery_at_ms: expires_at_ms.checked_sub(margin_ms)?,
        })
    }

    pub fn decide(
        &self,
        stage: Stage,
        preference: Preference,
        state: &DeliveryState<'_>,
        now_ms: i64,
    ) -> Decision {
        use Suppression::*;
        if !state.authorized {
            return Decision::Suppress(Unauthorized);
        }
        if state.resolved {
            return Decision::Suppress(Resolved);
        }
        if state.sent.contains(&stage) {
            return Decision::Suppress(AlreadySent);
        }
        if now_ms >= self.stop_delivery_at_ms {
            return Decision::Suppress(DeliveryWindowClosed);
        }
        let due = match (stage, preference) {
            (Stage::DesktopInitial, Preference::Desktop { .. }) => {
                if state.desktop_connected {
                    return Decision::Suppress(DesktopConnected);
                }
                self.created_at_ms
            }
            (Stage::DesktopReminder, Preference::Desktop { reminder: true }) => {
                self.created_at_ms + MOBILE_DELAY_MS
            }
            (Stage::Mobile, Preference::Mobile { immediate }) => {
                if state.actively_seen {
                    return Decision::Suppress(Seen);
                }
                self.created_at_ms + if immediate { 0 } else { MOBILE_DELAY_MS }
            }
            _ => return Decision::Suppress(NotSelected),
        };
        if due >= self.stop_delivery_at_ms {
            return Decision::Suppress(DeliveryWindowClosed);
        }
        if now_ms < due {
            Decision::WaitUntil(due)
        } else {
            Decision::Send
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CREATED: i64 = 1_793_264_005_000;
    const EXPIRES: i64 = CREATED + 300_000;
    const MARGIN: i64 = 15_000; // Test input, pending the joint protocol pin.

    fn window() -> ApprovalWindow {
        ApprovalWindow::new(CREATED, EXPIRES, MARGIN).unwrap()
    }
    fn state() -> DeliveryState<'static> {
        DeliveryState {
            authorized: true,
            resolved: false,
            actively_seen: false,
            desktop_connected: false,
            sent: &[],
        }
    }
    fn mobile(immediate: bool) -> Preference {
        Preference::Mobile { immediate }
    }
    fn desktop(reminder: bool) -> Preference {
        Preference::Desktop { reminder }
    }

    #[test]
    fn desktop_presence_only_routes_the_initial_os_notice() {
        assert_eq!(
            window().decide(Stage::DesktopInitial, desktop(false), &state(), CREATED),
            Decision::Send
        );
        let mut connected = state();
        connected.desktop_connected = true;
        assert_eq!(
            window().decide(Stage::DesktopInitial, desktop(false), &connected, CREATED),
            Decision::Suppress(Suppression::DesktopConnected)
        );
        assert_eq!(
            window().decide(Stage::Mobile, mobile(false), &connected, CREATED + 60_000),
            Decision::Send
        );
        connected.authorized = false;
        assert_eq!(
            window().decide(Stage::Mobile, mobile(false), &connected, CREATED + 60_000),
            Decision::Suppress(Suppression::Unauthorized)
        );
    }

    #[test]
    fn mobile_waits_exactly_sixty_seconds_unless_opted_into_immediate() {
        assert_eq!(
            window().decide(Stage::Mobile, mobile(false), &state(), CREATED + 59_999),
            Decision::WaitUntil(CREATED + 60_000)
        );
        assert_eq!(
            window().decide(Stage::Mobile, mobile(false), &state(), CREATED + 60_000),
            Decision::Send
        );
        assert_eq!(
            window().decide(Stage::Mobile, mobile(true), &state(), CREATED),
            Decision::Send
        );
    }

    #[test]
    fn late_admission_retry_and_restart_cannot_move_the_original_deadline() {
        for now in [CREATED + 90_000, CREATED + 120_000, CREATED + 180_000] {
            let restored = ApprovalWindow::new(CREATED, EXPIRES, MARGIN).unwrap();
            assert_eq!(
                restored.decide(Stage::Mobile, mobile(false), &state(), now),
                Decision::Send
            );
        }
        let sent = DeliveryState {
            sent: &[Stage::Mobile],
            ..state()
        };
        assert_eq!(
            window().decide(Stage::Mobile, mobile(true), &sent, CREATED + 180_000),
            Decision::Suppress(Suppression::AlreadySent)
        );
    }

    #[test]
    fn only_authenticated_active_seen_suppresses_mobile_without_resolving() {
        let mut seen = state();
        seen.actively_seen = true;
        for immediate in [false, true] {
            assert_eq!(
                window().decide(Stage::Mobile, mobile(immediate), &seen, CREATED + 60_000),
                Decision::Suppress(Suppression::Seen)
            );
        }
        assert!(!seen.resolved);
        assert_eq!(
            window().decide(Stage::DesktopInitial, desktop(false), &seen, CREATED),
            Decision::Send
        );
    }

    #[test]
    fn resolution_and_revocation_win_over_all_pending_or_retried_sends() {
        for stage in [Stage::DesktopInitial, Stage::DesktopReminder, Stage::Mobile] {
            let preference = if stage == Stage::Mobile {
                mobile(false)
            } else {
                desktop(true)
            };
            let resolved = DeliveryState {
                resolved: true,
                actively_seen: true,
                ..state()
            };
            assert_eq!(
                window().decide(stage, preference, &resolved, CREATED + 60_000),
                Decision::Suppress(Suppression::Resolved)
            );
            let revoked = DeliveryState {
                authorized: false,
                ..state()
            };
            assert_eq!(
                window().decide(stage, preference, &revoked, CREATED + 60_000),
                Decision::Suppress(Suppression::Unauthorized)
            );
        }
    }

    #[test]
    fn provider_cutoff_is_exact_and_does_not_resolve_the_card() {
        let state = state();
        assert_eq!(
            window().decide(Stage::Mobile, mobile(false), &state, EXPIRES - MARGIN - 1),
            Decision::Send
        );
        for now in [EXPIRES - MARGIN, EXPIRES, EXPIRES + 300_000] {
            assert_eq!(
                window().decide(Stage::Mobile, mobile(false), &state, now),
                Decision::Suppress(Suppression::DeliveryWindowClosed)
            );
        }
        assert!(!state.resolved);
    }

    #[test]
    fn optional_desktop_reminder_and_mobile_are_distinct_stages() {
        let sent = DeliveryState {
            sent: &[Stage::DesktopInitial],
            ..state()
        };
        assert_eq!(
            window().decide(
                Stage::DesktopReminder,
                desktop(false),
                &sent,
                CREATED + 60_000
            ),
            Decision::Suppress(Suppression::NotSelected)
        );
        assert_eq!(
            window().decide(
                Stage::DesktopReminder,
                desktop(true),
                &sent,
                CREATED + 59_999
            ),
            Decision::WaitUntil(CREATED + 60_000)
        );
        assert_eq!(
            window().decide(
                Stage::DesktopReminder,
                desktop(true),
                &sent,
                CREATED + 60_000
            ),
            Decision::Send
        );
        assert_eq!(
            window().decide(Stage::Mobile, mobile(false), &sent, CREATED + 60_000),
            Decision::Send
        );
    }

    #[test]
    fn preference_changes_cannot_duplicate_a_delivered_mobile_stage() {
        let sent = DeliveryState {
            sent: &[Stage::Mobile],
            ..state()
        };
        for immediate in [false, true] {
            assert_eq!(
                window().decide(Stage::Mobile, mobile(immediate), &sent, CREATED + 60_000),
                Decision::Suppress(Suppression::AlreadySent)
            );
        }
        assert_eq!(
            window().decide(
                Stage::Mobile,
                Preference::Disabled,
                &state(),
                CREATED + 60_000
            ),
            Decision::Suppress(Suppression::NotSelected)
        );
    }

    #[test]
    fn short_lifetimes_and_invalid_or_overflowing_times_fail_closed() {
        let short = ApprovalWindow::new(CREATED, CREATED + 60_000, MARGIN).unwrap();
        assert_eq!(
            short.decide(Stage::Mobile, mobile(false), &state(), CREATED),
            Decision::Suppress(Suppression::DeliveryWindowClosed)
        );
        assert_eq!(
            window().decide(Stage::Mobile, mobile(true), &state(), CREATED - 1),
            Decision::WaitUntil(CREATED)
        );
        for (created, expires, margin) in [
            (-1, EXPIRES, MARGIN),
            (CREATED, CREATED, MARGIN),
            (CREATED, CREATED - 1, MARGIN),
            (CREATED, EXPIRES, -1),
            (i64::MAX - 1, i64::MAX, 0),
        ] {
            assert!(ApprovalWindow::new(created, expires, margin).is_none());
        }
    }
}
