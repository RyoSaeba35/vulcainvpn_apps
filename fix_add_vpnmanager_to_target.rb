#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'ios/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

runner_target = project.targets.find { |t| t.name == 'Runner' }
raise "Runner target not found" unless runner_target

runner_group = project.main_group.find_subpath('Runner', true)
raise "Runner group not found" unless runner_group

file_path = 'Runner/VpnManager.swift'

# Skip if already referenced anywhere in the project
existing = project.files.find { |f| f.path == 'VpnManager.swift' }

if existing
  puts "VpnManager.swift already referenced in project — checking target membership"
  unless runner_target.source_build_phase.files_references.include?(existing)
    runner_target.add_file_references([existing])
    puts "Added existing reference to Runner target's Compile Sources"
  else
    puts "Already in Runner target's Compile Sources — nothing to do"
  end
else
  file_ref = runner_group.new_reference(file_path)
  file_ref.source_tree = '<group>'
  runner_target.add_file_references([file_ref])
  puts "Added VpnManager.swift as new file reference and to Runner target's Compile Sources"
end

project.save
puts "Saved #{project_path}"
