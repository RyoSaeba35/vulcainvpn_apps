#!/usr/bin/env ruby
# fix_framework_embed_location.rb
#
# Apple rejects app extensions that carry their own embedded Frameworks
# directory ("disallowed file 'Frameworks'" / "disallowed nested bundles").
# Frameworks used by an extension must be embedded in the CONTAINING APP
# instead — the extension just links against it (already resolved at
# runtime via the @executable_path/../../Frameworks rpath we set earlier).
#
# This moves the "Embed Frameworks" copy phase from PacketTunnel to Runner.
# The extension keeps its Frameworks (link) build phase — only removing the
# COPY/embed step, not the link.
#
# Usage:
#   ruby fix_framework_embed_location.rb

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'

unless Dir.exist?(PROJECT_PATH)
  abort "❌ Can't find #{PROJECT_PATH}. Run this from your Flutter project root."
end

project = Xcodeproj::Project.open(PROJECT_PATH)

runner_target = project.targets.find { |t| t.name == 'Runner' }
ext_target = project.targets.find { |t| t.name == 'PacketTunnel' }
abort '❌ Could not find Runner target' unless runner_target
abort '❌ Could not find PacketTunnel target' unless ext_target

# Find the existing Embed Frameworks phase on the extension
ext_embed_phase = ext_target.build_phases.find do |p|
  p.respond_to?(:name) && p.name == 'Embed Frameworks'
end
abort '❌ Could not find "Embed Frameworks" phase on PacketTunnel — already fixed?' unless ext_embed_phase

# Grab the framework file reference it was embedding, before we delete the phase
framework_build_file = ext_embed_phase.files.first
abort '❌ Embed Frameworks phase has no files' unless framework_build_file
framework_ref = framework_build_file.file_ref

# Remove the embed phase from the extension entirely
ext_target.build_phases.delete(ext_embed_phase)
project.objects.delete(ext_embed_phase) if project.objects.include?(ext_embed_phase)
puts "▶ Removed 'Embed Frameworks' phase from PacketTunnel extension"

# Check Runner doesn't already have one (idempotency)
existing_runner_embed = runner_target.build_phases.find do |p|
  p.respond_to?(:name) && p.name == 'Embed Frameworks'
end

if existing_runner_embed
  puts "⚠️  Runner already has an 'Embed Frameworks' phase — adding file reference to it instead of creating a new phase"
  new_build_file = existing_runner_embed.add_file_reference(framework_ref)
  new_build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeaderOnCopy'] }
else
  new_embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  new_embed_phase.name = 'Embed Frameworks'
  new_embed_phase.dst_subfolder_spec = '10'  # Frameworks folder
  runner_target.build_phases << new_embed_phase
  new_build_file = new_embed_phase.add_file_reference(framework_ref)
  new_build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeaderOnCopy'] }
  puts "▶ Added 'Embed Frameworks' phase to Runner, embedding Libbox.xcframework"
end

# Make sure Runner's build settings have the framework search path too
runner_target.build_configurations.each do |config|
  existing_search = config.build_settings['FRAMEWORK_SEARCH_PATHS']
  paths = existing_search.is_a?(Array) ? existing_search : (existing_search ? [existing_search] : ['$(inherited)'])
  paths << '$(SRCROOT)/Frameworks' unless paths.include?('$(SRCROOT)/Frameworks')
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = paths
end
puts "▶ Ensured FRAMEWORK_SEARCH_PATHS on Runner"

project.save

puts ""
puts "✅ Done. Libbox.xcframework now embeds in Runner.app/Frameworks/,"
puts "   PacketTunnel.appex links against it via the existing rpath"
puts "   (@executable_path/../../Frameworks) without carrying its own copy."
