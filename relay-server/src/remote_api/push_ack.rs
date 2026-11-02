//! R9.9 acknowledgment transport encoding. This does not verify a hint or
//! establish durable handling: callers must obtain complete identities from
//! the shared verifier and commit their disposition before calling `encode`.
//! The returned text is the complete Atem-link message, without another
//! `data` wrapper. Do not add fields after enforcing the encoded-byte limit.

use serde_json::Value;

pub const MAX_RELAY_MESSAGE_BYTES: usize = 262_144;
const PREFIX: &str = r#"{"type":"relay","op":"push_ack","acks":["#;
const SUFFIX: &str = "]}";

#[derive(Debug)]
pub enum EncodeError {
    /// An indivisible identity cannot fit; nothing is silently truncated or
    /// omitted, and the caller receives no partial batch to send.
    IdentityTooLarge {
        index: usize,
    },
    Json(serde_json::Error),
}

/// Split complete, durably handled shared-core `Identity::to_ack` values by
/// their actual UTF-8 JSON encoding, including commas and the entire wrapper.
/// Order and duplicates are retained. No message is needed for an empty list.
pub fn encode(identities: &[Value]) -> Result<Vec<String>, EncodeError> {
    let mut messages = Vec::new();
    let mut current = String::from(PREFIX);
    let mut has_identity = false;
    for (index, identity) in identities.iter().enumerate() {
        let encoded = serde_json::to_string(identity).map_err(EncodeError::Json)?;
        if PREFIX.len() + encoded.len() + SUFFIX.len() > MAX_RELAY_MESSAGE_BYTES {
            return Err(EncodeError::IdentityTooLarge { index });
        }
        let separator = usize::from(has_identity);
        if current.len() + separator + encoded.len() + SUFFIX.len() > MAX_RELAY_MESSAGE_BYTES {
            current.push_str(SUFFIX);
            messages.push(current);
            current = String::from(PREFIX);
            has_identity = false;
        }
        if has_identity {
            current.push(',');
        }
        current.push_str(&encoded);
        has_identity = true;
    }
    if has_identity {
        current.push_str(SUFFIX);
        messages.push(current);
    }
    Ok(messages)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Identity fields from r9-vectors-push-hint at accepted contract c685aba;
    // the actual Identity::to_ack shape is pinned at Atem 12c3c151a0d5,
    // crates/atem-client/src/push.rs (blob b18712ad781ff2384aa9d8269efb81ae16f323d7).
    fn open() -> Value {
        json!({
            "kind": "hint", "state": "open", "account_id": "acct-test-1",
            "genesis_hash": "93501542f5f9f4a7ce3d08f79e267d4d80df3f8e35ae852f47216e3cc559cd89",
            "host_id": "host-a", "host_trust_gen": 1,
            "session_id": "ses-aaaaaaaaaaaa", "process_gen": "22222222-2222-4222-8222-222222222222",
            "approval_id": "8c3e9d6b-1f40-4b52-8dae-4f5a6b7c8d9e", "device_id": "dev-phone"
        })
    }

    fn round_trip(messages: &[String]) -> Vec<Value> {
        messages
            .iter()
            .flat_map(|message| {
                assert!(message.len() <= MAX_RELAY_MESSAGE_BYTES);
                let value: Value = serde_json::from_str(message).unwrap();
                assert_eq!(value.as_object().unwrap().len(), 3);
                assert_eq!(value["type"], "relay");
                assert_eq!(value["op"], "push_ack");
                let acks = value["acks"].as_array().unwrap();
                assert!(!acks.is_empty());
                acks.clone()
            })
            .collect()
    }

    #[test]
    fn public_identity_crosses_the_limit_at_771_with_the_wrapper() {
        let identities = vec![open(); 771];
        assert_eq!(serde_json::to_vec(&identities[0]).unwrap().len(), 339);
        // A fixed count of 771 or an acks-only length check would lose ACKs:
        // Atem drops the entire 262181-byte message unread.
        let unsplit =
            serde_json::to_string(&json!({"type":"relay","op":"push_ack","acks":identities}))
                .unwrap();
        assert_eq!(unsplit.len(), 262_181);
        let messages = encode(&identities).unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].len(), 261_841);
        assert_eq!(round_trip(&messages), identities);
    }

    #[test]
    fn full_identity_and_order_survive_multiple_batches() {
        let mut resolved = open();
        resolved["state"] = json!("resolved");
        resolved.as_object_mut().unwrap().remove("device_id");
        let mut seen = open();
        seen["kind"] = json!("seen");
        seen.as_object_mut().unwrap().remove("state");
        seen["host_trust_gen"] = json!(9_007_199_254_740_991u64);
        let identities: Vec<_> = (0..1800)
            .map(|n| {
                let mut identity = [open(), resolved.clone(), seen.clone()][n % 3].clone();
                identity["session_id"] = json!(format!("session-{n}"));
                identity
            })
            .collect();
        let messages = encode(&identities).unwrap();
        assert!(messages.len() >= 3);
        assert_eq!(round_trip(&messages), identities);
    }

    #[test]
    fn utf8_and_json_escaping_determine_boundaries() {
        let mut identity = open();
        identity["device_id"] = json!("📱\"\\\n".repeat(30));
        let identities = vec![identity; 1200];
        let messages = encode(&identities).unwrap();
        assert_eq!(round_trip(&messages), identities);
        // Every completed batch is full enough that its next complete
        // identity and comma could not have fit, measured as encoded bytes.
        let next_bytes = serde_json::to_vec(&identities[0]).unwrap().len();
        for message in &messages[..messages.len() - 1] {
            assert!(message.len() + 1 + next_bytes > MAX_RELAY_MESSAGE_BYTES);
        }
    }

    #[test]
    fn exact_limit_fits_but_one_more_byte_does_not() {
        let mut identity = open();
        identity["device_id"] = json!("");
        let overhead = encode(&[identity.clone()]).unwrap()[0].len();
        identity["device_id"] = json!("a".repeat(MAX_RELAY_MESSAGE_BYTES - overhead));
        let messages = encode(&[identity.clone(), open()]).unwrap();
        assert_eq!(messages[0].len(), MAX_RELAY_MESSAGE_BYTES);
        assert_eq!(round_trip(&messages), vec![identity.clone(), open()]);
        identity["device_id"] = json!(format!("{}a", identity["device_id"].as_str().unwrap()));
        assert!(matches!(
            encode(&[open(), identity]),
            Err(EncodeError::IdentityTooLarge { index: 1 })
        ));
    }

    #[test]
    fn empty_input_has_nothing_to_acknowledge() {
        assert!(encode(&[]).unwrap().is_empty());
    }
}
