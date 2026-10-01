//! Per-replica metrics in the Prometheus text format (spec: "Metrics").
//! Plain atomics, rendered by hand: no metrics crate needed.

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Duration;

/// Histogram bucket upper bounds for Redis call latency, in seconds.
const LATENCY_BUCKETS: [f64; 9] = [0.0005, 0.001, 0.002, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25];

#[derive(Default)]
pub struct Metrics {
    pub bus_published: AtomicU64,
    pub bus_received: AtomicU64,
    pub slow_client_closes: AtomicU64,
    pub rate_limited_http: AtomicU64,
    pub rate_limited_ws: AtomicU64,
    redis_calls: AtomicU64,
    redis_errors: AtomicU64,
    /// Cumulative counts per LATENCY_BUCKETS bound.
    redis_latency_buckets: [AtomicU64; 9],
    redis_latency_micros: AtomicU64,
}

pub fn metrics() -> &'static Metrics {
    static METRICS: OnceLock<Metrics> = OnceLock::new();
    METRICS.get_or_init(Metrics::default)
}

impl Metrics {
    pub fn observe_redis(&self, elapsed: Duration, ok: bool) {
        self.redis_calls.fetch_add(1, Ordering::Relaxed);
        if !ok {
            self.redis_errors.fetch_add(1, Ordering::Relaxed);
        }
        self.redis_latency_micros
            .fetch_add(elapsed.as_micros() as u64, Ordering::Relaxed);
        let seconds = elapsed.as_secs_f64();
        for (bound, count) in LATENCY_BUCKETS.iter().zip(&self.redis_latency_buckets) {
            if seconds <= *bound {
                count.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    pub fn render(&self, replica_id: &str, sockets: (usize, usize), rooms: usize) -> String {
        let get = |counter: &AtomicU64| counter.load(Ordering::Relaxed);
        let mut out = String::new();
        let _ = writeln!(out, "# HELP relay_replica_info This relay replica.");
        let _ = writeln!(out, "# TYPE relay_replica_info gauge");
        let _ = writeln!(out, "relay_replica_info{{replica=\"{replica_id}\"}} 1");
        let _ = writeln!(out, "# HELP relay_sockets Live WebSockets on this replica.");
        let _ = writeln!(out, "# TYPE relay_sockets gauge");
        let _ = writeln!(out, "relay_sockets{{role=\"atem\"}} {}", sockets.0);
        let _ = writeln!(out, "relay_sockets{{role=\"astation\"}} {}", sockets.1);
        let _ = writeln!(
            out,
            "# HELP relay_rooms Rooms with a socket on this replica."
        );
        let _ = writeln!(out, "# TYPE relay_rooms gauge");
        let _ = writeln!(out, "relay_rooms {rooms}");
        for (name, help, value) in [
            (
                "relay_bus_published_total",
                "Messages published to other replicas.",
                get(&self.bus_published),
            ),
            (
                "relay_bus_received_total",
                "Messages received from the bus.",
                get(&self.bus_received),
            ),
            (
                "relay_slow_client_closes_total",
                "Sockets closed for a full send queue.",
                get(&self.slow_client_closes),
            ),
            (
                "relay_redis_calls_total",
                "Redis calls.",
                get(&self.redis_calls),
            ),
            (
                "relay_redis_errors_total",
                "Failed or timed-out Redis calls.",
                get(&self.redis_errors),
            ),
        ] {
            let _ = writeln!(out, "# HELP {name} {help}");
            let _ = writeln!(out, "# TYPE {name} counter");
            let _ = writeln!(out, "{name} {value}");
        }
        let _ = writeln!(
            out,
            "# HELP relay_rate_limited_total Requests refused by a rate or connection limit."
        );
        let _ = writeln!(out, "# TYPE relay_rate_limited_total counter");
        let _ = writeln!(
            out,
            "relay_rate_limited_total{{kind=\"http\"}} {}",
            get(&self.rate_limited_http)
        );
        let _ = writeln!(
            out,
            "relay_rate_limited_total{{kind=\"ws\"}} {}",
            get(&self.rate_limited_ws)
        );
        let _ = writeln!(
            out,
            "# HELP relay_redis_latency_seconds Redis call latency."
        );
        let _ = writeln!(out, "# TYPE relay_redis_latency_seconds histogram");
        for (bound, count) in LATENCY_BUCKETS.iter().zip(&self.redis_latency_buckets) {
            let _ = writeln!(
                out,
                "relay_redis_latency_seconds_bucket{{le=\"{bound}\"}} {}",
                get(count)
            );
        }
        let calls = get(&self.redis_calls);
        let _ = writeln!(
            out,
            "relay_redis_latency_seconds_bucket{{le=\"+Inf\"}} {calls}"
        );
        let _ = writeln!(
            out,
            "relay_redis_latency_seconds_sum {}",
            get(&self.redis_latency_micros) as f64 / 1_000_000.0
        );
        let _ = writeln!(out, "relay_redis_latency_seconds_count {calls}");
        out
    }
}

/// Test helper: a tiny check of the exposition line format.
#[cfg(test)]
pub(crate) fn assert_valid_exposition(text: &str) {
    let mut typed = std::collections::HashSet::new();
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("# TYPE ") {
            let mut parts = rest.split(' ');
            let name = parts.next().unwrap();
            let kind = parts.next().unwrap();
            assert!(["counter", "gauge", "histogram"].contains(&kind), "{line}");
            if kind == "counter" {
                assert!(name.ends_with("_total"), "counter without _total: {line}");
            }
            typed.insert(name.to_string());
        } else if line.starts_with("# HELP ") {
        } else {
            let (series, value) = line
                .rsplit_once(' ')
                .unwrap_or_else(|| panic!("bad line {line:?}"));
            value
                .parse::<f64>()
                .unwrap_or_else(|_| panic!("bad value in {line:?}"));
            let name = series.split('{').next().unwrap();
            let base = name
                .trim_end_matches("_bucket")
                .trim_end_matches("_sum")
                .trim_end_matches("_count");
            assert!(
                typed.contains(name) || typed.contains(base),
                "no TYPE for {line:?}"
            );
            if let Some(labels) = series.strip_prefix(name).filter(|l| !l.is_empty()) {
                assert!(labels.starts_with('{') && labels.ends_with('}'), "{line:?}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_prometheus_text() {
        let metrics = Metrics::default();
        metrics.bus_published.fetch_add(3, Ordering::Relaxed);
        metrics.bus_received.fetch_add(2, Ordering::Relaxed);
        metrics.slow_client_closes.fetch_add(1, Ordering::Relaxed);
        metrics.rate_limited_ws.fetch_add(4, Ordering::Relaxed);
        metrics.observe_redis(Duration::from_micros(700), true);
        metrics.observe_redis(Duration::from_millis(30), false);
        let text = metrics.render("a1b2c3d4e5f6", (7, 3), 5);
        for line in [
            "relay_replica_info{replica=\"a1b2c3d4e5f6\"} 1",
            "relay_sockets{role=\"atem\"} 7",
            "relay_sockets{role=\"astation\"} 3",
            "relay_rooms 5",
            "relay_bus_published_total 3",
            "relay_bus_received_total 2",
            "relay_slow_client_closes_total 1",
            "relay_rate_limited_total{kind=\"http\"} 0",
            "relay_rate_limited_total{kind=\"ws\"} 4",
            "relay_redis_calls_total 2",
            "relay_redis_errors_total 1",
            "relay_redis_latency_seconds_bucket{le=\"0.001\"} 1",
            "relay_redis_latency_seconds_bucket{le=\"0.05\"} 2",
            "relay_redis_latency_seconds_bucket{le=\"+Inf\"} 2",
            "relay_redis_latency_seconds_count 2",
            "# TYPE relay_redis_latency_seconds histogram",
        ] {
            assert!(
                text.lines().any(|l| l == line),
                "missing {line:?} in\n{text}"
            );
        }
        assert!(text.contains("relay_redis_latency_seconds_sum 0.0307"));
    }

    #[test]
    fn output_is_valid_exposition_and_counters_move() {
        let metrics = Metrics::default();
        assert_valid_exposition(&metrics.render("x", (0, 0), 0));
        let before = metrics.render("x", (0, 0), 0);
        metrics.rate_limited_http.fetch_add(2, Ordering::Relaxed);
        let after = metrics.render("x", (1, 2), 3);
        assert_valid_exposition(&after);
        assert_ne!(before, after);
        assert!(after.contains("relay_rate_limited_total{kind=\"http\"} 2"));
    }
}
