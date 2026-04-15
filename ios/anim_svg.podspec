#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint anim_svg.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'anim_svg'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter project.'
  s.description      = <<-DESC
A new Flutter project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'zoxo@outlook.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Build the Rust core (anim_svg_core.xcframework) before `pod install`
  # consumes the vendored framework. Safe to re-run: the script is a no-op
  # when the xcframework already exists (set FORCE_RUST_REBUILD=1 to force).
  s.prepare_command = <<-CMD
    set -e
    cd "$PODS_TARGET_SRCROOT/.."
    ./tool/prepare_rust.sh ios
  CMD

  s.vendored_frameworks = 'Frameworks/anim_svg_core.xcframework'
  s.preserve_paths = 'Frameworks/anim_svg_core.xcframework'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Dart FFI uses DynamicLibrary.process() on iOS, which requires the
    # Rust symbols to survive dead-stripping. AnimSvgKeepAlive.c holds a
    # live reference so the linker keeps the static lib.
    'DEAD_CODE_STRIPPING' => 'NO',
  }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'anim_svg_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
