#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'ios/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

targets_to_fix = ['Runner', 'PacketTunnel']

project.targets.each do |target|
  next unless targets_to_fix.include?(target.name)

  target.build_configurations.each do |config|
    ldflags = config.build_settings['OTHER_LDFLAGS']

    # Normalize to an array
    if ldflags.nil?
      ldflags = ['$(inherited)']
    elsif ldflags.is_a?(String)
      ldflags = [ldflags]
    end

    unless ldflags.include?('-lresolv')
      ldflags << '-lresolv'
      config.build_settings['OTHER_LDFLAGS'] = ldflags
      puts "Added -lresolv to #{target.name} / #{config.name}"
    else
      puts "-lresolv already present in #{target.name} / #{config.name}"
    end
  end
end

project.save
puts "Saved #{project_path}"
