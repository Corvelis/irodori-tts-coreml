#!/usr/bin/env ruby
require 'xcodeproj'
require 'pathname'
root = Pathname.new(__dir__).parent
path = root.join('Examples/IrodoriSamples.xcodeproj')
abort 'Project already exists; remove only the generated project before regenerating.' if path.exist?
project = Xcodeproj::Project.new(path.to_s)
group = project.main_group.new_group('Shared', 'Shared')
refs = root.join('Examples/Shared').glob('*.swift').sort.map { |file| group.new_file(file.basename.to_s) }
assets = group.new_file('Assets.xcassets')
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '..'
project.root_object.package_references << package
[['IrodoriiOS', :ios, '17.0'], ['IrodoriMac', :osx, '14.0']].each do |name, platform, deployment|
  target = project.new_target(:application, name, platform, deployment)
  target.add_file_references(refs)
  target.resources_build_phase.add_file_reference(assets, true)
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package
  product.product_name = 'IrodoriTTS'
  target.package_product_dependencies << product
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = product
  target.frameworks_build_phase.files << build
  target.build_configurations.each do |config|
    s = config.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER'] = "org.example.irodori.coreml.#{platform}"
    s['SWIFT_VERSION'] = '5.0'
    s['ASSETCATALOG_COMPILER_APPICON_NAME'] = platform == :ios ? 'AppIcon-iOS' : 'AppIcon-macOS'
    s['GENERATE_INFOPLIST_FILE'] = 'YES'
    s['INFOPLIST_KEY_NSMicrophoneUsageDescription'] = '参照音声として自分の声を録音します。'
    s['INFOPLIST_KEY_CFBundleDisplayName'] = 'Irodori Core ML'
    s['CODE_SIGN_STYLE'] = 'Automatic'
    s['MARKETING_VERSION'] = '0.1.0'
    s['CURRENT_PROJECT_VERSION'] = '1'
    if platform == :ios
      s['TARGETED_DEVICE_FAMILY'] = '1,2'
      s['INFOPLIST_FILE'] = 'iOS/Info.plist'
      s['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
      s['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
    else
      s['CODE_SIGN_ENTITLEMENTS'] = 'macOS/IrodoriMac.entitlements'
      s['ENABLE_HARDENED_RUNTIME'] = 'YES'
    end
  end
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.set_launch_target(target)
  scheme.save_as(path, name, true)
end
project.save
puts path
