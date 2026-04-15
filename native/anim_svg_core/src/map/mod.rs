//! Mapping layer — converts `SvgDocument` entities into Lottie domain types.
//!
//! Ported from `lib/src/data/mappers/`.

pub mod display;
pub mod image_asset;
pub mod keyspline;
pub mod motion_path;
pub mod nested_anim;
pub mod normalize;
pub mod opacity;
pub mod opacity_merge;
pub mod raster_transcoder;
pub mod shape;
pub mod svg_to_lottie;
pub mod transform_map;
pub mod use_flatten;
