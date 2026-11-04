#!/usr/bin/env ruby
# fix_group_paths.rb
#
# The original scaffold script gave the PacketTunnel group and its file
# references paths already prefixed with "ios/PacketTunnel/..." — but
# Xcode group/file paths are relative to their PARENT group's location,
# and the parent (main_group) is already anchored inside ios/. This
# doubled the prefix: ios/ + ios/PacketTunnel/... = ios/ios/PacketTunnel/...
#
# This script corrects the group's own path and all its file references
# to be relative to the group itself, not repo-root-relative.
#
# Usage:
#   ruby fix_group_paths.rb

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'
EXTENSION_NAME = 'PacketTunnel'

unless Dir.exist?(PROJECT_PATH)
  abort "❌ Can't find #{PROJECT_PATH}. Run this from your Flutter project root."
end

project = Xcodeproj::Project.open(PROJECT_PATH)

ext_group = project.main_group[EXTENSION_NAME]
abort "❌ Could not find #{EXTENSION_NAME} group" unless ext_group

puts "▶ Group '#{EXTENSION_NAME}' current path: #{ext_group.path.inspect}"
ext_group.path = EXTENSION_NAME
puts "▶ Set group path to: #{ext_group.path.inspect}"

ext_group.files.each do |file_ref|
  old_path = file_ref.path
  new_path = File.basename(old_path)
  file_ref.path = new_path
  puts "▶ Fixed file reference: #{old_path.inspect} → #{new_path.inspect}"
end

# Also check the Runner.entitlements reference, added the same buggy way
runner_group = project.main_group['Runner']
if runner_group
  runner_group.files.each do |file_ref|
    next unless file_ref.path.to_s.include?('Runner.entitlements')
    old_path = file_ref.path
    if old_path.include?('/')
      new_path = File.basename(old_path)
      file_ref.path = new_path
      puts "▶ Fixed Runner file reference: #{old_path.inspect} → #{new_path.inspect}"
    end
  end
end

project.save

puts ""
puts "✅ Done. Verify in the diff that only path strings changed, nothing structural."
