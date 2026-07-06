#!/usr/bin/env ruby
# add_shared_logger.rb
#
# Adds VulcainLogger.swift to BOTH the Runner and PacketTunnel targets'
# Compile Sources build phase, since it needs to be usable from both
# processes (main app + extension).
#
# Usage:
#   Place VulcainLogger.swift at ios/Runner/VulcainLogger.swift first,
#   then run this from the Flutter project root:
#   ruby add_shared_logger.rb

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'
FILE_PATH = 'Runner/VulcainLogger.swift'

unless Dir.exist?(PROJECT_PATH)
  abort "❌ Can't find #{PROJECT_PATH}. Run this from your Flutter project root."
end
unless File.exist?("ios/#{FILE_PATH}")
  abort "❌ Can't find ios/#{FILE_PATH}. Place VulcainLogger.swift there first."
end

project = Xcodeproj::Project.open(PROJECT_PATH)

runner_target = project.targets.find { |t| t.name == 'Runner' }
ext_target = project.targets.find { |t| t.name == 'PacketTunnel' }
abort '❌ Could not find Runner target' unless runner_target
abort '❌ Could not find PacketTunnel target' unless ext_target

runner_group = project.main_group['Runner']
abort "❌ Could not find Runner group" unless runner_group

existing_ref = runner_group.files.find { |f| f.path == 'VulcainLogger.swift' }
file_ref = existing_ref || runner_group.new_reference('VulcainLogger.swift')

[runner_target, ext_target].each do |target|
  sources_phase = target.source_build_phase
  already_added = sources_phase.files.any? { |f| f.file_ref == file_ref }
  unless already_added
    sources_phase.add_file_reference(file_ref)
    puts "▶ Added VulcainLogger.swift to #{target.name}'s Compile Sources"
  else
    puts "⚠️  VulcainLogger.swift already in #{target.name}'s Compile Sources — skipped"
  end
end

project.save

puts ""
puts "✅ Done. VulcainLogger is now compiled into both targets."
