use std::ffi::{CStr, CString};

use anim_svg_core::ffi::{
    anim_svg_convert, anim_svg_core_version, anim_svg_free_string, AnimSvgConvertOptions,
};

#[test]
fn version_is_exposed() {
    let ptr = anim_svg_core_version();
    assert!(!ptr.is_null());
    let s = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
    assert_eq!(s, env!("CARGO_PKG_VERSION"));
}

#[test]
fn convert_returns_envelope_even_for_stub() {
    let svg = CString::new("<svg xmlns=\"http://www.w3.org/2000/svg\"/>").unwrap();
    let opts = AnimSvgConvertOptions {
        log_level: std::ptr::null(),
        reserved: 0,
    };
    let out = unsafe { anim_svg_convert(svg.as_ptr(), &opts) };
    assert!(!out.is_null());

    let json = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
    unsafe { anim_svg_free_string(out) };

    let v: serde_json::Value = serde_json::from_str(&json).expect("envelope must be valid JSON");
    assert!(v.get("lottie").is_some());
    assert!(v.get("svg_raw").is_some());
    assert!(v.get("logs").is_some());
    assert!(v.get("error").is_some());
    // Phase 1 stub: error is populated.
    assert_eq!(
        v["error"]["kind"].as_str(),
        Some("unsupported_feature"),
        "phase 1 stub returns unsupported_feature"
    );
}

#[test]
fn convert_handles_null_svg() {
    let out = unsafe { anim_svg_convert(std::ptr::null(), std::ptr::null()) };
    assert!(out.is_null(), "null svg input returns null");
}

#[test]
fn free_string_accepts_null() {
    unsafe { anim_svg_free_string(std::ptr::null()) };
}
