#!/usr/bin/env ruby
# link_libbox_framework.rb
#
# Run this AFTER scaffold_ios_extension.rb, from the same project root.
#
# Wires up ios/Frameworks/Libbox.xcframework as a linked + embedded framework
# in the PacketTunnel extension target. The actual .xcframework file doesn't
# need to exist on YOUR machine — Codemagic's CI build produces it fresh at
# that exact path (ios/Frameworks/Libbox.xcframework) before Xcode compiles
# anything, via the "Build sing-box iOS framework" step in codemagic.yaml.
# This script just tells the Xcode project "expect a framework there and
# link/embed it into the PacketTunnel.appex" — a reference, not the file itself.
#
# Usage:
#   ruby link_libbox_framework.rb

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'
EXTENSION_NAME = 'PacketTunnel'
FRAMEWORK_RELATIVE_PATH = 'Frameworks/Libbox.xcframework'  # relative to ios/

unless Dir.exist?(PROJECT_PATH)
  abort "❌ Can't find #{PROJECT_PATH}. Run this from your Flutter project root."
end

project = Xcodeproj::Project.open(PROJECT_PATH)

ext_target = project.targets.find { |t| t.name == EXTENSION_NAME }
abort "❌ Could not find #{EXTENSION_NAME} target — run scaffold_ios_extension.rb first" unless ext_target

if project.frameworks_group.files.any? { |f| f.path == FRAMEWORK_RELATIVE_PATH }
  abort "❌ Libbox.xcframework reference already exists — script already run?"
end

# ─── 1. Add the file reference (doesn't need to exist on disk right now) ──
framework_ref = project.frameworks_group.new_reference(FRAMEWORK_RELATIVE_PATH)
framework_ref.source_tree = 'SDKROOT'  # relative to ios/ (SRCROOT), not absolute
framework_ref.source_tree = '<group>'  # relative to the Frameworks group location
puts "▶ Added file reference for #{FRAMEWORK_RELATIVE_PATH}"

# ─── 2. Link it into the extension target's Frameworks build phase ────────
frameworks_phase = ext_target.frameworks_build_phases
abort '❌ Could not find Frameworks build phase on extension target' unless frameworks_phase
frameworks_phase.add_file_reference(framework_ref)
puts "▶ Linked Libbox.xcframework to #{EXTENSION_NAME} target"

# ─── 3. Embed it into the extension bundle (xcframeworks with dynamic ─────
#         libraries must be embedded, not just linked, in the consuming target)
embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_phase.name = 'Embed Frameworks'
embed_phase.dst_subfolder_spec = '10'  # Frameworks folder
ext_target.build_phases << embed_phase
embedded_ref = embed_phase.add_file_reference(framework_ref)
embedded_ref.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeaderOnCopy'] }
puts "▶ Added Embed Frameworks phase to #{EXTENSION_NAME} target"

# ─── 4. Framework search path + runpath so the linker/loader find it ──────
ext_target.build_configurations.each do |config|
  existing_search = config.build_settings['FRAMEWORK_SEARCH_PATHS']
  paths = existing_search.is_a?(Array) ? existing_search : (existing_search ? [existing_search] : ['$(inherited)'])
  paths << '$(SRCROOT)/Frameworks' unless paths.include?('$(SRCROOT)/Frameworks')
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = paths

  existing_runpath = config.build_settings['LD_RUNPATH_SEARCH_PATHS']
  rpaths = existing_runpath.is_a?(Array) ? existing_runpath : (existing_runpath ? [existing_runpath] : ['$(inherited)'])
  rpaths << '@executable_path/Frameworks' unless rpaths.include?('@executable_path/Frameworks')
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = rpaths
end
puts "▶ Set FRAMEWORK_SEARCH_PATHS and LD_RUNPATH_SEARCH_PATHS on #{EXTENSION_NAME}"

project.save

puts ""
puts "✅ Done. Libbox.xcframework is now wired into the #{EXTENSION_NAME} target."
puts "   Remember: the actual framework FILE is built fresh by Codemagic CI"
puts "   at ios/Frameworks/Libbox.xcframework — you don't need it locally,"
puts "   and it won't exist in your working tree. That's expected."
puts ""
puts "⚠️  PacketTunnelProvider.swift still needs 'import Libbox' uncommented"
puts "   and real sing-box calls written in — currently just TODO stubs."
