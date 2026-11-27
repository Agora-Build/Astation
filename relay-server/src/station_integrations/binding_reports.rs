//! The oldest unsettled ownership change for a list precedes all its later changes.
use super::*;
use crate::integration_portal::DelegatedReportAnswer;
use atem_client::control::ReportAnswer;
use sqlx::PgConnection;

pub(super) struct BindingReport {
    pub body: Value,
    account: String,
    genesis: String,
    version: i64,
}

impl BindingReport {
    pub async fn next(
        db: &mut PgConnection,
        station: &FeedBinding,
    ) -> Result<Option<Self>, sqlx::Error> {
        let row: Option<(Value, String, String, i64)> = sqlx::query_as(
            "SELECT report,account_id,genesis,version FROM (
                SELECT DISTINCT ON (account_id,genesis) account_id,genesis,version,report,report_due
                FROM station_pending_binding_reports WHERE (issuer,portal_origin,station_origin)=($1,$2,$3)
                ORDER BY account_id,genesis,version
             ) heads WHERE report_due<=statement_timestamp()
             ORDER BY report_due,account_id,genesis LIMIT 1",
        )
        .bind(&station.issuer).bind(&station.portal_origin).bind(&station.station_origin)
        .fetch_optional(db).await?;
        Ok(row.map(|(body, account, genesis, version)| Self {
            body,
            account,
            genesis,
            version,
        }))
    }

    pub async fn settle(
        &self,
        db: &mut PgConnection,
        station: &FeedBinding,
        result: &DelegatedReportAnswer,
    ) -> Result<(), sqlx::Error> {
        let outcome = match result.answer {
            ReportAnswer::Confirm => Some("confirmed"),
            ReportAnswer::Refuse => Some("refused"),
            ReportAnswer::Retry => None,
            ReportAnswer::StopReporting => {
                return Err(sqlx::Error::Protocol(
                    "client stop needs the reporting journal".into(),
                ))
            }
        };
        let table = if self.body["bindingState"] == "released" {
            "station_applied_binding_releases"
        } else {
            "station_native_binding_transitions"
        };
        let retry_ms = result
            .retry_after_ms
            .map(|ms| ms.clamp(1000, 86_400_000) as i64);
        let updated = sqlx::query(&format!(
            "UPDATE {table} SET report_outcome=$8,
             report_attempts=least(report_attempts,8)+1,
             report_due=clock_timestamp() + interval '1 millisecond' *
                 COALESCE($9::bigint,(1000::bigint << least(report_attempts+1,8)))
             WHERE (issuer,portal_origin,station_origin,account_id,genesis,version)=($1,$2,$3,$4,$5,$6)
             AND report=$7 AND report_outcome IS NULL"
        )).bind(&station.issuer).bind(&station.portal_origin).bind(&station.station_origin)
            .bind(&self.account).bind(&self.genesis).bind(self.version).bind(&self.body)
            .bind(outcome).bind(retry_ms).execute(db).await?;
        if updated.rows_affected() != 1 {
            return Err(sqlx::Error::Protocol(
                "binding report changed during delivery".into(),
            ));
        }
        Ok(())
    }
}
