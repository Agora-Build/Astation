//! Connection admission (spec: "Connection limits"): at most
//! RELAY_WS_MAX_PER_IP concurrent `/ws` connections per client IP on each
//! replica. (The pending-Astation cap per room lives in the directory.)

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::http::HeaderMap;

pub const DEFAULT_WS_MAX_PER_IP: usize = 200;

#[derive(Clone)]
pub struct WsConnLimiter {
    max_per_ip: usize,
    open: Arc<Mutex<HashMap<String, usize>>>,
}

/// One admitted socket; its slot is released when dropped.
pub struct WsPermit {
    limiter: WsConnLimiter,
    ip: String,
}

impl Drop for WsPermit {
    fn drop(&mut self) {
        let mut open = self.limiter.open.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(count) = open.get_mut(&self.ip) {
            *count -= 1;
            if *count == 0 {
                open.remove(&self.ip);
            }
        }
    }
}

impl WsConnLimiter {
    pub fn new(max_per_ip: usize) -> Self {
        Self {
            max_per_ip,
            open: Arc::default(),
        }
    }

    pub fn from_env() -> Self {
        let max = std::env::var("RELAY_WS_MAX_PER_IP")
            .ok()
            .and_then(|value| value.trim().parse().ok())
            .filter(|max: &usize| *max > 0)
            .unwrap_or(DEFAULT_WS_MAX_PER_IP);
        Self::new(max)
    }

    pub fn try_acquire(&self, ip: &str) -> Option<WsPermit> {
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let count = open.entry(ip.to_string()).or_insert(0);
        if *count >= self.max_per_ip {
            return None;
        }
        *count += 1;
        Some(WsPermit {
            limiter: self.clone(),
            ip: ip.to_string(),
        })
    }

    /// Open sockets from `ip` on this replica.
    pub fn open(&self, ip: &str) -> usize {
        self.open
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(ip)
            .copied()
            .unwrap_or(0)
    }
}

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

/// The client's IP: Cloudflare's header (it can't be forged through the
/// tunnel), the first X-Forwarded-For entry, X-Real-IP, then the peer.
///
/// Trust assumption: production traffic always arrives through Cloudflare,
/// which overwrites any client-sent CF-Connecting-IP, so the header that
/// wins is never client-controlled there. X-Forwarded-For and X-Real-IP
/// are only trustworthy behind a proxy that sets them (nginx's `/ws`
/// location sets neither); a deployment reachable without Cloudflare can
/// have its per-IP limit dodged by a client that forges them.
pub fn client_ip(headers: &HeaderMap, peer: Option<SocketAddr>) -> String {
    header(headers, "cf-connecting-ip")
        .or_else(|| {
            header(headers, "x-forwarded-for")
                .and_then(|value| value.split(',').next())
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .or_else(|| header(headers, "x-real-ip"))
        .map(str::to_string)
        .or_else(|| peer.map(|peer| peer.ip().to_string()))
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permits_are_counted_per_ip_and_released_on_drop() {
        let limiter = WsConnLimiter::new(2);
        let a1 = limiter.try_acquire("203.0.113.1").expect("first");
        let _a2 = limiter.try_acquire("203.0.113.1").expect("second");
        assert!(limiter.try_acquire("203.0.113.1").is_none(), "third is over the cap");
        let _b1 = limiter.try_acquire("203.0.113.2").expect("another IP");
        assert_eq!(limiter.open("203.0.113.1"), 2);
        drop(a1);
        assert_eq!(limiter.open("203.0.113.1"), 1);
        assert!(limiter.try_acquire("203.0.113.1").is_some());
    }

    #[test]
    fn the_default_cap_refuses_the_201st_socket() {
        assert_eq!(DEFAULT_WS_MAX_PER_IP, 200);
        let limiter = WsConnLimiter::new(DEFAULT_WS_MAX_PER_IP);
        let held: Vec<_> = (0..200)
            .map(|_| limiter.try_acquire("203.0.113.1").expect("within the cap"))
            .collect();
        assert!(limiter.try_acquire("203.0.113.1").is_none(), "201st is refused");
        assert!(limiter.try_acquire("203.0.113.2").is_some(), "other IPs are unaffected");
        drop(held);
        assert_eq!(limiter.open("203.0.113.1"), 0);
    }

    #[test]
    fn client_ip_prefers_cloudflare_then_forwarded_then_peer() {
        let mut headers = HeaderMap::new();
        let peer: SocketAddr = "10.0.0.5:4444".parse().unwrap();
        assert_eq!(client_ip(&headers, Some(peer)), "10.0.0.5");
        assert_eq!(client_ip(&headers, None), "unknown");
        headers.insert("x-real-ip", "10.0.0.9".parse().unwrap());
        assert_eq!(client_ip(&headers, Some(peer)), "10.0.0.9");
        headers.insert("x-forwarded-for", "198.51.100.7, 10.0.0.9".parse().unwrap());
        assert_eq!(client_ip(&headers, Some(peer)), "198.51.100.7");
        headers.insert("cf-connecting-ip", "203.0.113.50".parse().unwrap());
        assert_eq!(client_ip(&headers, Some(peer)), "203.0.113.50");
    }
}
