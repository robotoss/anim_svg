use std::fs;
use std::path::PathBuf;

use anim_svg_core::{convert, ConvertOptions, LogLevel};

fn fixtures_dir() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(|p| p.parent())
        .map(|p| p.join("example").join("assets"))
        .expect("locate example/assets")
}

fn load_svg(name: &str) -> String {
    let path = fixtures_dir().join(name);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {:?}: {}", path, e))
}

fn run_convert(svg: &str) -> anim_svg_core::ConvertEnvelope {
    let opts = ConvertOptions {
        log_level: LogLevel::Warn,
        frame_rate: 60.0,
    };
    convert(svg, opts)
}

fn position_warnings(env: &anim_svg_core::ConvertEnvelope) -> Vec<&anim_svg_core::LogEntry> {
    env.logs
        .iter()
        .filter(|e| e.stage == "validate.position")
        .collect()
}

#[test]
fn report_position_warnings_for_all_assets() {
    let dir = fixtures_dir();
    let mut total = 0usize;
    let mut with_warns = 0usize;
    for entry in fs::read_dir(&dir).expect("read example/assets") {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("svg") {
            continue;
        }
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let svg = fs::read_to_string(&path).expect("read svg");
        let env = run_convert(&svg);
        let warns = position_warnings(&env);
        total += 1;
        if !warns.is_empty() {
            with_warns += 1;
            eprintln!("\n--- {} -- {} position warnings ---", name, warns.len());
            for w in warns.iter().take(5) {
                let f = &w.fields;
                let s = |k: &str| {
                    f.get(k)
                        .map(|v| v.to_string())
                        .unwrap_or_else(|| "?".into())
                };
                eprintln!(
                    "  layer #{} '{}' ({}): pos=({}, {})  parent={}",
                    s("layer_index"),
                    f.get("layer_name").and_then(|v| v.as_str()).unwrap_or(""),
                    f.get("layer_type").and_then(|v| v.as_str()).unwrap_or(""),
                    s("position_x"),
                    s("position_y"),
                    s("parent_index"),
                );
            }
            if warns.len() > 5 {
                eprintln!("  … and {} more", warns.len() - 5);
            }
        }
    }
    eprintln!(
        "\nposition validator summary: {}/{} fixtures produced warnings",
        with_warns, total
    );
}

#[test]
#[ignore]
fn anim_5_must_have_no_offscreen_layers() {
    let svg = load_svg("svg_anim_5.svg");
    let env = run_convert(&svg);
    let warns = position_warnings(&env);
    assert!(
        warns.is_empty(),
        "svg_anim_5.svg has {} layers placed outside comp at t=0; \
         this is the transform-composition bug being tracked. \
         First offenders:\n{}",
        warns.len(),
        warns
            .iter()
            .take(5)
            .map(|w| format!("{:?}", w))
            .collect::<Vec<_>>()
            .join("\n")
    );
}
