#!/usr/bin/env ruby
# fix_embed_phase_order.rb
#
# Known Flutter + iOS app extension bug (flutter/flutter#135056): the
# "Embed App Extensions" copy phase must run BEFORE Flutter's "Thin Binary"
# script phase, or Xcode's new build system detects a dependency cycle
# between them. Our embed phase was appended to the end of the target's
# build phases, landing after Thin Binary. This moves it before.
#
# Usage:
#   ruby fix_embed_phase_order.rb

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'

unless Dir.exist?(PROJECT_PATH)
  abort "❌ Can't find #{PROJECT_PATH}. Run this from your Flutter project root."
end

project = Xcodeproj::Project.open(PROJECT_PATH)

runner_target = project.targets.find { |t| t.name == 'Runner' }
abort '❌ Could not find Runner target' unless runner_target

embed_phase = runner_target.build_phases.find do |p|
  p.respond_to?(:name) && p.name == 'Embed App Extensions'
end
abort '❌ Could not find "Embed App Extensions" phase — run scaffold_ios_extension.rb first' unless embed_phase

thin_binary_phase = runner_target.build_phases.find do |p|
  p.respond_to?(:name) && p.name == 'Thin Binary'
end

unless thin_binary_phase
  puts "⚠️  Could not find a 'Thin Binary' phase by that exact name."
  puts "   Listing all build phases on Runner so we can find the right one:"
  runner_target.build_phases.each_with_index do |p, i|
    label = p.respond_to?(:name) ? p.name : p.class.to_s
    puts "   #{i}: #{label}"
  end
  abort "   Re-run after telling me which index/name is the Thin Binary equivalent."
end

current_index = runner_target.build_phases.index(embed_phase)
target_index = runner_target.build_phases.index(thin_binary_phase)

if current_index < target_index
  puts "✅ Embed App Extensions is already before Thin Binary — nothing to do."
else
  runner_target.build_phases.delete(embed_phase)
  # Recompute thin binary's index since deletion shifted the array
  new_thin_index = runner_target.build_phases.index(thin_binary_phase)
  runner_target.build_phases.insert(new_thin_index, embed_phase)
  puts "▶ Moved 'Embed App Extensions' to run before 'Thin Binary'"
  project.save
  puts "✅ Saved."
end
