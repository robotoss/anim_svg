Pod::Spec.new do |s|
  s.name             = 'thorvg_plus'
  s.version          = '1.1.0'
  s.summary          = 'Source-built fork of thorvg for Flutter with full iOS simulator support.'
  s.description      = <<-DESC
    thorvg_plus is a source-built fork of the ThorVG Flutter runtime,
    published to work around upstream thorvg.flutter#22 (iOS simulator
    linker failure). Compiled from source via CocoaPods; includes the
    sw engine and the lottie/png/jpg/raw loaders.
  DESC
  s.homepage         = 'https://github.com/robotoss/anim_svg/tree/master/thorvg.flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Yeftifeyev Konstantin' => 'zoxo@outlook.com' }
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform         = :ios, '11.0'
  s.swift_version    = '5.0'

  # CocoaPods source_files globs do not follow symlinks nor `..` paths.
  # Materialize hard-link mirrors of the wrapper sources and the thorvg
  # engine into this directory before pod install evaluates source_files.
  s.prepare_command = <<-CMD
    rm -rf plugin_src thorvg_ext
    cp -Rl ../src plugin_src
    cp -Rl ../thorvg thorvg_ext
  CMD

  s.source_files = [
    'Classes/**/*.{m,mm,h,swift}',
    'config.h',
    'plugin_src/*.{cpp,h}',
    'thorvg_ext/inc/thorvg.h',
    'thorvg_ext/src/common/*.{cpp,h}',
    'thorvg_ext/src/renderer/*.{cpp,h}',
    'thorvg_ext/src/renderer/sw_engine/*.{cpp,h}',
    'thorvg_ext/src/renderer/gl_engine/*.{cpp,h}',
    'thorvg_ext/src/loaders/lottie/tvgLottie*.{cpp,h}',
    'thorvg_ext/src/loaders/png/*.{cpp,h}',
    'thorvg_ext/src/loaders/jpg/*.{cpp,h}',
    'thorvg_ext/src/loaders/raw/*.{cpp,h}',
  ]

  # Only ThorvgBridge.h is public — the Swift sources in the same pod
  # see the ObjC interface through the auto-generated umbrella header.
  #
  # `thorvg.h` is intentionally NOT public: it is a C++ header that
  # `#include`s `<cstdint>` / `<functional>` / `<list>`, and CocoaPods'
  # auto-generated umbrella is parsed in Objective-C context when Swift
  # builds the module — the C++ standard headers fail to resolve and
  # the build dies with `'cstdint' file not found`. The pod's own C++
  # sources (`plugin_src/*.cpp`, `tvgFlutterLottieAnimation.cpp`) reach
  # `thorvg.h` via the project's HEADER_SEARCH_PATHS, not via the
  # public-headers path, so dropping it from this list breaks nothing
  # internally.
  s.public_header_files = [
    'Classes/ThorvgBridge.h',
  ]
  s.libraries = ['c++', 'z']

  # System frameworks:
  # - Accelerate: vImagePermuteChannels_ARGB8888 in ThorvgBridge.mm,
  #   used by the SW path; sprint 6 drops it once the GL path is
  #   wired and the swizzle moves into the IOSurface BGRA_EXT binding.
  # - CoreVideo + IOSurface: required by AngleRenderContext.mm
  #   (CVPixelBufferGetIOSurface, EGL_IOSURFACE_ANGLE).
  # - Metal + QuartzCore: ANGLE's Metal backend pulls these for
  #   MTLDevice / MTLCommandQueue / IOSurface-Metal interop.
  s.frameworks = ['Accelerate', 'CoreVideo', 'IOSurface', 'Metal', 'QuartzCore']

  # Prebuilt ANGLE binaries (Metal backend, GLES 2/3 + EGL 1.4),
  # extracted from Knightro63/flutter_angle (MIT — see
  # Frameworks/FLUTTER_ANGLE_LICENSE). Vendored as xcframeworks so
  # Xcode picks the correct slice per build target (ios-arm64,
  # ios-arm64_x86_64-simulator, macos-arm64_x86_64). Sprint 5 wires
  # AngleRenderContext.mm against eglGetPlatformDisplayEXT +
  # eglCreatePbufferFromClientBuffer; sprint 6 routes thorvg's
  # GlCanvas through the resulting context.
  s.vendored_frameworks = [
    'Frameworks/libEGL.xcframework',
    'Frameworks/libGLESv2.xcframework',
  ]

  s.pod_target_xcconfig = {
    'DEFINES_MODULE'                       => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD'          => 'gnu++14',
    'CLANG_CXX_LIBRARY'                    => 'libc++',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'GCC_PREPROCESSOR_DEFINITIONS'         => '$(inherited) TVG_STATIC=1',
    'OTHER_CPLUSPLUSFLAGS'                 => '$(inherited) -fno-exceptions -fno-rtti -fno-math-errno -fvisibility=hidden -fvisibility-inlines-hidden -w',
    'HEADER_SEARCH_PATHS'                  => [
      '$(inherited)',
      '"${PODS_TARGET_SRCROOT}"',
      '"${PODS_TARGET_SRCROOT}/Classes"',
      '"${PODS_TARGET_SRCROOT}/plugin_src"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/inc"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/common"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/renderer"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/renderer/sw_engine"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/renderer/gl_engine"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/loaders/lottie"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/loaders/png"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/loaders/jpg"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/loaders/raw"',
    ].join(' '),
  }
end
