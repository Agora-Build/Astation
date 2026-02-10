use chrono::{DateTime, Duration, Utc};
use rand::Rng;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionStatus {
    Pending,
    Granted,
    Denied,
    Expired,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub otp: String,
    pub hostname: String,
    pub status: SessionStatus,
    pub token: Option<String>,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

/// Generate an 8-digit numeric OTP.
pub fn generate_otp() -> String {
    let mut rng = rand::thread_rng();
    let otp: u32 = rng.gen_range(10_000_000..100_000_000);
    otp.to_string()
}

/// Generate a 64-character hex session token.
pub fn generate_session_token() -> String {
    let mut rng = rand::thread_rng();
    let bytes: Vec<u8> = (0..32).map(|_| rng.gen::<u8>()).collect();
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Create a new session with the given hostname.
/// The session has status=Pending, a generated UUID and OTP, and expires in 5 minutes.
pub fn create_session(hostname: &str) -> Session {
    let now = Utc::now();
    Session {
        id: Uuid::new_v4().to_string(),
        otp: generate_otp(),
        hostname: hostname.to_string(),
        status: SessionStatus::Pending,
        token: None,
        created_at: now,
        expires_at: now + Duration::minutes(5),
    }
}

/// Validate an OTP against a session.
/// Returns true if the OTP matches and the session has not expired.
pub fn validate_otp(session: &Session, otp: &str) -> bool {
    if session.otp != otp {
        return false;
    }
    if Utc::now() > session.expires_at {
        return false;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn test_generate_otp_format() {
        let otp = generate_otp();
        assert_eq!(otp.len(), 8, "OTP should be 8 digits");
        assert!(
            otp.chars().all(|c| c.is_ascii_digit()),
            "OTP should contain only digits"
        );
    }

    #[test]
    fn test_generate_otp_uniqueness() {
        // Generate multiple OTPs and verify they are not all the same
        let otps: Vec<String> = (0..10).map(|_| generate_otp()).collect();
        let unique: std::collections::HashSet<&String> = otps.iter().collect();
        assert!(unique.len() > 1, "Generated OTPs should vary");
    }

    #[test]
    fn test_generate_session_token_format() {
        let token = generate_session_token();
        assert_eq!(token.len(), 64, "Token should be 64 hex characters");
        assert!(
            token.chars().all(|c| c.is_ascii_hexdigit()),
            "Token should contain only hex characters"
        );
    }

    #[test]
    fn test_generate_session_token_uniqueness() {
        let tokens: Vec<String> = (0..10).map(|_| generate_session_token()).collect();
        let unique: std::collections::HashSet<&String> = tokens.iter().collect();
        assert!(unique.len() > 1, "Generated tokens should vary");
    }

    #[test]
    fn test_create_session() {
        let session = create_session("my-machine");
        assert!(!session.id.is_empty(), "Session ID should not be empty");
        // Validate UUID format
        assert!(
            Uuid::parse_str(&session.id).is_ok(),
            "Session ID should be a valid UUID"
        );
        assert_eq!(session.otp.len(), 8, "OTP should be 8 digits");
        assert_eq!(session.hostname, "my-machine");
        assert_eq!(session.status, SessionStatus::Pending);
        assert!(session.token.is_none(), "Token should be None initially");

        // Verify expiry is approximately 5 minutes from now
        let expected_duration = Duration::minutes(5);
        let actual_duration = session.expires_at - session.created_at;
        assert_eq!(actual_duration, expected_duration);
    }

    #[test]
    fn test_validate_otp_correct() {
        let session = create_session("test-host");
        let otp = session.otp.clone();
        assert!(validate_otp(&session, &otp), "Correct OTP should validate");
    }

    #[test]
    fn test_validate_otp_wrong() {
        let session = create_session("test-host");
        assert!(
            !validate_otp(&session, "00000000"),
            "Wrong OTP should not validate"
        );
    }

    #[test]
    fn test_validate_otp_expired() {
        let now = Utc::now();
        let session = Session {
            id: Uuid::new_v4().to_string(),
            otp: "12345678".to_string(),
            hostname: "test-host".to_string(),
            status: SessionStatus::Pending,
            token: None,
            created_at: now - Duration::minutes(10),
            expires_at: now - Duration::minutes(5), // Already expired
        };
        assert!(
            !validate_otp(&session, "12345678"),
            "Expired session OTP should not validate"
        );
    }

    #[test]
    fn test_session_status_serialization() {
        let status = SessionStatus::Pending;
        let json = serde_json::to_string(&status).unwrap();
        assert_eq!(json, "\"pending\"");

        let status = SessionStatus::Granted;
        let json = serde_json::to_string(&status).unwrap();
        assert_eq!(json, "\"granted\"");

        let status = SessionStatus::Denied;
        let json = serde_json::to_string(&status).unwrap();
        assert_eq!(json, "\"denied\"");

        let status = SessionStatus::Expired;
        let json = serde_json::to_string(&status).unwrap();
        assert_eq!(json, "\"expired\"");
    }

    #[test]
    fn test_session_status_deserialization() {
        let status: SessionStatus = serde_json::from_str("\"pending\"").unwrap();
        assert_eq!(status, SessionStatus::Pending);

        let status: SessionStatus = serde_json::from_str("\"granted\"").unwrap();
        assert_eq!(status, SessionStatus::Granted);
    }
}
