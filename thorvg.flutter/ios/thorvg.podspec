Pod::Spec.new do |s|
  s.name             = 'thorvg'
  s.version          = '1.0.0-src'
  s.summary          = 'ThorVG for Flutter (direct source build)'
  s.description      = <<-DESC
    ThorVG Flutter Runtime compiled from source via CocoaPods.
    Includes sw engine and lottie/png/jpg/raw loaders.
  DESC
  s.homepage         = 'https://github.com/thorvg/thorvg.flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Jinny You' => 'jinny@lottiefiles.com' }
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
    'Classes/**/*.{m,h}',
    'config.h',
    'plugin_src/*.{cpp,h}',
    'thorvg_ext/inc/thorvg.h',
    'thorvg_ext/src/common/*.{cpp,h}',
    'thorvg_ext/src/renderer/*.{cpp,h}',
    'thorvg_ext/src/renderer/sw_engine/*.{cpp,h}',
    'thorvg_ext/src/loaders/lottie/tvgLottie*.{cpp,h}',
    'thorvg_ext/src/loaders/png/*.{cpp,h}',
    'thorvg_ext/src/loaders/jpg/*.{cpp,h}',
    'thorvg_ext/src/loaders/raw/*.{cpp,h}',
  ]

  s.public_header_files = 'thorvg_ext/inc/thorvg.h'
  s.libraries = ['c++', 'z']

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
      '"${PODS_TARGET_SRCROOT}/plugin_src"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/inc"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/common"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/renderer"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/renderer/sw_engine"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/loaders/lottie"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/loaders/png"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/loaders/jpg"',
      '"${PODS_TARGET_SRCROOT}/thorvg_ext/src/loaders/raw"',
    ].join(' '),
  }
end
