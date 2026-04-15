import 'package:flutter/foundation.dart';

/// Play/pause/seek controls for [AnimSvgView].
///
/// The controller decouples the widget's internal Thorvg renderer from user
/// code: callers only talk to the controller, the widget wires up callbacks.
class AnimSvgController extends ChangeNotifier {
  _AnimSvgBinding? _binding;

  void _attach(_AnimSvgBinding binding) {
    _binding = binding;
  }

  void _detach(_AnimSvgBinding binding) {
    if (identical(_binding, binding)) _binding = null;
  }

  void play() => _binding?.play();

  void pause() => _binding?.pause();

  /// Seeks to a normalized time in [0..1].
  void seek(double progress) => _binding?.seek(progress.clamp(0, 1));
}

abstract class _AnimSvgBinding {
  void play();
  void pause();
  void seek(double progress);
}

/// Internal visibility: [AnimSvgView]'s State uses these to talk to controller.
@protected
abstract class AnimSvgBinding implements _AnimSvgBinding {}

/// Internal glue — kept visible for the widget layer only.
extension AnimSvgControllerInternal on AnimSvgController {
  void attachInternal(AnimSvgBinding b) => _attach(b);
  void detachInternal(AnimSvgBinding b) => _detach(b);
}
