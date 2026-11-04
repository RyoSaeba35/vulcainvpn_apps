#!/usr/bin/env ruby
# scaffold_macos_extension.rb
#
# Adds a PacketTunnel System Extension target to macos/Runner.xcodeproj.
#
# Unlike iOS (App Extension / .appex), macOS Developer ID distribution
# requires a System Extension (.systemextension) — confirmed directly by
# Apple DTS: appex packaging is Mac App Store only. This script scaffolds
# that target, wires up the App Group + entitlements on both targets, and
# adds the "Embed System Extensions" copy phase to Runner.
#
# Run this ONCE, locally (no Mac required — same as the iOS script).
# Then verify by opening in real Xcode / via Codemagic before trusting it.

require 'xcodeproj'

PROJECT_PATH = 'macos/Runner.xcodeproj'
MAIN_BUNDLE_ID = 'com.vulcainvpn.app.macos'
EXT_BUNDLE_ID  = 'com.vulcainvpn.app.macos.PacketTunnel'
APP_GROUP      = 'group.com.vulcainvpn.app.macos'
EXT_NAME       = 'PacketTunnelMac'
EXT_DIR        = 'PacketTunnelMac'          # relative to macos/ — used for xcodeproj group/build-setting paths
FS_EXT_DIR     = "macos/#{EXT_DIR}"         # relative to repo root — used for actual File/Dir operations

project = Xcodeproj::Project.open(PROJECT_PATH)

runner_target = project.targets.find { |t| t.name == 'Runner' }
raise "Could not find Runner target" unless runner_target

puts "▶ Found Runner target: #{runner_target.uuid}"

# ---------------------------------------------------------------------
# 1. Create the PacketTunnelMac System Extension target
# ---------------------------------------------------------------------

ext_target = project.new_target(
  :system_extension,
  EXT_NAME,
  :osx,
  '10.15',
  project.products_group,
  :bundle
)

# xcodeproj's :system_extension helper (if present in this gem version)
# may not set the exact product type UTI Apple expects — force it explicitly
# to be safe rather than trust the shortcut.
ext_target.product_type = 'com.apple.product-type.system-extension'

puts "▶ Created target #{EXT_NAME}: #{ext_target.uuid}"

# Build phases: a fresh :bundle-based new_target already gives Sources/
# Frameworks/Resources phases. Verify they exist; add if somehow missing.
sources_phase = ext_target.source_build_phase
frameworks_phase = ext_target.frameworks_build_phase
resources_phase = ext_target.resources_build_phase

sources_phase ||= project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase).tap { |p| ext_target.build_phases << p }
frameworks_phase ||= project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase).tap { |p| ext_target.build_phases << p }
resources_phase ||= project.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase).tap { |p| ext_target.build_phases << p }

# ---------------------------------------------------------------------
# 2. Create the PacketTunnelMac group + files on disk
# ---------------------------------------------------------------------

Dir.mkdir(FS_EXT_DIR) unless Dir.exist?(FS_EXT_DIR)

info_plist_content = <<~PLIST
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>VulcainVPN Packet Tunnel</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>SYSX</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
      <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSystemExtensionUsageDescription</key>
    <string>VulcainVPN uses a system extension to establish a secure VPN tunnel.</string>
    <key>NetworkExtension</key>
    <dict>
      <key>NEProviderClasses</key>
      <dict>
        <key>com.apple.networkextension.packet-tunnel</key>
        <string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
      </dict>
    </dict>
  </dict>
  </plist>
PLIST
File.write("#{FS_EXT_DIR}/Info.plist", info_plist_content)
puts "▶ Wrote #{FS_EXT_DIR}/Info.plist"

entitlements_content = <<~ENTITLEMENTS
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
      <string>packet-tunnel-provider</string>
    </array>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
      <string>#{APP_GROUP}</string>
    </array>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
  </dict>
  </plist>
ENTITLEMENTS
File.write("#{FS_EXT_DIR}/#{EXT_NAME}.entitlements", entitlements_content)
puts "▶ Wrote #{FS_EXT_DIR}/#{EXT_NAME}.entitlements"

provider_stub = <<~SWIFT
  import NetworkExtension
  import os.log

  // STUB — this is intentionally minimal. The real implementation should
  // port the proven logic from ios/PacketTunnel/PacketTunnelProvider.swift:
  //   - CommandServer/Libbox setup (LibboxSetup, pointed at the App Group
  //     container, same as iOS)
  //   - getInterfaces() returning CIDR-format addresses (NOT bare IPs —
  //     this was the exact cause of a sing-box panic on iOS, see commit
  //     "Fix the actual crash: getInterfaces() must return CIDR addresses")
  //   - autoDetectControl / IP_BOUND_IF binding logic
  //   - stderr redirection for Go panic capture (VulcainLogger pattern)
  //   - packetFlow.readPackets() liveness loop
  // NetworkExtension APIs are shared between iOS and macOS, so most of that
  // Swift code should port with minimal changes — the macOS-specific delta
  // is mainly around how the extension gets activated (OSSystemExtensionRequest
  // from the main app) rather than the tunnel logic itself.
  class PacketTunnelProvider: NEPacketTunnelProvider {
      override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
          os_log("PacketTunnelMac: startTunnel called (stub)")
          completionHandler(nil)
      }

      override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
          os_log("PacketTunnelMac: stopTunnel called (stub)")
          completionHandler()
      }
  }
SWIFT
File.write("#{FS_EXT_DIR}/PacketTunnelProvider.swift", provider_stub)
puts "▶ Wrote #{FS_EXT_DIR}/PacketTunnelProvider.swift (STUB — needs real implementation ported from iOS)"

# ---------------------------------------------------------------------
# 3. Add file references to the project, attach to the right build phases
# ---------------------------------------------------------------------

ext_group = project.main_group.new_group(EXT_NAME, EXT_DIR)

info_plist_ref = ext_group.new_reference("#{EXT_DIR}/Info.plist")

entitlements_ref = ext_group.new_reference("#{EXT_DIR}/#{EXT_NAME}.entitlements")

provider_ref = ext_group.new_reference("#{EXT_DIR}/PacketTunnelProvider.swift")
sources_phase.add_file_reference(provider_ref)

puts "▶ Added file references and wired PacketTunnelProvider.swift into Sources"

# ---------------------------------------------------------------------
# 4. Set build settings on the new target (Debug/Release/Profile)
# ---------------------------------------------------------------------

ext_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE_ID
  config.build_settings['PRODUCT_NAME'] = EXT_NAME
  config.build_settings['INFOPLIST_FILE'] = "#{EXT_DIR}/Info.plist"
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_DIR}/#{EXT_NAME}.entitlements"
  config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '10.15'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../../../../Frameworks']
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
end

puts "▶ Set build settings on #{EXT_NAME} target (all configurations)"

# ---------------------------------------------------------------------
# 5. Add "Embed System Extensions" copy phase to Runner, add dependency
# ---------------------------------------------------------------------

embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_phase.name = 'Embed System Extensions'
embed_phase.symbol_dst_subfolder_spec = :products_directory  # placeholder, overridden below
embed_phase.dst_subfolder_spec = '16'  # absolute path mode
embed_phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions'
runner_target.build_phases << embed_phase

build_file = embed_phase.add_file_reference(ext_target.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

runner_target.add_dependency(ext_target)

puts "▶ Added 'Embed System Extensions' phase to Runner, added target dependency"

# ---------------------------------------------------------------------
# 6. Update Runner's entitlements: add system-extension.install + App Group
#    NOTE: this edits the files on disk directly (simpler + more reliable
#    than manipulating plist via xcodeproj for existing referenced files).
# ---------------------------------------------------------------------

['macos/Runner/DebugProfile.entitlements', 'macos/Runner/Release.entitlements'].each do |path|
  unless File.exist?(path)
    puts "⚠️  #{path} not found, skipping"
    next
  end

  content = File.read(path)

  unless content.include?('com.apple.developer.system-extension.install')
    content = content.sub(
      '<dict>',
      "<dict>\n\t<key>com.apple.developer.system-extension.install</key>\n\t<true/>"
    )
  end

  unless content.include?(APP_GROUP)
    content = content.sub(
      '<dict>',
      "<dict>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>#{APP_GROUP}</string>\n\t</array>"
    )
  end

  # As established this session: sandboxed sysex requires a sandboxed
  # container app too. Flip app-sandbox to true, remove it if present as
  # false first.
  content = content.sub(
    /<key>com\.apple\.security\.app-sandbox<\/key>\s*<false\/>/,
    "<key>com.apple.security.app-sandbox</key>\n\t<true/>"
  )

  File.write(path, content)
  puts "▶ Updated #{path}"
end

# ---------------------------------------------------------------------
# 7. Save
# ---------------------------------------------------------------------

project.save
puts ""
puts "✅ Done. Summary:"
puts "   • Created System Extension target '#{EXT_NAME}' (product type: com.apple.product-type.system-extension)"
puts "   • Bundle ID: #{EXT_BUNDLE_ID}"
puts "   • App Group #{APP_GROUP} added to both targets' entitlements"
puts "   • Runner entitlements: app-sandbox flipped to true, system-extension.install added"
puts "   • 'Embed System Extensions' copy phase added to Runner (Contents/Library/SystemExtensions)"
puts ""
puts "⚠️  Still needed before this builds/works:"
puts "   1. PacketTunnelProvider.swift is a STUB — port real logic from ios/PacketTunnel/PacketTunnelProvider.swift"
puts "   2. Build Libbox.xcframework for macOS (gomobile bind -target=macos) — Codemagic step, like iOS"
puts "   3. Link Libbox.xcframework into the PacketTunnelMac target (compile-time only — same lesson"
puts "      learned on iOS: 'Stop embedding Libbox — it's a static library, only link it')"
puts "   4. Register #{MAIN_BUNDLE_ID} and #{EXT_BUNDLE_ID} in developer.apple.com → Identifiers"
puts "   5. Register App Group #{APP_GROUP} in developer.apple.com → Identifiers → App Groups"
puts "   6. Request/confirm System Extension + Network Extension entitlement approval covers macOS"
puts "      (per Apple DTS: an approved iOS NE entitlement does not automatically cover macOS)"
puts "   7. Remove now-obsolete sing-box-arm64/sing-box-amd64 bundling from codemagic.yaml + macos/Runner/Resources"
puts "      once the extension actually works — don't remove yet, keep as fallback until verified"
puts "   8. Open once in real Xcode (or trust Codemagic's build log) to sanity-check — same caveat"
puts "      as the iOS script: xcodeproj edits are usually clean but Xcode is the final source of truth"
