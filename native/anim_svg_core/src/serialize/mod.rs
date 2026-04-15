//! Serializers that take native domain types and produce the wire-format
//! Lottie JSON. The domain layer uses descriptive Rust field names; the
//! Lottie schema uses short two-letter keys (`ks`, `ty`, ...) and is
//! position-sensitive enough that serde's auto-derive isn't a good fit.
//! Each serializer below hand-builds a `serde_json::Value`.

pub mod lottie;

pub use lottie::serialize;
