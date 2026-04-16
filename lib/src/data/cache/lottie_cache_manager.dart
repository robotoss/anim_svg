import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Disk cache for converted Lottie JSON keyed by source SVG URL.
///
/// Bumping `_storeKey` invalidates every previously cached entry — use
/// when the conversion output format changes incompatibly.
class LottieCacheManager extends CacheManager {
  LottieCacheManager._()
      : super(Config(
          _storeKey,
          stalePeriod: const Duration(days: 7),
          maxNrOfCacheObjects: 200,
          fileService: HttpFileService(),
        ));

  static const _storeKey = 'anim_svg_lottie_v2';

  static final LottieCacheManager instance = LottieCacheManager._();
}
