#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'ios/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

file_ref = project.files.find { |f| f.path == 'Runner/VpnManager.swift' }

if file_ref
  file_ref.path = 'VpnManager.swift'
  project.save
  puts "Fixed path: 'Runner/VpnManager.swift' -> 'VpnManager.swift'"
else
  existing = project.files.find { |f| f.display_name == 'VpnManager.swift' }
  if existing
    puts "Found reference with path: #{existing.path.inspect} — not the expected 'Runner/VpnManager.swift', leaving untouched. Inspect manually."
  else
    puts "No VpnManager.swift reference found at all — did the earlier script actually run and save?"
  end
end
