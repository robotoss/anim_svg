import '../../core/errors.dart';
import '../../domain/entities/lottie_animation.dart';
import '../../domain/entities/svg_document.dart';
import '../parsers/data_uri_decoder.dart';
import 'raster_transcoder.dart';

/// Builds a Lottie asset (image) from an [SvgImage]. Validates the data URI
/// and transcodes WebP → PNG so thorvg (which lacks a WebP loader) can render
/// it. Other MIME types pass through untouched.
class ImageAssetBuilder {
  ImageAssetBuilder({
    DataUriDecoder? decoder,
    RasterTranscoder? transcoder,
  })  : _decoder = decoder ?? const DataUriDecoder(),
        _transcoder = transcoder ?? const RasterTranscoder();

  final DataUriDecoder _decoder;
  final RasterTranscoder _transcoder;

  LottieAsset build(SvgImage image, {required String assetId}) {
    if (!image.href.startsWith('data:')) {
      throw UnsupportedFeatureException(
        'image[external]',
        'external image href not supported in MVP: ${image.href}',
      );
    }
    final parsed = _decoder.parse(image.href);
    final ready = _transcoder.transcodeIfNeeded(parsed);
    return LottieAsset(
      id: assetId,
      width: image.width,
      height: image.height,
      dataUri: ready.asDataUri(),
    );
  }
}
