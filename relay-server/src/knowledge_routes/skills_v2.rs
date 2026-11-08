//! Opt-in skill transport. The store and legacy routes retain base64; only
//! this boundary removes the outer encoding of already sealed file bytes.

use super::*;
use crate::encryption::envelope_kid;
use base64::{engine::general_purpose::STANDARD, Engine};

#[cfg(test)]
mod tests;

fn invalid_encoding() -> ErrResp {
    err(StatusCode::BAD_REQUEST, "invalid skill files encoding")
}

fn normalize_files(value: &mut Value) -> Result<(), ErrResp> {
    let encoding = value
        .get("files_encoding")
        .and_then(Value::as_str)
        .ok_or_else(invalid_encoding)?;
    if !matches!(encoding, "e1-text" | "base64") {
        return Err(invalid_encoding());
    }
    let sealed = encoding == "e1-text";
    let files = value
        .get_mut("files")
        .and_then(Value::as_object_mut)
        .ok_or_else(invalid_encoding)?;
    for (path, value) in files {
        let text = value.as_str().ok_or_else(invalid_encoding)?;
        if sealed {
            if envelope_kid(path).is_none() || envelope_kid(text).is_none() {
                return Err(invalid_encoding());
            }
            *value = Value::String(STANDARD.encode(text.as_bytes()));
        } else if STANDARD.decode(text).is_err() {
            return Err(invalid_encoding());
        }
    }
    value.as_object_mut().unwrap().remove("files_encoding");
    Ok(())
}

fn normalize_ops(mut ops: Vec<Value>) -> Result<Vec<SkillOp>, ErrResp> {
    for op in &mut ops {
        match op.get("op").and_then(Value::as_str) {
            Some("push") => normalize_files(op.get_mut("skill").ok_or_else(invalid_encoding)?)?,
            Some("rewrite") => normalize_files(op)?,
            _ => {}
        }
    }
    // Compact transport must not bypass the legacy batch's storage budget.
    let normalized = serde_json::to_vec(&ops).map_err(|_| invalid_encoding())?;
    if normalized.len() + b"{\"ops\":}".len() > SKILLS_BATCH_BODY_LIMIT {
        return Err(err(
            StatusCode::PAYLOAD_TOO_LARGE,
            "normalized request body too large",
        ));
    }
    ops.into_iter()
        .map(|op| {
            serde_json::from_value(op).map_err(|_| err(StatusCode::BAD_REQUEST, "invalid batch"))
        })
        .collect()
}

fn encode_row(row: &mut Value) {
    let sealed: Option<serde_json::Map<String, Value>> = row
        .get("files")
        .and_then(Value::as_object)
        .and_then(|files| {
            files
                .iter()
                .map(|(path, encoded)| {
                    envelope_kid(path)?;
                    let bytes = STANDARD.decode(encoded.as_str()?).ok()?;
                    let text = String::from_utf8(bytes).ok()?;
                    envelope_kid(&text)?;
                    Some((path.clone(), Value::String(text)))
                })
                .collect()
        });
    if let Some(files) = sealed {
        row["files"] = Value::Object(files);
        row["files_encoding"] = json!("e1-text");
    } else {
        // Legacy binary/plaintext and partial-migration history remain lossless.
        row["files_encoding"] = json!("base64");
    }
}

pub async fn batch_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AuthQuery>,
    body: Body,
) -> Result<Json<Value>, ErrResp> {
    let caller = resolve_caller(&state, &headers, query.id.as_deref()).await?;
    let ops: Vec<Value> = read_batch(body, SKILLS_BATCH_BODY_LIMIT, SKILLS_BATCH_MAX_OPS).await?;
    // Validate the entire transport before applying any op, as on the v1 route.
    let ops = normalize_ops(ops)?;
    let encryption = encryption_state(&state, &caller.work_session_id).await?;
    let mut results = Vec::with_capacity(ops.len());
    for op in ops {
        results.push(apply_skill_op(&state, &caller.work_session_id, &encryption, op).await?);
    }
    Ok(Json(json!({"wire_version": 2, "results": results})))
}

pub async fn pull_handler(
    state: State<AppState>,
    headers: HeaderMap,
    query: Query<PullQuery>,
) -> Result<Json<Value>, ErrResp> {
    let Json(mut body) = skills_pull_handler(state, headers, query).await?;
    for row in body["skills"].as_array_mut().unwrap() {
        encode_row(row);
    }
    body["wire_version"] = json!(2);
    Ok(Json(body))
}

pub async fn versions_handler(
    state: State<AppState>,
    headers: HeaderMap,
    query: Query<SkillKeyQuery>,
) -> Result<Json<Value>, ErrResp> {
    let Json(mut body) = skill_versions_handler(state, headers, query).await?;
    body["wire_version"] = json!(2);
    Ok(Json(body))
}

pub async fn version_handler(
    state: State<AppState>,
    headers: HeaderMap,
    query: Query<SkillKeyQuery>,
) -> Result<Json<Value>, ErrResp> {
    let Json(mut body) = skill_version_handler(state, headers, query).await?;
    encode_row(&mut body["skill"]);
    body["wire_version"] = json!(2);
    Ok(Json(body))
}
