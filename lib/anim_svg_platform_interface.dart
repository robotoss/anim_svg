import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'anim_svg_method_channel.dart';

abstract class AnimSvgPlatform extends PlatformInterface {
  /// Constructs a AnimSvgPlatform.
  AnimSvgPlatform() : super(token: _token);

  static final Object _token = Object();

  static AnimSvgPlatform _instance = MethodChannelAnimSvg();

  /// The default instance of [AnimSvgPlatform] to use.
  ///
  /// Defaults to [MethodChannelAnimSvg].
  static AnimSvgPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AnimSvgPlatform] when
  /// they register themselves.
  static set instance(AnimSvgPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
