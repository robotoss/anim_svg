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
fn convert_returns_full_envelope_for_trivial_svg() {
    let svg = CString::new(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\">\
         <rect x=\"1\" y=\"1\" width=\"8\" height=\"8\" fill=\"#f00\"/></svg>",
    )
    .unwrap();
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
    assert!(v["error"].is_null(), "happy path produces no error");
    assert!(v["lottie"].is_object(), "lottie must be a populated object");
    assert!(v["svg_raw"].is_object(), "svg_raw reflects parsed tree");
}

#[test]
fn convert_reports_parse_error_for_malformed_xml() {
    let svg = CString::new("<svg xmlns=\"http://www.w3.org/2000/svg\"><unclosed>").unwrap();
    let opts = AnimSvgConvertOptions {
        log_level: std::ptr::null(),
        reserved: 0,
    };
    let out = unsafe { anim_svg_convert(svg.as_ptr(), &opts) };
    assert!(!out.is_null());
    let json = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
    unsafe { anim_svg_free_string(out) };
    let v: serde_json::Value = serde_json::from_str(&json).expect("envelope must be valid JSON");
    assert_eq!(v["error"]["kind"].as_str(), Some("parse"));
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
