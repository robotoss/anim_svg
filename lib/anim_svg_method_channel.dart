import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'anim_svg_platform_interface.dart';

/// An implementation of [AnimSvgPlatform] that uses method channels.
class MethodChannelAnimSvg extends AnimSvgPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('anim_svg');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
