#!/usr/bin/env ruby
# scaffold_ios_extension.rb
#
# Run this from your Flutter project root (the folder that contains `ios/`).
# It edits ios/Runner.xcodeproj/project.pbxproj as pure data — no Xcode needed.
#
# What it does:
#   1. Sets the real bundle ID (com.vulcainvpn.app) on the Runner + RunnerTests targets
#   2. Creates a new "PacketTunnel" Network Extension target
#   3. Wires up an App Group so the main app and the extension can share data
#      (VPN credentials, connection state) via UserDefaults(suiteName:)
#   4. Adds NetworkExtension.framework to the extension target
#   5. Embeds the extension into the main app (Copy Files build phase)
#   6. Writes entitlements files for both targets
#   7. Writes a PacketTunnel Info.plist declaring the packet-tunnel-provider extension point
#   8. Adds a starter PacketTunnelProvider.swift you'll fill in with sing-box calls
#
# Prereqs:
#   gem install xcodeproj
#
# Usage:
#   ruby scaffold_ios_extension.rb

require 'xcodeproj'
require 'fileutils'

# ─── CONFIG ──────────────────────────────────────────────────────────────
BUNDLE_ID          = 'com.vulcainvpn.app'
EXTENSION_BUNDLE_ID = "#{BUNDLE_ID}.PacketTunnel"
APP_GROUP           = "group.#{BUNDLE_ID}"
EXTENSION_NAME       = 'PacketTunnel'
PROJECT_PATH         = 'ios/Runner.xcodeproj'
IOS_DEPLOYMENT_TARGET = '13.0'
# ─────────────────────────────────────────────────────────────────────────

unless Dir.exist?(PROJECT_PATH)
  abort "❌ Can't find #{PROJECT_PATH}. Run this from your Flutter project root."
end

project = Xcodeproj::Project.open(PROJECT_PATH)

runner_target = project.targets.find { |t| t.name == 'Runner' }
abort '❌ Could not find Runner target' unless runner_target

if project.targets.any? { |t| t.name == EXTENSION_NAME }
  abort "❌ A target named #{EXTENSION_NAME} already exists — script already run? Aborting to avoid duplicating."
end

puts "▶ Setting bundle ID to #{BUNDLE_ID} on all targets..."
project.targets.each do |t|
  t.build_configurations.each do |config|
    if t.name == 'RunnerTests'
      config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_ID}.RunnerTests"
    else
      config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
    end
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_DEPLOYMENT_TARGET
  end
end

# ─── 1. Create the extension group + files on disk ────────────────────────
ext_dir = File.join('ios', EXTENSION_NAME)
FileUtils.mkdir_p(ext_dir)

info_plist_path = File.join(ext_dir, 'Info.plist')
File.write(info_plist_path, <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>PacketTunnel</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$(FLUTTER_BUILD_NAME)</string>
    <key>CFBundleVersion</key>
    <string>$(FLUTTER_BUILD_NUMBER)</string>
    <key>NSExtension</key>
    <dict>
      <key>NSExtensionPointIdentifier</key>
      <string>com.apple.networkextension.packet-tunnel</string>
      <key>NSExtensionPrincipalClass</key>
      <string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
    </dict>
  </dict>
  </plist>
PLIST

entitlements_ext_path = File.join(ext_dir, 'PacketTunnel.entitlements')
File.write(entitlements_ext_path, <<~ENT)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>com.apple.security.application-groups</key>
    <array>
      <string>#{APP_GROUP}</string>
    </array>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
      <string>packet-tunnel-provider</string>
    </array>
  </dict>
  </plist>
ENT

provider_swift_path = File.join(ext_dir, 'PacketTunnelProvider.swift')
File.write(provider_swift_path, <<~SWIFT)
  import NetworkExtension
  import os.log

  // TODO: import your sing-box iOS framework once Phase 1 (gomobile bind) is done, e.g.:
  // import Libbox

  class PacketTunnelProvider: NEPacketTunnelProvider {

      override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
          os_log("PacketTunnelProvider: startTunnel")

          // TODO:
          // 1. Read the sing-box JSON config written by the main app into the
          //    shared App Group container (see APP_GROUP constant), the same
          //    way vpn_config_service.dart builds it for other platforms.
          // 2. Boot sing-box against that config (mirror what libbox.aar does
          //    on Android — BoxService.start() equivalent on iOS is typically
          //    LibboxNewService(...) from the generated framework).
          // 3. Call setTunnelNetworkSettings(...) with the TUN interface
          //    settings sing-box expects, then call completionHandler(nil).

          completionHandler(nil)
      }

      override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
          os_log("PacketTunnelProvider: stopTunnel reason=%{public}@", String(describing: reason))
          // TODO: sing-box service.Close() equivalent
          completionHandler()
      }

      override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
          // Optional: two-way channel for the main app to query live stats
          // (bytes sent/received, current outbound) from the extension.
          completionHandler?(nil)
      }
  }
SWIFT

puts "▶ Wrote #{info_plist_path}, #{entitlements_ext_path}, #{provider_swift_path}"

# ─── 2. Main app entitlements (App Group only — no NE entitlement needed here) ─
runner_entitlements_path = File.join('ios', 'Runner', 'Runner.entitlements')
File.write(runner_entitlements_path, <<~ENT)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>com.apple.security.application-groups</key>
    <array>
      <string>#{APP_GROUP}</string>
    </array>
  </dict>
  </plist>
ENT
puts "▶ Wrote #{runner_entitlements_path}"

# ─── 3. Add extension group + file references to the project ──────────────
main_group = project.main_group
ext_group = main_group.new_group(EXTENSION_NAME, ext_dir)

info_plist_ref  = ext_group.new_reference(info_plist_path)
entitlements_ref = ext_group.new_reference(entitlements_ext_path)
provider_ref     = ext_group.new_reference(provider_swift_path)

runner_group = main_group['Runner']
runner_entitlements_ref = runner_group.new_reference(runner_entitlements_path)

# ─── 4. Create the extension target ────────────────────────────────────────
ext_target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
project.targets << ext_target
ext_target.name = EXTENSION_NAME
ext_target.product_name = EXTENSION_NAME
ext_target.product_type = 'com.apple.product-type.app-extension'

product_ref = project.products_group.new_reference("#{EXTENSION_NAME}.appex")
product_ref.explicit_file_type = 'wrapper.app-extension'
product_ref.include_in_index = '0'
product_ref.source_tree = 'BUILT_PRODUCTS_DIR'
ext_target.product_reference = product_ref

# Build phases
sources_phase = project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
ext_target.build_phases << sources_phase
sources_phase.add_file_reference(provider_ref)

frameworks_phase = project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
ext_target.build_phases << frameworks_phase

resources_phase = project.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
ext_target.build_phases << resources_phase

# Link NetworkExtension.framework
ne_framework = project.frameworks_group.new_reference('System/Library/Frameworks/NetworkExtension.framework')
ne_framework.source_tree = 'SDKROOT'
ne_framework.name = 'NetworkExtension.framework'
build_file = frameworks_phase.add_file_reference(ne_framework)

# Build settings per configuration (Debug/Release), mirrored from Runner's list
runner_config_list = runner_target.build_configuration_list
ext_config_list = project.new(Xcodeproj::Project::Object::XCConfigurationList)
ext_target.build_configuration_list = ext_config_list

runner_config_list.build_configurations.each do |runner_config|
  ext_config = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  ext_config.name = runner_config.name
  ext_config_list.build_configurations << ext_config

  ext_config.build_settings = {
    'PRODUCT_NAME'                    => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER'       => EXTENSION_BUNDLE_ID,
    'INFOPLIST_FILE'                  => "#{EXTENSION_NAME}/Info.plist",
    'CODE_SIGN_ENTITLEMENTS'          => "#{EXTENSION_NAME}/#{EXTENSION_NAME}.entitlements",
    'IPHONEOS_DEPLOYMENT_TARGET'      => IOS_DEPLOYMENT_TARGET,
    'SWIFT_VERSION'                   => '5.0',
    'TARGETED_DEVICE_FAMILY'          => '1,2',
    'SKIP_INSTALL'                    => 'YES',
    'CODE_SIGN_STYLE'                 => 'Automatic',
    'LD_RUNPATH_SEARCH_PATHS'         => '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks',
    'GENERATE_INFOPLIST_FILE'         => 'NO',
  }
end

# ─── 5. Embed the extension into the main app ──────────────────────────────
embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_phase.name = 'Embed App Extensions'
embed_phase.dst_subfolder_spec = '13'  # PlugIns
runner_target.build_phases << embed_phase
embedded_ref = embed_phase.add_file_reference(product_ref)
embedded_ref.settings = { 'ATTRIBUTES' => ['RemoveHeaderOnCopy'] }

# Make Runner depend on building the extension first
dependency = runner_target.add_dependency(ext_target)

# ─── 6. Point Runner target at its new entitlements file ──────────────────
runner_target.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
end

project.save

puts ""
puts "✅ Done. Summary:"
puts "   • Bundle ID set to #{BUNDLE_ID} (Runner), #{BUNDLE_ID}.RunnerTests (tests)"
puts "   • New target '#{EXTENSION_NAME}' → bundle ID #{EXTENSION_BUNDLE_ID}"
puts "   • App Group #{APP_GROUP} added to both targets' entitlements"
puts "   • Extension embedded into Runner.app via Copy Files phase"
puts ""
puts "⚠️  Still needed before this builds:"
puts "   1. Register both bundle IDs in developer.apple.com → Identifiers"
puts "   2. Register the App Group #{APP_GROUP} in developer.apple.com → Identifiers → App Groups"
puts "   3. Enable 'Network Extension' capability on the #{EXTENSION_BUNDLE_ID} App ID"
puts "      (only possible after Apple approves your entitlement request)"
puts "   4. Fill in PacketTunnelProvider.swift with real sing-box calls"
puts "   5. Open ios/Runner.xcodeproj once in real Xcode (or via Codemagic) to"
puts "      sanity-check — xcodeproj edits are usually clean but Xcode is the"
puts "      final source of truth for anything it disagrees with."
