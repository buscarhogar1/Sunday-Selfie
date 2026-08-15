#!/usr/bin/env ruby
# frozen_string_literal: true

repo_root = ENV.fetch('REPO_ROOT') { File.expand_path('../..', __dir__) }
ios_root = File.join(repo_root, 'ios')
pods_support_root = File.join(ios_root, 'Pods/Target Support Files/Pods-Runner')

pods_configs = [
  File.join(pods_support_root, 'Pods-Runner.debug.xcconfig'),
  File.join(pods_support_root, 'Pods-Runner.release.xcconfig'),
  File.join(pods_support_root, 'Pods-Runner.profile.xcconfig')
]

marker_start = '// BEGIN XCODE CLOUD FLUTTER SETTINGS'
marker_end = '// END XCODE CLOUD FLUTTER SETTINGS'
settings_block = [
  marker_start,
  '#include? "../../../Flutter/Generated.xcconfig"',
  'SWIFT_ENABLE_EXPLICIT_MODULES = NO',
  '_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES = NO',
  'CLANG_ENABLE_MODULES = YES',
  marker_end
].join("\n")

pods_configs.each do |path|
  abort "Missing CocoaPods config: #{path}" unless File.exist?(path)

  content = File.read(path)
  content = content.gsub(/\n?#{Regexp.escape(marker_start)}.*?#{Regexp.escape(marker_end)}\n?/m, "\n")
  content = "#{content.rstrip}\n\n#{settings_block}\n"

  if ENV['DRY_RUN'] == '1'
    puts "Would patch #{path}"
  else
    File.write(path, content)
    puts "Patched #{path}"
  end
end

puts 'Patched CocoaPods xcconfig files with Flutter build settings.'
