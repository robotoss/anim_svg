package com.zharume.anim_svg

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Registration stub for `anim_svg`. All Dart-native communication goes
 * through `dart:ffi` into `libanim_svg_core.so`, so this class exists only
 * to satisfy the `pluginClass` declaration in pubspec.yaml and, critically,
 * to force-load the Rust core before any Dart FFI call runs.
 *
 * The `System.loadLibrary` call in the companion init resolves
 * `libanim_svg_core.so` at plugin-class load time (i.e. before
 * `DynamicLibrary.open("libanim_svg_core.so")` on the Dart side), so a
 * missing or mis-packaged native binary surfaces as an early, clear
 * `UnsatisfiedLinkError` rather than an opaque FFI failure later.
 */
class AnimSvgPlugin : FlutterPlugin {
    companion object {
        init {
            System.loadLibrary("anim_svg_core")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
