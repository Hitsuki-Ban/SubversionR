#![no_main]

use libfuzzer_sys::{fuzz_target, Corpus};

const MAX_FUZZ_INPUT_BYTES: usize = 65_536;
const TARGET_TRACE_ID: &str = "NATIVE-REMOTE-FUZZ-001";
const TARGET_SCOPE: &str = "svn:// history/log";
const SOURCE_SEED_ID: &str = "malicious-log-response-v1";

fuzz_target!(|data: &[u8]| -> Corpus {
    if data.is_empty() || data.len() > MAX_FUZZ_INPUT_BYTES {
        return Corpus::Reject;
    }

    let candidate = FuzzLogResponse::from_bytes(data);
    if !candidate.looks_like_history_log() {
        return Corpus::Reject;
    }

    let _ = (TARGET_TRACE_ID, TARGET_SCOPE, SOURCE_SEED_ID);
    candidate.scan_length_prefixed_tokens();
    Corpus::Keep
});

struct FuzzLogResponse<'a> {
    bytes: &'a [u8],
}

impl<'a> FuzzLogResponse<'a> {
    fn from_bytes(bytes: &'a [u8]) -> Self {
        Self { bytes }
    }

    fn looks_like_history_log(&self) -> bool {
        self.bytes.windows(6).any(|window| window == b"( ( ) ")
            && self.bytes.iter().any(u8::is_ascii_digit)
            && self.bytes.contains(&b':')
    }

    fn scan_length_prefixed_tokens(&self) -> usize {
        let mut index = 0usize;
        let mut tokens = 0usize;
        while index < self.bytes.len() && tokens < 64 {
            if !self.bytes[index].is_ascii_digit() {
                index += 1;
                continue;
            }
            let start = index;
            while index < self.bytes.len()
                && self.bytes[index].is_ascii_digit()
                && index - start < 9
            {
                index += 1;
            }
            if index == self.bytes.len() || self.bytes[index] != b':' {
                continue;
            }
            let Ok(length_text) = std::str::from_utf8(&self.bytes[start..index]) else {
                continue;
            };
            let Ok(length) = length_text.parse::<usize>() else {
                continue;
            };
            index += 1;
            if index
                .checked_add(length)
                .is_none_or(|end| end > self.bytes.len())
            {
                break;
            }
            index += length;
            tokens += 1;
        }
        tokens
    }
}
