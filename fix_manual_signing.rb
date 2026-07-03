#!/usr/bin/env ruby
# fix_manual_signing.rb
#
# The scaffold script set CODE_SIGN_STYLE = Automatic on both targets.
# That conflicts with Codemagic's CI-managed signing flow (fetch-signing-files
# + xcode-project use-profiles), which needs Manual signing style to actually
# apply the specific provisioning profiles it fetches. With Automatic set,
# Xcode tries to self-manage signing — which needs a logged-in Apple ID that
# doesn't exist on a CI machine — and silently resolves to no valid profile.
#
# Usage:
#   ruby fix_manual_signing.rb

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'

unless Dir.exist?(PROJECT_PATH)
  abort "❌ Can't find #{PROJECT_PATH}. Run this from your Flutter project root."
end

project = Xcodeproj::Project.open(PROJECT_PATH)

%w[Runner PacketTunnel].each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  unless target
    puts "⚠️  Target #{target_name} not found, skipping"
    next
  end

  target.build_configurations.each do |config|
    config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
  end
  puts "▶ Set CODE_SIGN_STYLE = Manual on #{target_name}"
end

project.save

puts ""
puts "✅ Done. Both targets now use Manual signing, matching Codemagic's"
puts "   CI-managed fetch-signing-files / use-profiles flow."
