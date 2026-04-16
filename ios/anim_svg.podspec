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
  #
  # prepare_command runs with cwd = the podspec directory (this `ios/`
  # folder). Its parent is the plugin root where `tool/` lives.
  s.prepare_command = <<-CMD
    set -e
    cd ..
    ./tool/prepare_rust.sh ios
  CMD

  s.vendored_frameworks = 'Frameworks/anim_svg_core.xcframework'
  s.preserve_paths = 'Frameworks/anim_svg_core.xcframework'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Dart FFI uses DynamicLibrary.process() on iOS, which requires the
    # Rust symbols to survive dead-stripping. AnimSvgFFIKeep.m holds a
    # live reference to every exported symbol so the linker pulls each
    # containing object file from the static archive.
    'DEAD_CODE_STRIPPING' => 'NO',
    # The xcframework places the C header under <slice>/Headers/ — add
    # both slices so AnimSvgFFIKeep.m can `#import "anim_svg_core.h"`.
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Frameworks/anim_svg_core.xcframework/ios-arm64/Headers" "${PODS_TARGET_SRCROOT}/Frameworks/anim_svg_core.xcframework/ios-arm64_x86_64-simulator/Headers"',
  }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'anim_svg_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
