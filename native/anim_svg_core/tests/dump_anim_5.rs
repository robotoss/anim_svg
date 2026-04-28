use std::collections::HashSet;
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

#[test]
fn anim_5_layer_structure_dump() {
    let path = fixtures_dir().join("svg_anim_5.svg");
    let svg = fs::read_to_string(&path).unwrap();
    let opts = ConvertOptions {
        log_level: LogLevel::Warn,
        frame_rate: 60.0,
    };
    let env = convert(&svg, opts);
    let lottie = &env.lottie;
    let layers = lottie["layers"].as_array().expect("layers array");

    eprintln!("\n=== svg_anim_5 layer structure ===");
    eprintln!("comp: {}x{}", lottie["w"], lottie["h"]);
    eprintln!("layer count: {}", layers.len());

    let mut all_inds: HashSet<i64> = HashSet::new();
    for l in layers {
        if let Some(ind) = l["ind"].as_i64() {
            all_inds.insert(ind);
        }
    }

    let mut bad_parents = Vec::new();
    let mut by_ty: std::collections::BTreeMap<i64, usize> = Default::default();
    for l in layers {
        let ty = l["ty"].as_i64().unwrap_or(-1);
        *by_ty.entry(ty).or_default() += 1;
        if let Some(p) = l["parent"].as_i64() {
            if !all_inds.contains(&p) {
                bad_parents.push((
                    l["ind"].as_i64().unwrap_or(-1),
                    l["nm"].as_str().unwrap_or("").to_string(),
                    p,
                ));
            }
        }
    }
    eprintln!("layer types: {:?} (2=image, 3=null, 4=shape)", by_ty);

    if !bad_parents.is_empty() {
        eprintln!("\n!!! UNRESOLVED PARENT REFERENCES !!!");
        for (ind, nm, p) in &bad_parents {
            eprintln!("  layer ind={} '{}' has parent={} which does not exist", ind, nm, p);
        }
    }

    eprintln!("\nlayer dump (ind | parent | ty | nm | pos):");
    for l in layers {
        let ind = l["ind"].as_i64().unwrap_or(-1);
        let parent = l
            .get("parent")
            .and_then(|p| p.as_i64())
            .map(|p| p.to_string())
            .unwrap_or_else(|| "—".into());
        let ty = l["ty"].as_i64().unwrap_or(-1);
        let nm = l["nm"].as_str().unwrap_or("");
        let pos = &l["ks"]["p"];
        let scale = &l["ks"]["s"];
        let pos_str = if pos.get("a").and_then(|a| a.as_i64()) == Some(1) {
            format!(
                "anim[{}kf]",
                pos["k"].as_array().map(|a| a.len()).unwrap_or(0)
            )
        } else {
            format!("{}", pos.get("k").map(|k| k.to_string()).unwrap_or_default())
        };
        let scale_str = if scale.get("a").and_then(|a| a.as_i64()) == Some(1) {
            "anim".into()
        } else {
            format!("{}", scale.get("k").map(|k| k.to_string()).unwrap_or_default())
        };
        let rot = &l["ks"]["r"];
        let skew = &l["ks"]["sk"];
        let rot_str = if rot.get("a").and_then(|a| a.as_i64()) == Some(1) {
            "anim".into()
        } else {
            format!("{}", rot.get("k").map(|k| k.to_string()).unwrap_or_default())
        };
        let skew_str = if skew.get("a").and_then(|a| a.as_i64()) == Some(1) {
            "anim".into()
        } else {
            format!("{}", skew.get("k").map(|k| k.to_string()).unwrap_or_default())
        };
        eprintln!(
            "  {:>3} | parent={:<4} | ty={} | {:<22} | pos={} scale={} rot={} skew={}",
            ind, parent, ty, nm, pos_str, scale_str, rot_str, skew_str
        );
    }

    assert!(
        bad_parents.is_empty(),
        "{} layers have unresolved parent references",
        bad_parents.len()
    );
}
