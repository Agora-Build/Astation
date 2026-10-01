//! Redis key and channel names (spec: "Redis keys"). Everything is under
//! `relay:`. Client-supplied parts are escaped (`%` → `%25`, `:` → `%3A`)
//! so an id can't name another key (a room code `X:atems` would otherwise
//! be room X's Atem hash). Real ids contain neither character.

use std::borrow::Cow;

pub fn part(raw: &str) -> Cow<'_, str> {
    if raw.contains(['%', ':']) {
        Cow::Owned(raw.replace('%', "%25").replace(':', "%3A"))
    } else {
        Cow::Borrowed(raw)
    }
}

pub fn unpart(escaped: &str) -> String {
    escaped.replace("%3A", ":").replace("%25", "%")
}

/// Sorted set of live replica ids, scored by expiry (unix seconds).
pub const REPLICAS_INDEX: &str = "relay:replicas";
pub const REPLICA_PREFIX: &str = "relay:replica:";
// Spec key-table name only: presence lists replicas from REPLICAS_INDEX
// rather than SCANning this pattern, so only the key-table test reads it.
#[cfg(test)]
pub const REPLICA_PATTERN: &str = "relay:replica:*";
pub const VOICE_PREFIX: &str = "relay:voice:";
pub const VOICE_PATTERN: &str = "relay:voice:*";
pub const BROADCAST_CHANNEL: &str = "relay:broadcast";
pub const VOICE_REPLY_CHANNEL_PREFIX: &str = "relay:voice-reply:";
pub const VOICE_REPLY_PATTERN: &str = "relay:voice-reply:*";

pub fn replica(replica_id: &str) -> String {
    format!("{REPLICA_PREFIX}{}", part(replica_id))
}

pub fn room(code: &str) -> String {
    format!("relay:room:{}", part(code))
}

pub fn room_atems(code: &str) -> String {
    format!("relay:room:{}:atems", part(code))
}

pub fn room_pending(code: &str) -> String {
    format!("relay:room:{}:pending", part(code))
}

pub fn session(id: &str) -> String {
    format!("relay:session:{}", part(id))
}

pub fn voice(id: &str) -> String {
    format!("{VOICE_PREFIX}{}", part(id))
}

pub fn voice_reply(id: &str) -> String {
    format!("{VOICE_PREFIX}{}:reply", part(id))
}

pub fn rtc(id: &str) -> String {
    format!("relay:rtc:{}", part(id))
}

/// Fixed one-minute window counter; `minute` is unix seconds / 60.
pub fn rate(bucket: &str, ip: &str, minute: i64) -> String {
    format!("relay:rl:{}:{}:{}", part(bucket), part(ip), minute)
}

pub fn inbox_channel(replica_id: &str) -> String {
    format!("relay:inbox:{}", part(replica_id))
}

pub fn voice_reply_channel(id: &str) -> String {
    format!("{VOICE_REPLY_CHANNEL_PREFIX}{}", part(id))
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_match_the_spec_tables() {
        assert_eq!(replica("a1b2c3d4e5f6"), "relay:replica:a1b2c3d4e5f6");
        assert_eq!(room("ABCD-EFGH"), "relay:room:ABCD-EFGH");
        assert_eq!(room_atems("ABCD-EFGH"), "relay:room:ABCD-EFGH:atems");
        assert_eq!(room_pending("ABCD-EFGH"), "relay:room:ABCD-EFGH:pending");
        assert_eq!(session("s-1"), "relay:session:s-1");
        assert_eq!(voice("v-1"), "relay:voice:v-1");
        assert_eq!(voice_reply("v-1"), "relay:voice:v-1:reply");
        assert_eq!(rtc("r-1"), "relay:rtc:r-1");
        assert_eq!(rate("grant", "203.0.113.9", 28_333_333), "relay:rl:grant:203.0.113.9:28333333");
        assert_eq!(inbox_channel("a1b2"), "relay:inbox:a1b2");
        assert_eq!(BROADCAST_CHANNEL, "relay:broadcast");
        assert_eq!(voice_reply_channel("v-1"), "relay:voice-reply:v-1");
        assert_eq!(VOICE_REPLY_PATTERN, "relay:voice-reply:*");
        assert_eq!(REPLICA_PATTERN, "relay:replica:*");
    }

    #[test]
    fn client_supplied_parts_cannot_reach_other_keys() {
        assert_eq!(room("X:atems"), "relay:room:X%3Aatems");
        assert_eq!(voice("x:reply"), "relay:voice:x%3Areply");
        assert_eq!(rate("general", "::1", 1), "relay:rl:general:%3A%3A1:1");
        for raw in ["plain", "a:b", "100%", "%3A", "a%25:b", "日本:語"] {
            assert_eq!(unpart(&part(raw)), raw);
        }
    }
}
