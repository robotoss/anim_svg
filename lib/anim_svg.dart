/// Public API of the `anim_svg` Flutter package.
///
/// See `brain/` for architecture docs, feature map and sprint plan.
library;

export 'src/core/errors.dart';
export 'src/core/logger.dart';
export 'src/core/result.dart';

export 'src/domain/usecases/convert_svg_to_lottie.dart';

export 'src/data/ffi/rust_convert_envelope.dart';
export 'src/data/ffi/rust_converter.dart';

export 'src/presentation/anim_svg_widget.dart';
export 'src/presentation/anim_svg_controller.dart';
