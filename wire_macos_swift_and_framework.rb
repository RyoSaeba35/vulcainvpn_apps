#!/usr/bin/env ruby
# wire_macos_swift_and_framework.rb
#
# Run AFTER placing these files (from this session) at:
#   macos/Runner/VulcainLogger.swift        (new)
#   macos/Runner/VpnManager.swift            (new)
#   macos/PacketTunnelMac/PacketTunnelProvider.swift  (OVERWRITE the stub —
#     no wiring needed for this one, it's already referenced in the project
#     from scaffold_macos_extension.rb, just replace its content)
#
# This script:
#   1. Adds VulcainLogger.swift to BOTH Runner and PacketTunnelMac Sources
#   2. Adds VpnManager.swift to Runner's Sources only
#   3. Adds a file reference to macos/Frameworks/Libbox.xcframework (doesn't
#      exist on disk yet — same as iOS, Codemagic builds it fresh each run)
#   4. LINKS it into PacketTunnelMac (compile-time only — do NOT embed here,
#      same lesson learned on iOS: "Stop embedding Libbox — it's a static
#      library, only link it")
#   5. EMBEDS it into Runner (Apple requires the actual embed to happen in
#      the main app, not the extension — same as the iOS fix)
#   6. Fixes LD_RUNPATH_SEARCH_PATHS on PacketTunnelMac. NOTE: the earlier
#      scaffold_macos_extension.rb set this to 4 levels up
#      (@executable_path/../../../../Frameworks) — that was WRONG, worked
#      out by hand here. The real nesting depth for a .systemextension is:
#        VulcainVPN.app/Contents/Library/SystemExtensions/EXT.systemextension/Contents/MacOS/
#      That's 5 levels up from the executable's directory to reach
#      VulcainVPN.app/Contents/, then into Frameworks/. This script
#      corrects it to 5.

require 'xcodeproj'

PROJECT_PATH = 'macos/Runner.xcodeproj'

project = Xcodeproj::Project.open(PROJECT_PATH)

runner_target = project.targets.find { |t| t.name == 'Runner' }
ext_target = project.targets.find { |t| t.name == 'PacketTunnelMac' }

raise "Could not find Runner target" unless runner_target
raise "Could not find PacketTunnelMac target — run scaffold_macos_extension.rb first" unless ext_target

puts "▶ Runner: #{runner_target.uuid}"
puts "▶ PacketTunnelMac: #{ext_target.uuid}"

# ---------------------------------------------------------------------
# 1 & 2. Add VulcainLogger.swift (both targets) and VpnManager.swift (Runner only)
# ---------------------------------------------------------------------

runner_group = project.main_group.find_subpath('Runner', false)
raise "Could not find Runner group in project" unless runner_group

['VulcainLogger.swift', 'VpnManager.swift'].each do |filename|
  fs_path = "macos/Runner/#{filename}"
  unless File.exist?(fs_path)
    puts "❌ #{fs_path} not found on disk — place the file there before running this script"
    next
  end

  existing_ref = runner_group.files.find { |f| f.path == filename }
  file_ref = existing_ref || runner_group.new_reference(filename)

  unless runner_target.source_build_phase.files_references.include?(file_ref)
    runner_target.source_build_phase.add_file_reference(file_ref)
    puts "▶ Added #{filename} to Runner Sources"
  end
end

# VulcainLogger.swift additionally needs to be in PacketTunnelMac's Sources
# (it's a shared struct compiled into both targets, same pattern as iOS's
# add_shared_logger.rb).
logger_ref = runner_group.files.find { |f| f.path == 'VulcainLogger.swift' }
if logger_ref
  unless ext_target.source_build_phase.files_references.include?(logger_ref)
    ext_target.source_build_phase.add_file_reference(logger_ref)
    puts "▶ Added VulcainLogger.swift to PacketTunnelMac Sources"
  end
else
  puts "❌ Could not find VulcainLogger.swift file reference to share with PacketTunnelMac"
end

# ---------------------------------------------------------------------
# 3. Add Libbox.xcframework file reference (macOS build, doesn't exist yet)
# ---------------------------------------------------------------------

frameworks_group = project.main_group.find_subpath('Frameworks', true)
frameworks_group.set_source_tree('SOURCE_ROOT')

libbox_ref = frameworks_group.files.find { |f| f.path == 'Frameworks/Libbox.xcframework' }
libbox_ref ||= frameworks_group.new_reference('Frameworks/Libbox.xcframework')
libbox_ref.last_known_file_type = 'wrapper.xcframework'

puts "▶ Libbox.xcframework file reference ready: #{libbox_ref.uuid}"

# ---------------------------------------------------------------------
# 4. Link (compile-time only) into PacketTunnelMac
# ---------------------------------------------------------------------

ext_frameworks_phase = ext_target.frameworks_build_phase
unless ext_frameworks_phase.files_references.include?(libbox_ref)
  ext_frameworks_phase.add_file_reference(libbox_ref)
  puts "▶ Linked Libbox.xcframework into PacketTunnelMac (compile-time)"
end

# ---------------------------------------------------------------------
# 5. Embed into Runner (create Embed Frameworks phase if it doesn't exist)
# ---------------------------------------------------------------------

embed_frameworks_phase = runner_target.build_phases.find { |p| p.respond_to?(:name) && p.name == 'Embed Frameworks' }

unless embed_frameworks_phase
  embed_frameworks_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  embed_frameworks_phase.name = 'Embed Frameworks'
  embed_frameworks_phase.symbol_dst_subfolder_spec = :frameworks
  runner_target.build_phases << embed_frameworks_phase
  puts "▶ Created 'Embed Frameworks' phase on Runner"
end

runner_frameworks_phase = runner_target.frameworks_build_phase
unless runner_frameworks_phase.files_references.include?(libbox_ref)
  runner_frameworks_phase.add_file_reference(libbox_ref)
  puts "▶ Linked Libbox.xcframework into Runner"
end

unless embed_frameworks_phase.files_references.include?(libbox_ref)
  embed_build_file = embed_frameworks_phase.add_file_reference(libbox_ref)
  embed_build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  puts "▶ Embedded Libbox.xcframework into Runner"
end

# ---------------------------------------------------------------------
# 6. Fix LD_RUNPATH_SEARCH_PATHS on PacketTunnelMac (5 levels, not 4)
# ---------------------------------------------------------------------

ext_target.build_configurations.each do |config|
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/../../../../../Frameworks',
  ]
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(PROJECT_DIR)/Frameworks']
end

runner_target.build_configurations.each do |config|
  existing = config.build_settings['FRAMEWORK_SEARCH_PATHS']
  paths = existing.is_a?(Array) ? existing : (existing.nil? ? [] : [existing])
  paths = ['$(inherited)'] if paths.empty?
  paths << '$(PROJECT_DIR)/Frameworks' unless paths.include?('$(PROJECT_DIR)/Frameworks')
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = paths
end

puts "▶ Fixed LD_RUNPATH_SEARCH_PATHS (5 levels) and FRAMEWORK_SEARCH_PATHS on both targets"

project.save

puts ""
puts "✅ Done. Summary:"
puts "   • VulcainLogger.swift wired into Runner + PacketTunnelMac Sources"
puts "   • VpnManager.swift wired into Runner Sources"
puts "   • Libbox.xcframework: linked (compile-time) into PacketTunnelMac, linked + embedded into Runner"
puts "   • LD_RUNPATH_SEARCH_PATHS corrected to 5 levels on PacketTunnelMac"
puts ""
puts "⚠️  Still needed:"
puts "   1. Overwrite macos/PacketTunnelMac/PacketTunnelProvider.swift with the real implementation (from this session)"
puts "   2. Add VpnManager.register(with:) call to macos/Runner/MainFlutterWindow.swift — see next message"
puts "   3. Update codemagic.yaml to build Libbox.xcframework for macOS (gomobile bind -target=macos)"
puts "   4. Register bundle IDs, App Group, and confirm entitlement approval on developer.apple.com"
puts "   5. Rewrite lib/services/vpn_service_macos.dart to call the new MethodChannel instead of spawning sing-box"
