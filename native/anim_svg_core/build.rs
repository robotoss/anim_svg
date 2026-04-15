use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let crate_dir = PathBuf::from(crate_dir);
    let out_header = crate_dir.join("include").join("anim_svg_core.h");

    println!("cargo:rerun-if-changed=src/ffi.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");

    match cbindgen::generate(&crate_dir) {
        Ok(bindings) => {
            bindings.write_to_file(&out_header);
        }
        Err(err) => {
            println!("cargo:warning=cbindgen failed: {err}");
        }
    }
}
