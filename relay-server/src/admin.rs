//! Operator commands: `station-relay-server admin <command>` (runbook:
//! DEPLOY.md, "Admin reset").

use crate::cluster::bus::{BroadcastMessage, ReplicaBus};
use crate::cluster::redis::bus::RedisBus;
use crate::cluster::redis::RedisConn;
use crate::identity_store::{IdentityStore, PgIdentityStore};

pub const USAGE: &str = "usage: station-relay-server admin forget-key <astation_id>\n\
\n\
Deletes the Astation's registered relay key (DATABASE_URL, required) and\n\
announces it on relay:broadcast (REDIS_URL, optional) so every relay\n\
replica drops the cached key at once. Bindings are kept.";

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
    let astation_id = match args {
        [command, id] if command == "forget-key" && !id.is_empty() => id.clone(),
        _ => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    let Some(database_url) = std::env::var("DATABASE_URL").ok().filter(|url| !url.is_empty()) else {
        eprintln!("DATABASE_URL is required");
        return 2;
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
    let masked = crate::relay::mask_code(&astation_id);
    match forget_key(&identity, bus.as_ref().map(|bus| bus as &dyn ReplicaBus), &astation_id).await {
        Ok(outcome) => {
            if outcome.deleted {
                println!("Deleted the relay key of {masked}.");
            } else {
                println!("No relay key was registered for {masked}.");
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

    #[tokio::test]
    async fn bad_arguments_print_usage() {
        assert_eq!(main(&[]).await, 2);
        assert_eq!(main(&["forget-key".to_string()]).await, 2);
        assert_eq!(main(&["drop-everything".to_string(), "x".to_string()]).await, 2);
    }
}
