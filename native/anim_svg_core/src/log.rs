use serde::Serialize;
use serde_json::Value;

/// Log levels, numerically ordered so comparisons filter correctly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Trace,
    Debug,
    #[default]
    Info,
    Warn,
    Error,
}

impl LogLevel {
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "trace" => Some(Self::Trace),
            "debug" => Some(Self::Debug),
            "info" => Some(Self::Info),
            "warn" | "warning" => Some(Self::Warn),
            "error" | "err" => Some(Self::Error),
            _ => None,
        }
    }
}

/// A single log entry. Mirrors the Dart `AnimSvgLogger` call signature so
/// the Dart side can replay it onto the caller-provided logger.
#[derive(Debug, Clone, Serialize)]
pub struct LogEntry {
    pub level: LogLevel,
    pub stage: String,
    pub message: String,
    #[serde(skip_serializing_if = "serde_json::Map::is_empty")]
    pub fields: serde_json::Map<String, Value>,
}

/// Collects log entries for a single conversion call. Per-call, not global —
/// the FFI boundary is fully re-entrant.
#[derive(Debug, Clone)]
pub struct LogCollector {
    min_level: LogLevel,
    entries: Vec<LogEntry>,
}

impl LogCollector {
    pub fn new(min_level: LogLevel) -> Self {
        Self {
            min_level,
            entries: Vec::new(),
        }
    }

    pub fn push(&mut self, level: LogLevel, stage: &str, message: &str, fields: &[(&str, Value)]) {
        if level < self.min_level {
            return;
        }
        let mut map = serde_json::Map::with_capacity(fields.len());
        for (k, v) in fields {
            map.insert((*k).to_string(), v.clone());
        }
        self.entries.push(LogEntry {
            level,
            stage: stage.to_string(),
            message: message.to_string(),
            fields: map,
        });
    }

    pub fn trace(&mut self, stage: &str, message: &str, fields: &[(&str, Value)]) {
        self.push(LogLevel::Trace, stage, message, fields);
    }
    pub fn debug(&mut self, stage: &str, message: &str, fields: &[(&str, Value)]) {
        self.push(LogLevel::Debug, stage, message, fields);
    }
    pub fn info(&mut self, stage: &str, message: &str, fields: &[(&str, Value)]) {
        self.push(LogLevel::Info, stage, message, fields);
    }
    pub fn warn(&mut self, stage: &str, message: &str, fields: &[(&str, Value)]) {
        self.push(LogLevel::Warn, stage, message, fields);
    }
    pub fn error(&mut self, stage: &str, message: &str, fields: &[(&str, Value)]) {
        self.push(LogLevel::Error, stage, message, fields);
    }

    pub fn into_entries(self) -> Vec<LogEntry> {
        self.entries
    }
}
