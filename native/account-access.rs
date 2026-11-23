use hbb_common::{config::Config, sodiumoxide::crypto::auth::hmacsha256};
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) fn session_passwords(device_id: &str) -> Option<[String; 3]> {
    hbb_common::sodiumoxide::init().ok()?;
    let path = Config::file().with_file_name("DesklinkAccess.key");
    let text = std::fs::read_to_string(path).ok()?;
    let raw = text.trim().as_bytes();
    if raw.len() != 64 {
        return None;
    }
    let mut key = [0; 32];
    for (output, pair) in key.iter_mut().zip(raw.chunks_exact(2)) {
        *output = u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()?;
    }
    let key = hmacsha256::Key::from_slice(&key)?;
    let slot = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() / 30;
    // A neighboring time slot on either side allows for clock skew and network transit.
    Some([slot.saturating_sub(1), slot, slot + 1].map(|slot| {
        let input = format!("desklink-native-v1:{device_id}:{slot}");
        hmacsha256::authenticate(input.as_bytes(), &key)
            .0
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }))
}
