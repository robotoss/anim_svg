//! Parser pipeline — ports `lib/src/data/parsers/**`.
//!
//! Order of dependency (smallest → largest): `data_uri` → `transform`
//! → `path_data` → `animation` (SMIL) → `css` → `svgator` → `xml`
//! (the top-level SVG walker).

pub mod data_uri;
pub mod path_data;
pub mod transform;
