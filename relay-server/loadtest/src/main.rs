//! Relay load test (docs/specs/2026-09-30-relay-multi-replica.md,
//! "Scaling to 10k+", step 4). Run it before claiming 10k users and before
//! raising any limit. How to run and what passes: relay-server/README.md,
//! "Load test".
//!
//!   cargo run --release -- --url ws://127.0.0.1:3001/ws --url ws://127.0.0.1:3002/ws
//!
//! It speaks the real protocol: every Astation socket (`role=astation`,
//! `code=astation-lt-…`) answers the relay's `relayAuthChallenge` with a
//! `relayAuth` signed by its own fresh P-256 key (so its room is a keyed,
//! registered room, as in production), and every Atem socket joins with
//! `role=atem&code=…&atem_id=…`. Traffic per room, once every interval:
//! each Atem sends a frame (the relay wraps it in the `{atem_id,
//! connection_id, payload}` envelope), the Astation answers each one with a
//! targeted envelope (unicast), and the Astation broadcasts one raw frame to
//! all its Atems. Every frame carries its send time; receivers record the
//! one-way latency (same process, same clock).
//!
//! One client host needs `ulimit -n 65535` and
//! `sysctl -w net.ipv4.ip_local_port_range="1024 65535"` for 30k sockets,
//! and the relays need RELAY_WS_MAX_PER_IP above the per-replica share.
//!
//! Safety: only loopback URLs are accepted unless
//! `--i-know-this-is-production` is passed. A run registers one Astation key
//! per room in the relays' identity store (see the README for cleanup).

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::http::Uri;
use tokio_tungstenite::{
    connect_async_with_config, tungstenite::Message, MaybeTlsStream, WebSocketStream,
};

const USAGE: &str = "usage: relay-loadtest [--url ws://host:port/ws]... [--astations N] \
[--atems-per-astation N] [--interval-ms N] [--duration-secs N] [--ramp-per-sec N] [--run-id ID] \
[--i-know-this-is-production]

Defaults: --url ws://127.0.0.1:3000/ws --astations 10000 --atems-per-astation 2 \
--interval-ms 5000 --duration-secs 1800 --ramp-per-sec 500 (30k sockets, 30 minutes).
URLs that are not loopback (localhost, 127.0.0.0/8, ::1) are refused unless
--i-know-this-is-production is given.";

const PRODUCTION_FLAG: &str = "--i-know-this-is-production";

/// Pass criteria (spec): p99 frame latency under 100 ms.
const P99_LIMIT_MS: f64 = 100.0;

/// WebSocket connect (TCP + TLS + upgrade) limit per socket.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Challenge → relayAuthResult limit per Astation.
const AUTH_TIMEOUT: Duration = Duration::from_secs(10);
/// How long an Astation waits for all its Atems' `connected` events.
const ROOM_READY_TIMEOUT: Duration = Duration::from_secs(30);
/// Settle time between the end of the ramp and the start of traffic.
const SETTLE: Duration = Duration::from_secs(5);
/// After `stop`, sockets stay open this long so frames in flight arrive.
const DRAIN: Duration = Duration::from_secs(3);

// Must match the relay (relay.rs, "Astation relay identity").
const RELAY_AUTH_CONTEXT: &str = "station-relay-auth-v1";

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

struct Args {
    urls: Vec<String>,
    astations: usize,
    atems_per_astation: usize,
    interval: Duration,
    duration: Duration,
    ramp_per_sec: u64,
    run_id: String,
    production: bool,
}

fn default_run_id() -> String {
    // Unique across runs against the same relays: a reused Astation id would
    // hit the key registered by an earlier run and be rejected.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0);
    format!("{secs:x}{:x}", std::process::id())
}

fn parse_args(raw: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut args = Args {
        urls: Vec::new(),
        astations: 10_000,
        atems_per_astation: 2,
        interval: Duration::from_millis(5_000),
        duration: Duration::from_secs(1_800),
        ramp_per_sec: 500,
        run_id: default_run_id(),
        production: false,
    };
    let mut it = raw.into_iter();
    while let Some(flag) = it.next() {
        let mut value = || {
            it.next()
                .ok_or_else(|| format!("{flag} needs a value\n{USAGE}"))
        };
        let number = |text: String| text.parse::<u64>().map_err(|e| format!("{flag}: {e}"));
        match flag.as_str() {
            "--url" => args.urls.push(value()?),
            "--astations" => args.astations = number(value()?)? as usize,
            "--atems-per-astation" => args.atems_per_astation = number(value()?)? as usize,
            "--interval-ms" => args.interval = Duration::from_millis(number(value()?)?),
            "--duration-secs" => args.duration = Duration::from_secs(number(value()?)?),
            "--ramp-per-sec" => args.ramp_per_sec = number(value()?)?,
            "--run-id" => args.run_id = value()?,
            PRODUCTION_FLAG => args.production = true,
            "-h" | "--help" => return Err(USAGE.to_string()),
            other => return Err(format!("unknown flag {other}\n{USAGE}")),
        }
    }
    if args.urls.is_empty() {
        args.urls.push("ws://127.0.0.1:3000/ws".to_string());
    }
    if args.astations == 0 || args.atems_per_astation == 0 {
        return Err("--astations and --atems-per-astation must be at least 1".to_string());
    }
    if args.interval.is_zero() || args.duration.is_zero() || args.ramp_per_sec == 0 {
        return Err(
            "--interval-ms, --duration-secs and --ramp-per-sec must be positive".to_string(),
        );
    }
    if args.run_id.is_empty()
        || !args
            .run_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err("--run-id must be [A-Za-z0-9-]+".to_string());
    }
    for url in &args.urls {
        check_target(url, args.production)?;
    }
    Ok(args)
}

/// The host of a `ws://` or `wss://` URL (IPv6 without brackets), parsed
/// with the same `http::Uri` parser tungstenite connects with, so the guard
/// sees exactly the host the client dials.
fn url_host(url: &str) -> Option<String> {
    let uri: Uri = url.parse().ok()?;
    if !matches!(uri.scheme_str(), Some("ws") | Some("wss")) {
        return None;
    }
    let host = uri.host()?;
    let host = host
        .strip_prefix('[')
        .and_then(|v6| v6.strip_suffix(']'))
        .unwrap_or(host);
    (!host.is_empty()).then(|| host.to_string())
}

fn is_loopback_host(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<IpAddr>()
            .map(|ip| ip.is_loopback())
            .unwrap_or(false)
}

/// Refuse anything but a loopback ws(s) URL unless `production` is set.
fn check_target(url: &str, production: bool) -> Result<(), String> {
    let host = url_host(url).ok_or_else(|| format!("not a valid ws:// or wss:// URL: {url}"))?;
    if is_loopback_host(&host) || production {
        Ok(())
    } else {
        Err(format!(
            "refusing to load-test {url}: {host} is not a loopback address. \
             This opens tens of thousands of sockets and registers an Astation key per room. \
             Pass {PRODUCTION_FLAG} only for a planned run against relays you own."
        ))
    }
}

fn now_us() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_micros() as u64
}

#[derive(Default)]
struct Stats {
    open: AtomicU64,
    connect_errors: AtomicU64,
    auth_errors: AtomicU64,
    rooms_incomplete: AtomicU64,
    dropped_sockets: AtomicU64,
    /// Atem → Astation (envelope).
    up_sent: AtomicU64,
    up_received: AtomicU64,
    /// Astation → all its Atems (raw broadcast); expected = Atems × sends.
    bcast_expected: AtomicU64,
    bcast_received: AtomicU64,
    /// Astation → one Atem (targeted envelope), one per Atem frame.
    uni_sent: AtomicU64,
    uni_received: AtomicU64,
    /// Per (sender, flow) sequence checks at the receivers.
    seq_gaps: AtomicU64,
    seq_duplicates: AtomicU64,
    window: Mutex<Vec<u32>>,
    all: Mutex<Vec<u32>>,
}

impl Stats {
    fn record(&self, sent_us: u64) {
        let micros = now_us().saturating_sub(sent_us).min(u32::MAX as u64) as u32;
        self.window.lock().unwrap().push(micros);
    }

    fn bump(counter: &AtomicU64, by: u64) {
        counter.fetch_add(by, Ordering::Relaxed);
    }

    fn get(counter: &AtomicU64) -> u64 {
        counter.load(Ordering::Relaxed)
    }
}

/// Per-(sender, flow) sequence check at one receiver: each sender's frames
/// must arrive as 1, 2, 3, … A skipped number is a gap (a frame lost in the
/// middle); a number at or below the last seen is a duplicate or reorder.
#[derive(Default)]
struct SeqTracker {
    last: HashMap<String, u64>,
}

impl SeqTracker {
    fn observe(&mut self, stats: &Stats, key: &str, seq: Option<u64>) {
        let Some(seq) = seq else {
            Stats::bump(&stats.seq_gaps, 1);
            return;
        };
        let last = self.last.entry(key.to_string()).or_insert(0);
        if seq > *last {
            Stats::bump(&stats.seq_gaps, seq - *last - 1);
            *last = seq;
        } else {
            Stats::bump(&stats.seq_duplicates, 1);
        }
    }
}

fn percentile_ms(sorted: &[u32], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let index = ((sorted.len() - 1) as f64 * p).round() as usize;
    sorted[index] as f64 / 1000.0
}

/// When traffic runs; shared by every socket.
#[derive(Clone, Copy)]
struct Plan {
    traffic_start: Instant,
    stop: Instant,
    interval: Duration,
}

/// An Astation's relay identity key (P-256), as Astation keeps in its keychain.
struct AstationKey {
    pair: EcdsaKeyPair,
    rng: SystemRandom,
}

impl AstationKey {
    fn generate() -> Self {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng)
            .expect("generate P-256 key");
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng)
            .expect("load P-256 key");
        Self { pair, rng }
    }

    /// The `relayAuth` answer: X9.63 public key and DER signature over
    /// "station-relay-auth-v1\n<challenge>\n<astation_id>", both lowercase hex.
    fn relay_auth(&self, challenge: &str, astation_id: &str) -> String {
        let message = format!("{RELAY_AUTH_CONTEXT}\n{challenge}\n{astation_id}");
        let signature = self
            .pair
            .sign(&self.rng, message.as_bytes())
            .expect("sign challenge");
        serde_json::json!({
            "type": "relayAuth",
            "astation_id": astation_id,
            "public_key": hex(self.pair.public_key().as_ref()),
            "signature": hex(signature.as_ref()),
        })
        .to_string()
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

async fn connect(url: String) -> Option<Socket> {
    // TCP_NODELAY, as interactive clients use: no Nagle delay on small frames.
    match tokio::time::timeout(CONNECT_TIMEOUT, connect_async_with_config(url, None, true)).await {
        Ok(Ok((socket, _))) => Some(socket),
        _ => None,
    }
}

/// Next JSON text frame (pings are answered by tungstenite while reading).
async fn next_json(stream: &mut SplitStream<Socket>) -> Option<serde_json::Value> {
    while let Some(message) = stream.next().await {
        if let Message::Text(text) = message.ok()? {
            if let Ok(value) = serde_json::from_str(&text) {
                return Some(value);
            }
        }
    }
    None
}

/// Answer the relay's challenge; Ok on `registered` or `verified`.
async fn authenticate(
    sink: &mut SplitSink<Socket, Message>,
    stream: &mut SplitStream<Socket>,
    key: &AstationKey,
    astation_id: &str,
) -> Result<(), String> {
    let challenge = loop {
        let value = next_json(stream)
            .await
            .ok_or("closed before the challenge")?;
        if value["type"] == "relayAuthChallenge" {
            break value["challenge"]
                .as_str()
                .ok_or("challenge without a challenge")?
                .to_string();
        }
    };
    sink.send(Message::Text(key.relay_auth(&challenge, astation_id)))
        .await
        .map_err(|e| e.to_string())?;
    loop {
        let value = next_json(stream)
            .await
            .ok_or("closed before relayAuthResult")?;
        if value["type"] == "relayAuthResult" {
            return match value["status"].as_str() {
                Some("registered") | Some("verified") => Ok(()),
                _ => Err(format!("rejected: {}", value["message"])),
            };
        }
    }
}

/// One Astation owning room `code`: authenticates, waits for its Atems,
/// then broadcasts every interval and answers each Atem frame with a
/// targeted envelope. Records Atem → Astation latency.
async fn astation(
    url: String,
    code: String,
    atems: usize,
    stats: Arc<Stats>,
    plan: Plan,
    offset: Duration,
    ready: oneshot::Sender<bool>,
) {
    let key = AstationKey::generate();
    let Some(socket) = connect(format!("{url}?role=astation&code={code}")).await else {
        Stats::bump(&stats.connect_errors, 1);
        let _ = ready.send(false);
        return;
    };
    Stats::bump(&stats.open, 1);
    let (mut sink, mut stream) = socket.split();
    let auth = tokio::time::timeout(
        AUTH_TIMEOUT,
        authenticate(&mut sink, &mut stream, &key, &code),
    )
    .await;
    if !matches!(auth, Ok(Ok(()))) {
        if let Ok(Err(reason)) = &auth {
            eprintln!("{code}: relayAuth failed: {reason}");
        }
        Stats::bump(&stats.auth_errors, 1);
        let _ = ready.send(false);
        let _ = sink.close().await;
        stats.open.fetch_sub(1, Ordering::Relaxed);
        return;
    }
    let _ = ready.send(true);

    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            if sink.send(Message::Text(frame)).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });
    let connected = Arc::new(AtomicUsize::new(0));
    let all_connected = Arc::new(tokio::sync::Notify::new());
    let reader = tokio::spawn({
        let stats = stats.clone();
        let tx = tx.clone();
        let connected = connected.clone();
        let all_connected = all_connected.clone();
        async move {
            let mut seqs = SeqTracker::default();
            let mut uni_seq: HashMap<String, u64> = HashMap::new();
            while let Some(Ok(message)) = stream.next().await {
                let Message::Text(text) = message else {
                    continue;
                };
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                    continue;
                };
                if value["relay_event"] == "connected" {
                    if connected.fetch_add(1, Ordering::Relaxed) + 1 >= atems {
                        all_connected.notify_one();
                    }
                } else if let Some(sent) = value["payload"]["lt"]["sent_us"].as_u64() {
                    Stats::bump(&stats.up_received, 1);
                    stats.record(sent);
                    let atem_id = value["atem_id"].as_str().unwrap_or_default().to_string();
                    seqs.observe(
                        &stats,
                        &format!("{atem_id}/up"),
                        value["payload"]["lt"]["seq"].as_u64(),
                    );
                    let seq = uni_seq.entry(atem_id).or_insert(0);
                    *seq += 1;
                    let reply = serde_json::json!({
                        "atem_id": value["atem_id"],
                        "connection_id": value["connection_id"],
                        "payload": {"lt_uni": {"seq": *seq, "sent_us": now_us()}},
                    });
                    if tx.send(reply.to_string()).is_ok() {
                        Stats::bump(&stats.uni_sent, 1);
                    }
                }
            }
            if Instant::now() < plan.stop {
                Stats::bump(&stats.dropped_sockets, 1);
            }
        }
    });

    if tokio::time::timeout(ROOM_READY_TIMEOUT, all_connected.notified())
        .await
        .is_err()
    {
        Stats::bump(&stats.rooms_incomplete, 1);
    }
    let mut tick = send_interval(plan, offset);
    let mut seq: u64 = 0;
    loop {
        tick.tick().await;
        if Instant::now() >= plan.stop {
            break;
        }
        seq += 1;
        let frame = serde_json::json!({"lt_bcast": {"seq": seq, "sent_us": now_us()}}).to_string();
        if tx.send(frame).is_err() {
            break;
        }
        let atems_now = connected.load(Ordering::Relaxed).min(atems) as u64;
        Stats::bump(&stats.bcast_expected, atems_now);
    }
    // Let frames in flight (and replies to them) arrive before closing.
    tokio::time::sleep_until((plan.stop + DRAIN).into()).await;
    reader.abort();
    drop(tx);
    let _ = writer.await;
    stats.open.fetch_sub(1, Ordering::Relaxed);
}

/// One Atem in room `code` sending every interval; records broadcast and
/// unicast (Astation → Atem) latency.
async fn atem(
    url: String,
    code: String,
    atem_id: String,
    stats: Arc<Stats>,
    plan: Plan,
    offset: Duration,
) {
    let Some(socket) = connect(format!("{url}?role=atem&code={code}&atem_id={atem_id}")).await
    else {
        Stats::bump(&stats.connect_errors, 1);
        return;
    };
    Stats::bump(&stats.open, 1);
    let (mut sink, mut stream) = socket.split();
    let reader = tokio::spawn({
        let stats = stats.clone();
        async move {
            // One sender (the room's Astation): key by flow.
            let mut seqs = SeqTracker::default();
            while let Some(Ok(message)) = stream.next().await {
                let Message::Text(text) = message else {
                    continue;
                };
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                    continue;
                };
                if let Some(sent) = value["lt_bcast"]["sent_us"].as_u64() {
                    Stats::bump(&stats.bcast_received, 1);
                    stats.record(sent);
                    seqs.observe(&stats, "bcast", value["lt_bcast"]["seq"].as_u64());
                } else if let Some(sent) = value["lt_uni"]["sent_us"].as_u64() {
                    Stats::bump(&stats.uni_received, 1);
                    stats.record(sent);
                    seqs.observe(&stats, "uni", value["lt_uni"]["seq"].as_u64());
                }
            }
            if Instant::now() < plan.stop {
                Stats::bump(&stats.dropped_sockets, 1);
            }
        }
    });
    let mut tick = send_interval(plan, offset);
    let mut seq: u64 = 0;
    loop {
        tick.tick().await;
        if Instant::now() >= plan.stop {
            break;
        }
        seq += 1;
        let frame =
            serde_json::json!({"type": "loadtest", "lt": {"seq": seq, "sent_us": now_us()}})
                .to_string();
        if sink.send(Message::Text(frame)).await.is_err() {
            break;
        }
        Stats::bump(&stats.up_sent, 1);
    }
    tokio::time::sleep_until((plan.stop + DRAIN).into()).await;
    let _ = sink.close().await;
    reader.abort();
    stats.open.fetch_sub(1, Ordering::Relaxed);
}

/// A room's send clock. A late tick (busy client) delays the following ones
/// instead of bursting to catch up, so a stall doesn't spike the load.
fn send_interval(plan: Plan, offset: Duration) -> tokio::time::Interval {
    let mut tick = tokio::time::interval_at((plan.traffic_start + offset).into(), plan.interval);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    tick
}

/// One room: its Astation (on `urls[room]`), then its Atems once the
/// Astation is registered (on the other URLs, so traffic crosses replicas).
async fn room(index: usize, args: Arc<Args>, stats: Arc<Stats>, plan: Plan) {
    let urls = &args.urls;
    let code = format!("astation-lt-{}-{index}", args.run_id);
    // Spread each room's ticks over the interval instead of all at once.
    let offset = plan.interval.mul_f64(index as f64 / args.astations as f64);
    let (ready_tx, ready_rx) = oneshot::channel();
    let mut tasks = vec![tokio::spawn(astation(
        urls[index % urls.len()].clone(),
        code.clone(),
        args.atems_per_astation,
        stats.clone(),
        plan,
        offset,
        ready_tx,
    ))];
    if ready_rx.await.unwrap_or(false) {
        for n in 0..args.atems_per_astation {
            tasks.push(tokio::spawn(atem(
                urls[(index + n + 1) % urls.len()].clone(),
                code.clone(),
                format!("lt-atem-{n}"),
                stats.clone(),
                plan,
                offset,
            )));
        }
    }
    for task in tasks {
        let _ = task.await;
    }
}

fn phase(plan: &Plan) -> &'static str {
    let now = Instant::now();
    if now < plan.traffic_start {
        "ramp"
    } else if now < plan.stop {
        "traffic"
    } else {
        "drain"
    }
}

#[tokio::main]
async fn main() {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(args) => Arc::new(args),
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };
    let _ = rustls::crypto::ring::default_provider().install_default();
    now_us();

    let stats = Arc::new(Stats::default());
    let rooms = args.astations;
    let sockets = rooms * (1 + args.atems_per_astation);
    let per_room =
        Duration::from_secs_f64((1 + args.atems_per_astation) as f64 / args.ramp_per_sec as f64);
    let ramp = per_room.mul_f64(rooms as f64);
    let launch = Instant::now();
    let traffic_start = launch + ramp + SETTLE;
    let plan = Plan {
        traffic_start,
        stop: traffic_start + args.duration,
        interval: args.interval,
    };
    println!(
        "relay-loadtest {}: {} sockets ({} rooms × (Astation + {} Atems)) over {} URL(s), \
         ramp {:.0} s, traffic {} s every {} ms",
        args.run_id,
        sockets,
        rooms,
        args.atems_per_astation,
        args.urls.len(),
        ramp.as_secs_f64(),
        args.duration.as_secs(),
        args.interval.as_millis()
    );

    let reporter = tokio::spawn({
        let stats = stats.clone();
        async move {
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            tick.tick().await;
            loop {
                tick.tick().await;
                let mut window = std::mem::take(&mut *stats.window.lock().unwrap());
                window.sort_unstable();
                println!(
                    "{:>7} open {:>6}  up {}/{}  bcast {}/{}  uni {}/{}  p50 {:.1} ms  p99 {:.1} ms  \
                     gaps {}  dups {}  errors {}  auth {}  incomplete {}  dropped {}",
                    phase(&plan),
                    Stats::get(&stats.open),
                    Stats::get(&stats.up_received),
                    Stats::get(&stats.up_sent),
                    Stats::get(&stats.bcast_received),
                    Stats::get(&stats.bcast_expected),
                    Stats::get(&stats.uni_received),
                    Stats::get(&stats.uni_sent),
                    percentile_ms(&window, 0.50),
                    percentile_ms(&window, 0.99),
                    Stats::get(&stats.seq_gaps),
                    Stats::get(&stats.seq_duplicates),
                    Stats::get(&stats.connect_errors),
                    Stats::get(&stats.auth_errors),
                    Stats::get(&stats.rooms_incomplete),
                    Stats::get(&stats.dropped_sockets),
                );
                stats.all.lock().unwrap().extend(window);
            }
        }
    });

    let mut tasks = Vec::with_capacity(rooms);
    for index in 0..rooms {
        tokio::time::sleep_until((launch + per_room.mul_f64(index as f64)).into()).await;
        tasks.push(tokio::spawn(room(index, args.clone(), stats.clone(), plan)));
    }
    for task in tasks {
        let _ = task.await;
    }
    reporter.abort();

    let mut all = std::mem::take(&mut *stats.all.lock().unwrap());
    all.extend(std::mem::take(&mut *stats.window.lock().unwrap()));
    all.sort_unstable();
    let p50 = percentile_ms(&all, 0.50);
    let p99 = percentile_ms(&all, 0.99);
    let lost = |sent: &AtomicU64, received: &AtomicU64| {
        Stats::get(sent).saturating_sub(Stats::get(received))
    };
    let up_lost = lost(&stats.up_sent, &stats.up_received);
    let bcast_lost = lost(&stats.bcast_expected, &stats.bcast_received);
    let uni_lost = lost(&stats.uni_sent, &stats.uni_received);
    let errors = Stats::get(&stats.connect_errors);
    let auth = Stats::get(&stats.auth_errors);
    let incomplete = Stats::get(&stats.rooms_incomplete);
    let dropped = Stats::get(&stats.dropped_sockets);
    let gaps = Stats::get(&stats.seq_gaps);
    let duplicates = Stats::get(&stats.seq_duplicates);
    println!(
        "total: {} samples  p50 {:.1} ms  p99 {:.1} ms  max {:.1} ms  lost frames up {} bcast {} uni {}  \
         seq gaps {}  duplicates/reordered {}  connect errors {}  auth errors {}  incomplete rooms {}  dropped sockets {}",
        all.len(),
        p50,
        p99,
        all.last().map(|&us| us as f64 / 1000.0).unwrap_or(0.0),
        up_lost,
        bcast_lost,
        uni_lost,
        gaps,
        duplicates,
        errors,
        auth,
        incomplete,
        dropped
    );
    let pass = !all.is_empty()
        && p99 < P99_LIMIT_MS
        && up_lost + bcast_lost + uni_lost == 0
        && gaps + duplicates == 0
        && errors + auth + incomplete + dropped == 0;
    println!(
        "{}  (p99 < {P99_LIMIT_MS} ms, no lost, skipped, duplicate or reordered frames, \
         no failed or dropped sockets; \
         also check relay memory is flat)",
        if pass { "PASS" } else { "FAIL" }
    );
    std::process::exit(if pass { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args, String> {
        parse_args(list.iter().map(|s| s.to_string()))
    }

    #[test]
    fn loopback_urls_are_accepted() {
        for url in [
            "ws://127.0.0.1:3001/ws",
            "ws://localhost:3000/ws",
            "ws://LOCALHOST/ws",
            "wss://127.0.0.2:443/ws",
            "ws://[::1]:3000/ws",
        ] {
            assert!(check_target(url, false).is_ok(), "{url}");
        }
    }

    #[test]
    fn remote_urls_need_the_production_flag() {
        for url in [
            "wss://station.agora.build/ws",
            "ws://10.0.0.5:3000/ws",
            "ws://localhost.evil.com/ws",
            "ws://127.0.0.1.evil.com/ws",
            "ws://user@example.com:80/ws",
            "ws://127.0.0.1@evil.com/ws",
            "ws://localhost:3000@evil.com/ws",
            "ws://[2001:db8::1]:3000/ws",
        ] {
            assert!(check_target(url, false).is_err(), "{url}");
            assert!(check_target(url, true).is_ok(), "{url}");
        }
        assert!(args(&["--url", "wss://station.agora.build/ws"]).is_err());
        assert!(args(&["--url", "wss://station.agora.build/ws", PRODUCTION_FLAG]).is_ok());
    }

    #[test]
    fn userinfo_tricks_resolve_to_the_dialed_host() {
        // Userinfo before a loopback host: the client dials loopback.
        assert!(check_target("ws://evil.com@127.0.0.1/ws", false).is_ok());
        assert!(check_target("ws://user:pw@[::1]:3000/ws", false).is_ok());
        assert_eq!(
            url_host("ws://user:pw@[::1]:3000/ws").as_deref(),
            Some("::1")
        );
        assert_eq!(
            url_host("ws://127.0.0.1@evil.com/ws").as_deref(),
            Some("evil.com")
        );
        // A backslash is not a valid URI character: refused even with the flag.
        assert!(check_target("ws://evil.com\\@127.0.0.1/ws", false).is_err());
        assert!(check_target("ws://evil.com\\@127.0.0.1/ws", true).is_err());
    }

    #[test]
    fn non_websocket_urls_are_refused() {
        assert!(check_target("http://127.0.0.1:3000/ws", true).is_err());
        assert!(check_target("ws:///ws", true).is_err());
    }

    #[test]
    fn defaults_target_localhost_at_full_scale() {
        let parsed = args(&[]).unwrap();
        assert_eq!(parsed.urls, ["ws://127.0.0.1:3000/ws"]);
        assert_eq!(parsed.astations * (1 + parsed.atems_per_astation), 30_000);
        assert_eq!(parsed.duration, Duration::from_secs(1_800));
        assert!(!parsed.production);
    }

    #[test]
    fn sequence_gaps_and_duplicates() {
        let stats = Stats::default();
        let mut seqs = SeqTracker::default();
        for seq in [1, 2, 3] {
            seqs.observe(&stats, "a/up", Some(seq));
            seqs.observe(&stats, "b/up", Some(seq));
        }
        assert_eq!(Stats::get(&stats.seq_gaps), 0);
        assert_eq!(Stats::get(&stats.seq_duplicates), 0);
        seqs.observe(&stats, "a/up", Some(6)); // 4, 5 skipped
        assert_eq!(Stats::get(&stats.seq_gaps), 2);
        seqs.observe(&stats, "a/up", Some(6)); // duplicate
        seqs.observe(&stats, "b/up", Some(2)); // reordered
        assert_eq!(Stats::get(&stats.seq_duplicates), 2);
        seqs.observe(&stats, "c/up", None); // no seq at all
        assert_eq!(Stats::get(&stats.seq_gaps), 3);
    }

    #[test]
    fn percentiles() {
        let sorted: Vec<u32> = (1..=100).map(|ms| ms * 1000).collect();
        assert_eq!(percentile_ms(&sorted, 0.50), 51.0);
        assert_eq!(percentile_ms(&sorted, 0.99), 99.0);
        assert_eq!(percentile_ms(&[], 0.99), 0.0);
    }

    #[test]
    fn relay_auth_signature_verifies() {
        let key = AstationKey::generate();
        let frame: serde_json::Value =
            serde_json::from_str(&key.relay_auth("ab12", "astation-x")).unwrap();
        assert_eq!(frame["type"], "relayAuth");
        assert_eq!(frame["astation_id"], "astation-x");
        let public_key = frame["public_key"].as_str().unwrap();
        assert_eq!(public_key.len(), 130);
        assert!(public_key.starts_with("04"));
        let unhex = |text: &str| -> Vec<u8> {
            (0..text.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
                .collect()
        };
        ring::signature::UnparsedPublicKey::new(
            &ring::signature::ECDSA_P256_SHA256_ASN1,
            unhex(public_key),
        )
        .verify(
            b"station-relay-auth-v1\nab12\nastation-x",
            &unhex(frame["signature"].as_str().unwrap()),
        )
        .expect("signature verifies");
    }
}
