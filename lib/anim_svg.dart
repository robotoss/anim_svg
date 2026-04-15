/// Public API of the `anim_svg` Flutter package.
///
/// See `brain/` for architecture docs, feature map and sprint plan.
library;

export 'src/core/errors.dart';
export 'src/core/logger.dart';
export 'src/core/result.dart';

export 'src/domain/entities/lottie_animation.dart';
export 'src/domain/entities/svg_animation.dart';
export 'src/domain/entities/svg_document.dart';
export 'src/domain/entities/svg_motion_path.dart';
export 'src/domain/entities/svg_transform.dart';

export 'src/domain/usecases/convert_svg_to_lottie.dart';

export 'src/data/parsers/data_uri_decoder.dart';
export 'src/data/parsers/svg_animation_parser.dart';
export 'src/data/parsers/svg_css_parser.dart';
export 'src/data/parsers/svg_parser.dart';
export 'src/data/parsers/svg_path_data_parser.dart';
export 'src/data/parsers/svg_svgator_parser.dart';
export 'src/data/parsers/svg_transform_parser.dart';

export 'src/data/mappers/display_mapper.dart';
export 'src/data/mappers/image_asset_builder.dart';
export 'src/data/mappers/keyspline_mapper.dart';
export 'src/data/mappers/opacity_mapper.dart';
export 'src/data/mappers/opacity_merge.dart';
export 'src/data/mappers/shape_mapper.dart';
export 'src/data/mappers/svg_to_lottie_mapper.dart';
export 'src/data/mappers/transform_mapper.dart';
export 'src/data/mappers/use_flattener.dart';

export 'src/data/serializers/lottie_serializer.dart';

export 'src/presentation/anim_svg_widget.dart';
export 'src/presentation/anim_svg_controller.dart';
