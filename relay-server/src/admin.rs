//! Operator commands: `station-relay-server admin <command>` (runbook:
//! DEPLOY.md, "Admin reset").

use crate::cluster::bus::{BroadcastMessage, ReplicaBus};
use crate::cluster::redis::bus::RedisBus;
use crate::cluster::redis::RedisConn;
use crate::identity_store::{IdentityStore, PgIdentityStore};

pub const USAGE: &str = "usage: station-relay-server admin forget-key <astation_id>\n\
       station-relay-server admin delegated-recovery status|fence\n\
       station-relay-server admin delegated-recovery inspect|prepare <genesis_hash>\n\
       station-relay-server admin delegated-recovery retain-stops <genesis_hash> <file>\n\
\n\
Deletes the Astation's registered relay key (DATABASE_URL, required) and\n\
announces it on relay:broadcast (REDIS_URL, optional) so every relay\n\
replica drops the cached key at once. Bindings are kept.\n\
\n\
delegated-recovery uses DATABASE_URL, PUBLIC_BASE_URL and\n\
STATION_DELEGATED_RECOVERY_GENERATION. status and inspect only read; fence\n\
durably stops delegated serving, signing and reporting. prepare retains the old\n\
evidence and reserves a replacement feed behind a closed fence. retain-stops adds\n\
native stop evidence to that exact preparation. Neither command resumes them.";

#[derive(Debug, PartialEq, Eq)]
pub struct ForgetOutcome {
    pub deleted: bool,
    pub announced: bool,
}

pub async fn forget_key(
    identity: &dyn IdentityStore,
    bus: Option<&dyn ReplicaBus>,
    astation_id: &str,
) -> Result<ForgetOutcome, String> {
    let deleted = identity
        .delete_key(astation_id)
        .await
        .map_err(|error| format!("could not delete the key: {error}"))?;
    let announced = match bus {
        Some(bus) => {
            bus.broadcast(BroadcastMessage::KeyChanged {
                astation_id: astation_id.to_string(),
            })
            .await
            .map_err(|error| {
                format!(
                    "the key was deleted, but announcing it failed ({error}); \
                     restart the relay replicas to drop the cached key now"
                )
            })?;
            true
        }
        None => false,
    };
    Ok(ForgetOutcome { deleted, announced })
}

/// `admin` arguments (after the word `admin`); returns the exit code.
pub async fn main(args: &[String]) -> i32 {
    if args.first().map(String::as_str) == Some("delegated-recovery") {
        return delegated_recovery(&args[1..]).await;
    }
    let astation_id = match args {
        [command, id] if command == "forget-key" && !id.is_empty() => id.clone(),
        _ => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    let Some(database_url) = std::env::var("DATABASE_URL").ok().filter(|url| !url.is_empty()) else {
        eprintln!("DATABASE_URL is required");
        return 1;
    };
    let pool = match sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
    {
        Ok(pool) => pool,
        Err(error) => {
            eprintln!("could not connect to DATABASE_URL: {error}");
            return 1;
        }
    };
    let identity = PgIdentityStore::new(pool);
    let bus = match std::env::var("REDIS_URL").ok().filter(|url| !url.trim().is_empty()) {
        Some(url) => match RedisConn::connect_checked(&url).await {
            Ok(conn) => Some(RedisBus::publisher(conn, "admin")),
            Err(error) => {
                eprintln!("could not connect to REDIS_URL: {error}");
                return 1;
            }
        },
        None => None,
    };
    match forget_key(&identity, bus.as_ref().map(|bus| bus as &dyn ReplicaBus), &astation_id).await {
        Ok(outcome) => {
            if outcome.deleted {
                println!("Deleted the relay key of {astation_id}.");
            } else {
                println!("No relay key was registered for {astation_id}.");
            }
            if outcome.announced {
                println!("Announced on relay:broadcast: every relay replica drops its cached key now.");
            } else {
                println!("REDIS_URL is not set: restart the relay to drop its cached key.");
            }
            0
        }
        Err(message) => {
            eprintln!("{message}");
            1
        }
    }
}

async fn delegated_recovery(args: &[String]) -> i32 {
    use crate::remote_api::recovery::delegated_recovery::{generation, inspect, inspect_root, Binding};
    let (fence, root, file) = match args {
        [command] if command == "status" => (false, None, None),
        [command] if command == "fence" => (true, None, None),
        [command, genesis]
            if matches!(command.as_str(), "inspect" | "prepare") && genesis.len() == 64
                && genesis.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) =>
        {
            (false, Some((command.as_str(), genesis)), None)
        }
        [command, genesis, file]
            if command == "retain-stops" && genesis.len() == 64
                && genesis.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) =>
        {
            (false, Some((command.as_str(), genesis)), Some(file))
        }
        _ => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    let origin = std::env::var("PUBLIC_BASE_URL").unwrap_or_default();
    let configured = std::env::var("STATION_DELEGATED_RECOVERY_GENERATION").unwrap_or_default();
    let binding = match generation(&configured).and_then(|g| Binding::new(&origin, g)) {
        Ok(binding) => binding,
        Err(reason) => {
            eprintln!("{reason}");
            return 2;
        }
    };
    let Ok(url) = std::env::var("DATABASE_URL") else {
        eprintln!("DATABASE_URL is required");
        return 1;
    };
    let pool = match sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect(&url)
        .await
    {
        Ok(pool) => pool,
        Err(_) => {
            eprintln!("could not connect to recovery storage");
            return 1;
        }
    };
    if let Some((command, genesis)) = root {
        let report = if let Some(file) = file {
            use tokio::io::AsyncReadExt;
            use crate::remote_api::recovery::delegated_recovery::plan::stops;
            let limit = stops::input_limit();
            let mut bytes = Vec::new();
            if !tokio::fs::metadata(file).await.is_ok_and(|metadata| metadata.is_file()) {
                eprintln!("recovery stop evidence must be a regular file");
                return 1;
            }
            let input = match tokio::fs::File::open(file).await {
                Ok(input) => input,
                Err(_) => { eprintln!("could not read recovery stop evidence"); return 1; }
            };
            if input.take((limit + 1) as u64).read_to_end(&mut bytes).await.is_err() || bytes.len() > limit {
                eprintln!("could not read bounded recovery stop evidence");
                return 1;
            }
            stops::retain(&pool, &binding, genesis, &bytes).await
        } else if command == "prepare" {
            crate::remote_api::recovery::delegated_recovery::plan::prepare(&pool, &binding, genesis).await
        } else {
            inspect_root(&pool, &binding, genesis).await
        };
        return match report {
            Ok(report) => {
                println!("{report}");
                0
            }
            Err(_) => {
                eprintln!("could not {command} the retained delegated recovery state");
                1
            }
        };
    }
    let result = if fence {
        binding.initialize(&pool, true).await.map(Some)
    } else {
        inspect(&pool, &binding.origin).await
    };
    match result {
        Ok(status) => {
            println!(
                "{}",
                serde_json::json!({
                    "origin": binding.origin,
                    "configured_generation": binding.generation,
                    "recovery_ready": status.as_ref().is_some_and(|s| s.ready && s.generation == binding.generation),
                    "status": status,
                })
            );
            0
        }
        Err(_) => {
            eprintln!("could not inspect or commit the delegated recovery fence");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::bus::LoopbackBus;
    use crate::cluster::local::LocalSockets;
    use crate::identity_store::InMemoryIdentityStore;

    #[tokio::test]
    async fn forget_key_deletes_and_announces() {
        let identity = InMemoryIdentityStore::new();
        identity.register_key_if_absent("astation-a", "04aa", 1).await.unwrap();
        let bus = LoopbackBus::new("admin", LocalSockets::new());
        assert_eq!(
            forget_key(&identity, Some(&bus), "astation-a").await.unwrap(),
            ForgetOutcome { deleted: true, announced: true }
        );
        assert_eq!(identity.get_key("astation-a").await.unwrap(), None);
        assert_eq!(
            forget_key(&identity, None, "astation-a").await.unwrap(),
            ForgetOutcome { deleted: false, announced: false }
        );
    }

    struct RecordingBus(std::sync::Mutex<Vec<BroadcastMessage>>);

    #[async_trait::async_trait]
    impl ReplicaBus for RecordingBus {
        fn backend_name(&self) -> &'static str {
            "recording"
        }
        async fn send_inbox(
            &self,
            _replica_id: &str,
            _message: crate::cluster::bus::InboxMessage,
        ) -> Result<(), crate::cluster::StoreError> {
            Ok(())
        }
        async fn broadcast(&self, message: BroadcastMessage) -> Result<(), crate::cluster::StoreError> {
            self.0.lock().unwrap().push(message);
            Ok(())
        }
    }

    struct FailingBus;

    #[async_trait::async_trait]
    impl ReplicaBus for FailingBus {
        fn backend_name(&self) -> &'static str {
            "failing"
        }
        async fn send_inbox(
            &self,
            _replica_id: &str,
            _message: crate::cluster::bus::InboxMessage,
        ) -> Result<(), crate::cluster::StoreError> {
            Ok(())
        }
        async fn broadcast(&self, _message: BroadcastMessage) -> Result<(), crate::cluster::StoreError> {
            Err(crate::cluster::StoreError::Unavailable("down".into()))
        }
    }

    #[tokio::test]
    async fn announces_exactly_one_key_changed_after_the_key_is_gone() {
        let identity = InMemoryIdentityStore::new();
        identity.register_key_if_absent("astation-a", "04aa", 1).await.unwrap();
        let bus = RecordingBus(Default::default());
        forget_key(&identity, Some(&bus), "astation-a").await.unwrap();
        {
            let sent = bus.0.lock().unwrap();
            assert_eq!(sent.len(), 1);
            assert!(matches!(&sent[0], BroadcastMessage::KeyChanged { astation_id } if astation_id == "astation-a"));
        }
        assert_eq!(identity.get_key("astation-a").await.unwrap(), None);
    }

    #[tokio::test]
    async fn a_failing_bus_still_deletes_and_says_restart() {
        let identity = InMemoryIdentityStore::new();
        identity.register_key_if_absent("astation-a", "04aa", 1).await.unwrap();
        let error = forget_key(&identity, Some(&FailingBus), "astation-a").await.unwrap_err();
        assert!(error.contains("restart the relay replicas"), "{error}");
        assert_eq!(identity.get_key("astation-a").await.unwrap(), None);
    }

    #[tokio::test]
    async fn bad_arguments_print_usage() {
        assert_eq!(main(&[]).await, 2);
        assert_eq!(main(&["forget-key".to_string()]).await, 2);
        assert_eq!(main(&["drop-everything".to_string(), "x".to_string()]).await, 2);
        assert_eq!(main(&["delegated-recovery".into()]).await, 2);
        assert_eq!(main(&["delegated-recovery".into(), "resume".into()]).await, 2);
        assert_eq!(main(&["delegated-recovery".into(), "fence".into(), "extra".into()]).await, 2);
        for command in ["inspect", "prepare"] {
            for genesis in ["", "not-a-hash", &"A".repeat(64), &"g".repeat(64), &"0".repeat(63)] {
                assert_eq!(main(&["delegated-recovery".into(), command.into(), genesis.into()]).await, 2);
            }
            assert_eq!(main(&["delegated-recovery".into(), command.into()]).await, 2);
        }
    }
}
