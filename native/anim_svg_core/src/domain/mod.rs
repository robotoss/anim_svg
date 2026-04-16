//! Domain layer — pure data shapes ported from `lib/src/domain/entities/`.
//!
//! Every type derives `Serialize` so the envelope can emit a JSON snapshot
//! of the parsed SvgDocument for Dart consumers that want to inspect the
//! intermediate tree (that's the `svg_raw` field in ConvertEnvelope).
//!
//! `rename_all = "camelCase"` is the convention across all domain types.

pub mod lottie;
pub mod svg;
pub mod svg_anim;
pub mod svg_motion_path;
pub mod svg_transform;

pub use lottie::*;
pub use svg::*;
pub use svg_anim::*;
pub use svg_motion_path::*;
pub use svg_transform::*;
