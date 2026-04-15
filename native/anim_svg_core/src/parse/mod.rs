//! Parser pipeline — ports `lib/src/data/parsers/**`.
//!
//! Order of dependency (smallest → largest): `data_uri` → `transform`
//! → `path_data` → `animation` (SMIL) → `css` → `svgator` → `xml`
//! (the top-level SVG walker).

pub mod animation;
pub mod css;
pub mod data_uri;
pub mod path_data;
pub mod svgator;
pub mod transform;
