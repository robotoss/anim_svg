//! Port of `lib/src/data/mappers/nested_animation_classifier.dart`.
//!
//! Decides how to express a nested chain of animated `<g>` groups in Lottie.
//!
//! Two strategies:
//!
//! - **Parenting** (preferred): each ancestor becomes its own Lottie null
//!   layer (`ty:3`) carrying its animateTransforms; the child layer
//!   references it via the Lottie `parent` field. Preconditions:
//!     - Equal `durSeconds` and `repeatIndefinite` flags across the whole
//!       chain (Lottie layers share the top-level `outPoint`).
//!     - Chain depth ≤ `max_depth`.
//!
//! - **Bake** (fallback): collapse the chain into per-frame samples on the
//!   leaf. Supported today only for a single animated ancestor.

use crate::domain::SvgAnimationNode;

/// Default max chain depth. thorvg's Lottie renderer starts degrading past
/// ~8 parents; we leave headroom for the leaf and an outer static-transform
/// carrier.
pub const DEFAULT_MAX_DEPTH: usize = 6;

/// Tolerance for comparing `durSeconds` across ancestors. AE/Figma exports
/// sometimes round to 3 decimal places.
pub const DEFAULT_DUR_EPSILON: f64 = 1e-3;

/// Minimal snapshot of an animated group needed by the classifier. Mirrors
/// the Dart `ChainEntry`. `transform_anims` is kept (parity with Dart),
/// even though `can_chain_parent` itself only needs the timing fields.
#[derive(Debug, Clone)]
pub struct ChainEntry {
    pub dur_seconds: f64,
    pub repeat_indefinite: bool,
    pub transform_anims: Vec<SvgAnimationNode>,
}

/// Classifier configuration.
#[derive(Debug, Clone, Copy)]
pub struct NestedAnimationClassifier {
    pub max_depth: usize,
    pub dur_epsilon: f64,
}

impl Default for NestedAnimationClassifier {
    fn default() -> Self {
        Self {
            max_depth: DEFAULT_MAX_DEPTH,
            dur_epsilon: DEFAULT_DUR_EPSILON,
        }
    }
}

impl NestedAnimationClassifier {
    pub const fn new(max_depth: usize, dur_epsilon: f64) -> Self {
        Self {
            max_depth,
            dur_epsilon,
        }
    }

    /// Returns `true` when the given chain of groups (root→leaf order) can
    /// be expressed as a Lottie parenting chain: all entries animate with
    /// the same `dur_seconds` and matching `repeat_indefinite`.
    pub fn can_chain_parent(&self, chain: &[ChainEntry]) -> bool {
        if chain.is_empty() {
            return false;
        }
        if chain.len() > self.max_depth {
            return false;
        }
        let dur = chain[0].dur_seconds;
        let loop_ = chain[0].repeat_indefinite;
        for e in chain {
            if (e.dur_seconds - dur).abs() > self.dur_epsilon {
                return false;
            }
            if e.repeat_indefinite != loop_ {
                return false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(dur: f64, repeat: bool) -> ChainEntry {
        ChainEntry {
            dur_seconds: dur,
            repeat_indefinite: repeat,
            transform_anims: Vec::new(),
        }
    }

    #[test]
    fn empty_chain_returns_false() {
        let c = NestedAnimationClassifier::default();
        assert!(!c.can_chain_parent(&[]));
    }

    #[test]
    fn matching_dur_and_repeat_returns_true() {
        let c = NestedAnimationClassifier::default();
        let chain = vec![entry(2.0, false), entry(2.0, false), entry(2.0, false)];
        assert!(c.can_chain_parent(&chain));
    }

    #[test]
    fn mismatched_dur_returns_false() {
        let c = NestedAnimationClassifier::default();
        let chain = vec![entry(2.0, false), entry(3.0, false)];
        assert!(!c.can_chain_parent(&chain));
    }

    #[test]
    fn mismatched_repeat_returns_false() {
        let c = NestedAnimationClassifier::default();
        let chain = vec![entry(1.0, true), entry(1.0, false)];
        assert!(!c.can_chain_parent(&chain));
    }

    #[test]
    fn chain_deeper_than_max_depth_returns_false() {
        let c = NestedAnimationClassifier::new(2, DEFAULT_DUR_EPSILON);
        let chain = vec![entry(1.0, false), entry(1.0, false), entry(1.0, false)];
        assert!(!c.can_chain_parent(&chain));
    }

    #[test]
    fn durations_within_epsilon_are_accepted() {
        let c = NestedAnimationClassifier::default();
        let chain = vec![entry(2.000, false), entry(2.0005, false)];
        assert!(c.can_chain_parent(&chain));
    }

    #[test]
    fn durations_outside_epsilon_are_rejected() {
        let c = NestedAnimationClassifier::new(6, 1e-6);
        let chain = vec![entry(2.000, false), entry(2.001, false)];
        assert!(!c.can_chain_parent(&chain));
    }
}
