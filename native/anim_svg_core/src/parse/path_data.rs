//! Port of `lib/src/data/parsers/svg_path_data_parser.dart`.
//!
//! SVG path `d` → flat list of cubic-bezier contours. Every SVG command
//! is normalised to cubics so the Lottie `sh` emitter has one uniform
//! shape representation.

use once_cell::sync::Lazy;
use regex::Regex;

use crate::log::LogCollector;

/// One cubic-bezier contour. Matches Lottie's `sh`: `v` (vertices),
/// `i` (in-tangents relative to vertex), `o` (out-tangents relative to
/// vertex), `c` (closed flag).
#[derive(Debug, Clone, Default)]
pub struct CubicContour {
    pub vertices: Vec<[f64; 2]>,
    pub in_tangents: Vec<[f64; 2]>,
    pub out_tangents: Vec<[f64; 2]>,
    pub closed: bool,
}

#[derive(Debug, Clone, Copy)]
enum Token {
    Cmd(char),
    Num(f64),
}

static TOKEN_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[MmLlHhVvCcSsQqTtAaZz]|[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?").unwrap()
});

fn tokenize(d: &str) -> Vec<Token> {
    let mut out = Vec::new();
    for m in TOKEN_RE.find_iter(d) {
        let s = m.as_str();
        let first = s.as_bytes()[0];
        let is_alpha = (0x41..=0x5A).contains(&first) || (0x61..=0x7A).contains(&first);
        if is_alpha {
            out.push(Token::Cmd(first as char));
        } else if let Ok(n) = s.parse::<f64>() {
            if n.is_finite() {
                out.push(Token::Num(n));
            }
        }
    }
    out
}

/// Parses the `d` attribute into cubic contours. Empty/invalid input
/// yields an empty vec.
///
/// `drop_closing_duplicate` trims a coincident final vertex on closed
/// contours (Lottie's static `sh` prefers the triplet without an
/// explicit close-vertex). Pass `false` for animated `attributeName="d"`
/// frames — the trim would yield inconsistent vertex counts across
/// keyframes when the endpoint lands within epsilon on some frames but
/// not others.
pub fn parse(d: &str, drop_closing_duplicate: bool, logs: &mut LogCollector) -> Vec<CubicContour> {
    let tokens = tokenize(d);
    if tokens.is_empty() {
        return Vec::new();
    }

    let mut contours: Vec<CubicContour> = Vec::new();
    let mut verts: Vec<[f64; 2]> = Vec::new();
    let mut ins: Vec<[f64; 2]> = Vec::new();
    let mut outs: Vec<[f64; 2]> = Vec::new();

    let mut x = 0.0_f64;
    let mut y = 0.0_f64;
    let mut start_x = 0.0_f64;
    let mut start_y = 0.0_f64;
    let mut last_cubic_ctrl: Option<(f64, f64)> = None;
    let mut last_quad_ctrl: Option<(f64, f64)> = None;

    let close_contour = |closed: bool,
                         verts: &mut Vec<[f64; 2]>,
                         ins: &mut Vec<[f64; 2]>,
                         outs: &mut Vec<[f64; 2]>,
                         contours: &mut Vec<CubicContour>| {
        if verts.is_empty() {
            return;
        }
        if drop_closing_duplicate && closed && verts.len() > 1 {
            let last = *verts.last().unwrap();
            let first = verts[0];
            if (last[0] - first[0]).abs() < 1e-6 && (last[1] - first[1]).abs() < 1e-6 {
                let last_in = *ins.last().unwrap();
                if ins[0][0].abs() < 1e-9 && ins[0][1].abs() < 1e-9 {
                    ins[0] = last_in;
                }
                verts.pop();
                ins.pop();
                outs.pop();
            }
        }
        contours.push(CubicContour {
            vertices: std::mem::take(verts),
            in_tangents: std::mem::take(ins),
            out_tangents: std::mem::take(outs),
            closed,
        });
    };

    let add_vertex = |vx: f64,
                      vy: f64,
                      verts: &mut Vec<[f64; 2]>,
                      ins: &mut Vec<[f64; 2]>,
                      outs: &mut Vec<[f64; 2]>| {
        verts.push([vx, vy]);
        ins.push([0.0, 0.0]);
        outs.push([0.0, 0.0]);
    };

    let set_out = |cx: f64,
                   cy: f64,
                   verts: &Vec<[f64; 2]>,
                   outs: &mut Vec<[f64; 2]>| {
        if outs.is_empty() {
            return;
        }
        let v = *verts.last().unwrap();
        let last = outs.len() - 1;
        outs[last] = [cx - v[0], cy - v[1]];
    };

    let set_in = |cx: f64,
                  cy: f64,
                  verts: &Vec<[f64; 2]>,
                  ins: &mut Vec<[f64; 2]>| {
        if ins.is_empty() {
            return;
        }
        let v = *verts.last().unwrap();
        let last = ins.len() - 1;
        ins[last] = [cx - v[0], cy - v[1]];
    };

    let mut i = 0usize;
    while i < tokens.len() {
        let cmd_ch = match tokens[i] {
            Token::Cmd(c) => c,
            Token::Num(v) => {
                logs.warn(
                    "parse.path",
                    "unexpected number without command",
                    &[("at", (i as u64).into()), ("value", v.into())],
                );
                i += 1;
                continue;
            }
        };
        let is_rel = cmd_ch.is_ascii_lowercase();
        let upper = cmd_ch.to_ascii_uppercase();

        // Pulls the next number, advancing `i`. Returns 0.0 on missing.
        let take_num = |i: &mut usize, tokens: &[Token], logs: &mut LogCollector, cmd: char| -> f64 {
            *i += 1;
            if *i >= tokens.len() {
                logs.warn(
                    "parse.path",
                    "missing number after command",
                    &[("cmd", cmd.to_string().into())],
                );
                return 0.0;
            }
            match tokens[*i] {
                Token::Num(n) => n,
                Token::Cmd(_) => {
                    logs.warn(
                        "parse.path",
                        "missing number after command",
                        &[("cmd", cmd.to_string().into())],
                    );
                    0.0
                }
            }
        };

        let peek_num = |i: usize, tokens: &[Token]| -> bool {
            i + 1 < tokens.len() && matches!(tokens[i + 1], Token::Num(_))
        };

        match upper {
            'M' => {
                if !verts.is_empty() {
                    close_contour(false, &mut verts, &mut ins, &mut outs, &mut contours);
                }
                let nx = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                let ny = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                x = nx;
                y = ny;
                start_x = x;
                start_y = y;
                add_vertex(x, y, &mut verts, &mut ins, &mut outs);
                last_cubic_ctrl = None;
                last_quad_ctrl = None;
                // Implicit L pairs after M.
                while peek_num(i, &tokens)
                    && (i + 2 >= tokens.len() || matches!(tokens[i + 2], Token::Num(_)))
                {
                    let lx = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ly = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    x = lx;
                    y = ly;
                    add_vertex(x, y, &mut verts, &mut ins, &mut outs);
                }
                i += 1;
            }
            'L' => {
                while peek_num(i, &tokens) {
                    let lx = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ly = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    x = lx;
                    y = ly;
                    add_vertex(x, y, &mut verts, &mut ins, &mut outs);
                }
                last_cubic_ctrl = None;
                last_quad_ctrl = None;
                i += 1;
            }
            'H' => {
                while peek_num(i, &tokens) {
                    let nx = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    x = nx;
                    add_vertex(x, y, &mut verts, &mut ins, &mut outs);
                }
                last_cubic_ctrl = None;
                last_quad_ctrl = None;
                i += 1;
            }
            'V' => {
                while peek_num(i, &tokens) {
                    let ny = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    y = ny;
                    add_vertex(x, y, &mut verts, &mut ins, &mut outs);
                }
                last_cubic_ctrl = None;
                last_quad_ctrl = None;
                i += 1;
            }
            'C' => {
                while peek_num(i, &tokens) {
                    let x1 = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let y1 = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let x2 = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let y2 = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ex = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ey = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    set_out(x1, y1, &verts, &mut outs);
                    add_vertex(ex, ey, &mut verts, &mut ins, &mut outs);
                    set_in(x2, y2, &verts, &mut ins);
                    x = ex;
                    y = ey;
                    last_cubic_ctrl = Some((x2, y2));
                }
                last_quad_ctrl = None;
                i += 1;
            }
            'S' => {
                while peek_num(i, &tokens) {
                    let rx = match last_cubic_ctrl {
                        Some((cx, _)) => 2.0 * x - cx,
                        None => x,
                    };
                    let ry = match last_cubic_ctrl {
                        Some((_, cy)) => 2.0 * y - cy,
                        None => y,
                    };
                    let x2 = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let y2 = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ex = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ey = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    set_out(rx, ry, &verts, &mut outs);
                    add_vertex(ex, ey, &mut verts, &mut ins, &mut outs);
                    set_in(x2, y2, &verts, &mut ins);
                    x = ex;
                    y = ey;
                    last_cubic_ctrl = Some((x2, y2));
                }
                last_quad_ctrl = None;
                i += 1;
            }
            'Q' => {
                while peek_num(i, &tokens) {
                    let qx = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let qy = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ex = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ey = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let c1x = x + 2.0 / 3.0 * (qx - x);
                    let c1y = y + 2.0 / 3.0 * (qy - y);
                    let c2x = ex + 2.0 / 3.0 * (qx - ex);
                    let c2y = ey + 2.0 / 3.0 * (qy - ey);
                    set_out(c1x, c1y, &verts, &mut outs);
                    add_vertex(ex, ey, &mut verts, &mut ins, &mut outs);
                    set_in(c2x, c2y, &verts, &mut ins);
                    x = ex;
                    y = ey;
                    last_quad_ctrl = Some((qx, qy));
                }
                last_cubic_ctrl = None;
                i += 1;
            }
            'T' => {
                while peek_num(i, &tokens) {
                    let qx = match last_quad_ctrl {
                        Some((cx, _)) => 2.0 * x - cx,
                        None => x,
                    };
                    let qy = match last_quad_ctrl {
                        Some((_, cy)) => 2.0 * y - cy,
                        None => y,
                    };
                    let ex = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ey = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let c1x = x + 2.0 / 3.0 * (qx - x);
                    let c1y = y + 2.0 / 3.0 * (qy - y);
                    let c2x = ex + 2.0 / 3.0 * (qx - ex);
                    let c2y = ey + 2.0 / 3.0 * (qy - ey);
                    set_out(c1x, c1y, &verts, &mut outs);
                    add_vertex(ex, ey, &mut verts, &mut ins, &mut outs);
                    set_in(c2x, c2y, &verts, &mut ins);
                    x = ex;
                    y = ey;
                    last_quad_ctrl = Some((qx, qy));
                }
                last_cubic_ctrl = None;
                i += 1;
            }
            'A' => {
                while peek_num(i, &tokens) {
                    let rx = take_num(&mut i, &tokens, logs, cmd_ch);
                    let ry = take_num(&mut i, &tokens, logs, cmd_ch);
                    let rot = take_num(&mut i, &tokens, logs, cmd_ch);
                    let large_arc = take_num(&mut i, &tokens, logs, cmd_ch) != 0.0;
                    let sweep = take_num(&mut i, &tokens, logs, cmd_ch) != 0.0;
                    let ex = if is_rel { x + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    let ey = if is_rel { y + take_num(&mut i, &tokens, logs, cmd_ch) } else { take_num(&mut i, &tokens, logs, cmd_ch) };
                    emit_arc(
                        x, y, ex, ey, rx, ry, rot, large_arc, sweep,
                        &mut verts, &mut ins, &mut outs,
                    );
                    x = ex;
                    y = ey;
                }
                last_cubic_ctrl = None;
                last_quad_ctrl = None;
                i += 1;
            }
            'Z' => {
                x = start_x;
                y = start_y;
                close_contour(true, &mut verts, &mut ins, &mut outs, &mut contours);
                last_cubic_ctrl = None;
                last_quad_ctrl = None;
                i += 1;
            }
            other => {
                logs.warn(
                    "parse.path",
                    "unknown path command",
                    &[("cmd", other.to_string().into())],
                );
                i += 1;
            }
        }
    }

    if !verts.is_empty() {
        close_contour(false, &mut verts, &mut ins, &mut outs, &mut contours);
    }
    contours
}

/// Converts one SVG elliptical arc segment into cubic-bezier segments.
/// Follows W3C SVG 1.1 Appendix F.6.
#[allow(clippy::too_many_arguments)]
fn emit_arc(
    x1: f64, y1: f64, x2: f64, y2: f64,
    rx_in: f64, ry_in: f64, rot_deg: f64,
    large_arc: bool, sweep: bool,
    verts: &mut Vec<[f64; 2]>,
    ins: &mut Vec<[f64; 2]>,
    outs: &mut Vec<[f64; 2]>,
) {
    if x1 == x2 && y1 == y2 {
        return;
    }
    let mut rx = rx_in.abs();
    let mut ry = ry_in.abs();
    if rx == 0.0 || ry == 0.0 {
        verts.push([x2, y2]);
        ins.push([0.0, 0.0]);
        outs.push([0.0, 0.0]);
        return;
    }
    let phi = rot_deg.to_radians();
    let cos_phi = phi.cos();
    let sin_phi = phi.sin();

    let dx = (x1 - x2) / 2.0;
    let dy = (y1 - y2) / 2.0;
    let x1p = cos_phi * dx + sin_phi * dy;
    let y1p = -sin_phi * dx + cos_phi * dy;

    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if lambda > 1.0 {
        let s = lambda.sqrt();
        rx *= s;
        ry *= s;
    }

    let rx2 = rx * rx;
    let ry2 = ry * ry;
    let x1p2 = x1p * x1p;
    let y1p2 = y1p * y1p;
    let denom = rx2 * y1p2 + ry2 * x1p2;
    let numer = rx2 * ry2 - denom;
    let factor = (numer / denom).max(0.0).sqrt();
    let sign = if large_arc == sweep { -1.0 } else { 1.0 };
    let cxp = sign * factor * (rx * y1p / ry);
    let cyp = sign * factor * (-ry * x1p / rx);

    let cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2.0;
    let cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2.0;

    fn angle(ux: f64, uy: f64, vx: f64, vy: f64) -> f64 {
        let dot = ux * vx + uy * vy;
        let len = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).sqrt();
        let c = (dot / len).clamp(-1.0, 1.0);
        let sgn = if ux * vy - uy * vx < 0.0 { -1.0 } else { 1.0 };
        sgn * c.acos()
    }

    let ux = (x1p - cxp) / rx;
    let uy = (y1p - cyp) / ry;
    let vx = (-x1p - cxp) / rx;
    let vy = (-y1p - cyp) / ry;
    let theta1 = angle(1.0, 0.0, ux, uy);
    let mut delta = angle(ux, uy, vx, vy);
    if !sweep && delta > 0.0 {
        delta -= 2.0 * std::f64::consts::PI;
    }
    if sweep && delta < 0.0 {
        delta += 2.0 * std::f64::consts::PI;
    }

    let seg_count = (delta.abs() / (std::f64::consts::FRAC_PI_2)).ceil().max(1.0) as i32;
    let seg_angle = delta / seg_count as f64;
    let t = 4.0 / 3.0 * (seg_angle / 4.0).tan();

    for k in 0..seg_count {
        let a1 = theta1 + (k as f64) * seg_angle;
        let a2 = a1 + seg_angle;
        let (cos_a1, sin_a1) = (a1.cos(), a1.sin());
        let (cos_a2, sin_a2) = (a2.cos(), a2.sin());

        let p1x = cos_a1 - t * sin_a1;
        let p1y = sin_a1 + t * cos_a1;
        let p2x = cos_a2 + t * sin_a2;
        let p2y = sin_a2 - t * cos_a2;
        let p3x = cos_a2;
        let p3y = sin_a2;

        let project = |ex: f64, ey: f64| -> [f64; 2] {
            let sx = ex * rx;
            let sy = ey * ry;
            [cos_phi * sx - sin_phi * sy + cx, sin_phi * sx + cos_phi * sy + cy]
        };

        let c1 = project(p1x, p1y);
        let c2 = project(p2x, p2y);
        let p3 = project(p3x, p3y);

        // set_out on current last vertex
        if let Some(v) = verts.last().copied() {
            *outs.last_mut().unwrap() = [c1[0] - v[0], c1[1] - v[1]];
        }
        verts.push([p3[0], p3[1]]);
        ins.push([c2[0] - p3[0], c2[1] - p3[1]]);
        outs.push([0.0, 0.0]);
    }
}

/// Circle/ellipse → 4 cubic segments. Magic `k = 4/3 * tan(π/8)`.
pub fn ellipse_contour(cx: f64, cy: f64, rx: f64, ry: f64) -> CubicContour {
    const K: f64 = 0.5522847498307936;
    let vertices = vec![
        [cx, cy - ry],
        [cx + rx, cy],
        [cx, cy + ry],
        [cx - rx, cy],
    ];
    let out_t = vec![
        [rx * K, 0.0],
        [0.0, ry * K],
        [-rx * K, 0.0],
        [0.0, -ry * K],
    ];
    let in_t = vec![
        [-rx * K, 0.0],
        [0.0, -ry * K],
        [rx * K, 0.0],
        [0.0, ry * K],
    ];
    CubicContour {
        vertices,
        in_tangents: in_t,
        out_tangents: out_t,
        closed: true,
    }
}

/// Rectangle with optional rounded corners.
pub fn rect_contour(x: f64, y: f64, w: f64, h: f64, rx_in: f64, ry_in: f64) -> CubicContour {
    if rx_in <= 0.0 && ry_in <= 0.0 {
        return CubicContour {
            vertices: vec![[x, y], [x + w, y], [x + w, y + h], [x, y + h]],
            in_tangents: vec![[0.0, 0.0]; 4],
            out_tangents: vec![[0.0, 0.0]; 4],
            closed: true,
        };
    }
    let rx = rx_in.min(w / 2.0);
    let ry = ry_in.min(h / 2.0);
    const K: f64 = 0.5522847498307936;
    let vertices = vec![
        [x + rx, y],
        [x + w - rx, y],
        [x + w, y + ry],
        [x + w, y + h - ry],
        [x + w - rx, y + h],
        [x + rx, y + h],
        [x, y + h - ry],
        [x, y + ry],
    ];
    let in_t = vec![
        [0.0, 0.0],
        [0.0, 0.0],
        [0.0, -ry * K],
        [0.0, 0.0],
        [rx * K, 0.0],
        [0.0, 0.0],
        [0.0, ry * K],
        [0.0, 0.0],
    ];
    let out_t = vec![
        [0.0, 0.0],
        [rx * K, 0.0],
        [0.0, 0.0],
        [0.0, ry * K],
        [0.0, 0.0],
        [-rx * K, 0.0],
        [0.0, 0.0],
        [0.0, -ry * K],
    ];
    CubicContour {
        vertices,
        in_tangents: in_t,
        out_tangents: out_t,
        closed: true,
    }
}

/// Polyline/polygon → contour with zero tangents.
pub fn poly_contour(points: Vec<[f64; 2]>, closed: bool) -> CubicContour {
    let n = points.len();
    CubicContour {
        vertices: points,
        in_tangents: vec![[0.0, 0.0]; n],
        out_tangents: vec![[0.0, 0.0]; n],
        closed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::LogLevel;

    fn p(d: &str) -> Vec<CubicContour> {
        let mut logs = LogCollector::new(LogLevel::Warn);
        parse(d, true, &mut logs)
    }

    #[test]
    fn empty_input_returns_empty() {
        assert!(p("").is_empty());
    }

    #[test]
    fn move_line_close_produces_one_closed_contour() {
        let c = p("M0 0 L10 0 L10 10 L0 10 Z");
        assert_eq!(c.len(), 1);
        assert!(c[0].closed);
        assert_eq!(c[0].vertices.len(), 4);
        assert_eq!(c[0].vertices[0], [0.0, 0.0]);
        assert_eq!(c[0].vertices[1], [10.0, 0.0]);
    }

    #[test]
    fn relative_move_line() {
        let c = p("m10 10 l5 0 l0 5 z");
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].vertices[0], [10.0, 10.0]);
        assert_eq!(c[0].vertices[1], [15.0, 10.0]);
        assert_eq!(c[0].vertices[2], [15.0, 15.0]);
    }

    #[test]
    fn horizontal_vertical_lines() {
        let c = p("M0 0 H10 V10");
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].vertices.len(), 3);
        assert_eq!(c[0].vertices[1], [10.0, 0.0]);
        assert_eq!(c[0].vertices[2], [10.0, 10.0]);
    }

    #[test]
    fn cubic_sets_tangents() {
        let c = p("M0 0 C10 0 10 10 0 10");
        assert_eq!(c[0].vertices.len(), 2);
        // out-tangent of first vertex = (10,0) - (0,0) = (10, 0)
        assert_eq!(c[0].out_tangents[0], [10.0, 0.0]);
        // in-tangent of second vertex = (10,10) - (0,10) = (10, 0)
        assert_eq!(c[0].in_tangents[1], [10.0, 0.0]);
    }

    #[test]
    fn quadratic_converts_to_cubic() {
        let c = p("M0 0 Q5 10 10 0");
        assert_eq!(c[0].vertices.len(), 2);
        // c1 = p0 + 2/3*(q-p0) = (0,0)+2/3*(5,10)-(0,0) = (3.333, 6.667)
        let out = c[0].out_tangents[0];
        assert!((out[0] - 10.0 / 3.0).abs() < 1e-6);
        assert!((out[1] - 20.0 / 3.0).abs() < 1e-6);
    }

    #[test]
    fn smooth_cubic_reflects_previous_control() {
        let c = p("M0 0 C10 0 10 10 0 10 S-10 20 0 20");
        assert_eq!(c[0].vertices.len(), 3);
        // reflected rx = 2*0-10 = -10, ry = 2*10-10 = 10
        // out-tangent of second vertex = (-10,10) - (0,10) = (-10, 0)
        assert_eq!(c[0].out_tangents[1], [-10.0, 0.0]);
    }

    #[test]
    fn closing_duplicate_trimmed_when_requested() {
        let c = p("M0 0 L10 0 L0 0 Z");
        // three verts ending at start → trimmed to 2
        assert_eq!(c[0].vertices.len(), 2);
    }

    #[test]
    fn closing_duplicate_kept_when_disabled() {
        let mut logs = LogCollector::new(LogLevel::Warn);
        let c = parse("M0 0 L10 0 L0 0 Z", false, &mut logs);
        assert_eq!(c[0].vertices.len(), 3);
    }

    #[test]
    fn implicit_lineto_after_move() {
        let c = p("M0 0 10 0 10 10");
        assert_eq!(c[0].vertices.len(), 3);
        assert_eq!(c[0].vertices[1], [10.0, 0.0]);
        assert_eq!(c[0].vertices[2], [10.0, 10.0]);
    }

    #[test]
    fn compact_number_parsing() {
        // `M0 0L.5-.5` = M(0,0) L(0.5, -0.5)
        let c = p("M0 0L.5-.5");
        assert_eq!(c[0].vertices[1], [0.5, -0.5]);
    }

    #[test]
    fn multiple_subpaths() {
        let c = p("M0 0 L10 0 M20 0 L30 0");
        assert_eq!(c.len(), 2);
    }

    #[test]
    fn ellipse_contour_has_four_vertices() {
        let c = ellipse_contour(50.0, 50.0, 10.0, 20.0);
        assert_eq!(c.vertices.len(), 4);
        assert!(c.closed);
        assert_eq!(c.vertices[0], [50.0, 30.0]);
    }

    #[test]
    fn rect_contour_without_radius_has_four_corners() {
        let c = rect_contour(0.0, 0.0, 10.0, 20.0, 0.0, 0.0);
        assert_eq!(c.vertices.len(), 4);
        assert!(c.closed);
    }

    #[test]
    fn rect_contour_rounded_has_eight_corners() {
        let c = rect_contour(0.0, 0.0, 10.0, 20.0, 2.0, 2.0);
        assert_eq!(c.vertices.len(), 8);
    }

    #[test]
    fn poly_contour_zero_tangents() {
        let c = poly_contour(vec![[0.0, 0.0], [10.0, 0.0], [5.0, 10.0]], true);
        assert_eq!(c.vertices.len(), 3);
        assert!(c.closed);
        assert!(c.in_tangents.iter().all(|t| *t == [0.0, 0.0]));
    }
}

#[cfg(test)]
mod u41_top_ellipse_test {
    use super::*;
    use crate::log::LogLevel;

    #[test]
    fn anim5_top_ellipse_is_smooth_curve_no_straight_segment() {
        let d = "M654.14,606.8c32.29,18.77,32.12,49.2-.39,68s-85,18.77-117.34,0-32.13-49.2.38-68s85.05-18.8,117.35,0Z";
        let mut logs = LogCollector::new(LogLevel::Trace);
        let contours = parse(d, true, &mut logs);
        assert_eq!(contours.len(), 1, "one closed contour");
        let c = &contours[0];
        eprintln!("verts={} closed={}", c.vertices.len(), c.closed);
        for (i, v) in c.vertices.iter().enumerate() {
            eprintln!(
                "V{} pos=({:.2}, {:.2}) in=({:.2}, {:.2}) out=({:.2}, {:.2})",
                i, v[0], v[1],
                c.in_tangents[i][0], c.in_tangents[i][1],
                c.out_tangents[i][0], c.out_tangents[i][1]
            );
        }
        let mut zero_tangent_count = 0;
        for i in 0..c.vertices.len() {
            let in_zero = c.in_tangents[i][0].abs() < 1e-6 && c.in_tangents[i][1].abs() < 1e-6;
            let out_zero = c.out_tangents[i][0].abs() < 1e-6 && c.out_tangents[i][1].abs() < 1e-6;
            if in_zero && out_zero {
                zero_tangent_count += 1;
            }
        }
        assert_eq!(
            zero_tangent_count, 0,
            "every vertex should have at least one non-zero tangent for a smooth ellipse-like curve",
        );
    }
}
