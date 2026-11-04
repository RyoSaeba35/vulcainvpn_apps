#!/usr/bin/env ruby
# fix_remove_framework_embed.rb
#
# Root cause (confirmed via an Apple Forums thread with the identical
# error): the "invalid bundle structure... binary file is not permitted"
# error happens when a framework's binary is a STATIC library rather than
# a true dynamic library (.dylib) and it gets EMBEDDED (copied at runtime)
# into the app bundle. Static libraries must only be LINKED at compile
# time — embedding them creates a loose, non-dylib executable sitting in
# Frameworks/, which Apple's validator correctly rejects.
#
# gomobile bind's output is very likely static under the hood. This
# removes the Embed Frameworks copy phase entirely (wherever it currently
# is — we'd previously moved it to Runner). The existing LINK reference
# (Frameworks / "Link Binary With Libraries" phase) on PacketTunnel stays
# untouched — that's the correct, sufficient way to consume a static lib.
#
# Usage:
#   ruby fix_remove_framework_embed.rb

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'

unless Dir.exist?(PROJECT_PATH)
  abort "❌ Can't find #{PROJECT_PATH}. Run this from your Flutter project root."
end

project = Xcodeproj::Project.open(PROJECT_PATH)

removed_any = false

project.targets.each do |target|
  embed_phase = target.build_phases.find do |p|
    p.respond_to?(:name) && p.name == 'Embed Frameworks'
  end
  next unless embed_phase

  target.build_phases.delete(embed_phase)
  project.objects.delete(embed_phase) if project.objects.include?(embed_phase)
  puts "▶ Removed 'Embed Frameworks' phase from #{target.name}"
  removed_any = true
end

unless removed_any
  puts "⚠️  No 'Embed Frameworks' phase found on any target — already removed?"
end

# Confirm PacketTunnel still has the LINK reference (should be untouched)
ext_target = project.targets.find { |t| t.name == 'PacketTunnel' }
if ext_target
  has_link = ext_target.frameworks_build_phases.files.any? do |f|
    f.file_ref && f.file_ref.path.to_s.include?('Libbox')
  end
  if has_link
    puts "✅ PacketTunnel still links Libbox.xcframework (compile-time only) — correct."
  else
    puts "⚠️  PacketTunnel does NOT have a Libbox link reference — something's missing, check manually."
  end
end

project.save

puts ""
puts "✅ Done. Libbox.xcframework is now linked (compile-time) but not embedded"
puts "   (runtime copy) anywhere — matching how static libraries must be consumed."
