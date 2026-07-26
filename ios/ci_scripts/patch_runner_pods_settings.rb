#!/usr/bin/env ruby
# Makes the Runner target inherit the CocoaPods build settings explicitly.
# Xcode Cloud can otherwise compile GeneratedPluginRegistrant.m without the
# Pods framework/module search paths.

require "xcodeproj"

repo_root = ENV["REPO_ROOT"] || File.expand_path("../..", __dir__)
ios_dir = File.join(repo_root, "ios")
project_path = File.join(ios_dir, "Runner.xcodeproj")
pods_support_dir = File.join(
  ios_dir,
  "Pods",
  "Target Support Files",
  "Pods-Runner"
)

def parse_xcconfig(path)
  settings = {}

  File.foreach(path) do |line|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?("//", "#")

    match = stripped.match(/\A([A-Z0-9_]+)\s*=\s*(.+)\z/)
    next unless match

    settings[match[1]] = match[2].strip
  end

  settings
end

project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == "Runner" }
abort "Runner target not found in #{project_path}" unless runner

settings_to_copy = %w[
  ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES
  CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER
  FRAMEWORK_SEARCH_PATHS
  GCC_PREPROCESSOR_DEFINITIONS
  HEADER_SEARCH_PATHS
  LIBRARY_SEARCH_PATHS
  OTHER_LDFLAGS
  OTHER_MODULE_VERIFIER_FLAGS
  OTHER_SWIFT_FLAGS
  PODS_BUILD_DIR
  PODS_CONFIGURATION_BUILD_DIR
  PODS_PODFILE_DIR_PATH
  PODS_ROOT
  PODS_XCFRAMEWORKS_BUILD_DIR
  USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES
]

runner.build_configurations.each do |configuration|
  pods_config = configuration.name.downcase
  xcconfig_path = File.join(
    pods_support_dir,
    "Pods-Runner.#{pods_config}.xcconfig"
  )

  unless File.exist?(xcconfig_path)
    warn "Skipping #{configuration.name}: #{xcconfig_path} does not exist"
    next
  end

  pods_settings = parse_xcconfig(xcconfig_path)

  settings_to_copy.each do |key|
    value = pods_settings[key]
    configuration.build_settings[key] = value if value && !value.empty?
  end

  configuration.build_settings["CLANG_ENABLE_MODULES"] = "YES"
end

if ENV["DRY_RUN"] == "1"
  puts "Dry run: Runner Pods settings are readable."
else
  project.save
  puts "Runner target now has explicit Pods build settings."
end
