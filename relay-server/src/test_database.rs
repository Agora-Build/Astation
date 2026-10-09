//! Postgres fixtures use a unique schema, never reset shared relay tables.

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::PgPool;
use std::str::FromStr;

pub(crate) fn is_local_db_url(url: &str) -> bool {
    if !matches!(url.split_once("://"), Some(("postgres" | "postgresql", _))) {
        return false;
    }
    PgConnectOptions::from_str(url)
        .map(|options| {
            matches!(
                options.get_host(),
                "localhost" | "127.0.0.1" | "::1" | "[::1]"
            )
        })
        .unwrap_or(false)
}

pub(crate) struct TestDatabase {
    pub pool: PgPool,
    admin: PgPool,
    schema: String,
}

impl TestDatabase {
    pub async fn new(environment: &str, max_connections: u32) -> Self {
        let url = std::env::var(environment)
            .unwrap_or_else(|_| panic!("set {environment} to run the Postgres tests"));
        assert!(
            is_local_db_url(&url),
            "{environment} must point at a local Postgres server"
        );
        let options = PgConnectOptions::from_str(&url).expect("parse Postgres test URL");
        let admin = PgPoolOptions::new()
            .max_connections(1)
            .connect_with(options.clone())
            .await
            .expect("connect Postgres test database");
        let schema = format!("relay_test_{}", uuid::Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA {schema}"))
            .execute(&admin)
            .await
            .expect("create isolated Postgres test schema");
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .connect_with(options.options([("search_path", schema.as_str())]))
            .await
            .expect("connect isolated Postgres test schema");
        Self {
            pool,
            admin,
            schema,
        }
    }

    pub async fn migrated(environment: &str, max_connections: u32) -> Self {
        let database = Self::new(environment, max_connections).await;
        sqlx::migrate!("./migrations")
            .run(&database.pool)
            .await
            .expect("migrate isolated test schema");
        database
    }

    pub async fn reconnect(&self, max_connections: u32) -> PgPool {
        PgPoolOptions::new()
            .max_connections(max_connections)
            .connect_with((*self.pool.connect_options()).clone())
            .await
            .expect("reconnect to the same Postgres test schema")
    }

    pub async fn cleanup(self) {
        self.pool.close().await;
        sqlx::query(&format!("DROP SCHEMA {} CASCADE", self.schema))
            .execute(&self.admin)
            .await
            .expect("remove isolated Postgres test schema");
        self.admin.close().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_database_guard_checks_the_actual_connection_host() {
        for url in [
            "postgres://u:p@localhost/db",
            "postgres://u@127.0.0.1/db",
            "postgresql://u@[::1]/db",
        ] {
            assert!(is_local_db_url(url));
        }
        for url in [
            "not a url",
            "https://localhost/db",
            "postgres://localhost@db.example.com/db",
            "postgres://u@localhost.evil.com/db",
            "postgres://u@localhost/db?host=db.example.com",
            "postgres://u@localhost/db?hostaddr=192.0.2.1",
        ] {
            assert!(!is_local_db_url(url));
        }
    }

    #[tokio::test]
    #[ignore]
    async fn postgres_schemas_are_isolated_and_reconnect_to_the_same_data() {
        use crate::identity_store::{IdentityStore, PgIdentityStore, RegisterOutcome};
        let first = TestDatabase::migrated("IDENTITY_TEST_DATABASE_URL", 2).await;
        let second = TestDatabase::migrated("IDENTITY_TEST_DATABASE_URL", 2).await;
        let left = PgIdentityStore::new(first.pool.clone());
        let right = PgIdentityStore::new(second.pool.clone());
        assert_eq!(
            left.register_key_if_absent("same-id", "04aa", 1)
                .await
                .unwrap(),
            RegisterOutcome::Registered
        );
        assert_eq!(
            right
                .register_key_if_absent("same-id", "04bb", 1)
                .await
                .unwrap(),
            RegisterOutcome::Registered
        );
        let reconnected = PgIdentityStore::new(first.reconnect(2).await);
        assert_eq!(
            reconnected.get_key("same-id").await.unwrap().as_deref(),
            Some("04aa")
        );
        assert_eq!(
            right.get_key("same-id").await.unwrap().as_deref(),
            Some("04bb")
        );
        let first_schema = first.schema.clone();
        first.cleanup().await;
        assert_eq!(
            right.get_key("same-id").await.unwrap().as_deref(),
            Some("04bb")
        );
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = $1)")
                .bind(first_schema)
                .fetch_one(&second.pool)
                .await
                .unwrap();
        assert!(!exists);
        second.cleanup().await;
    }
}
