#!/usr/bin/env ruby
# Makes the Flutter xcconfig files inherit the CocoaPods build settings
# explicitly. Xcode Cloud can otherwise compile GeneratedPluginRegistrant.m
# without the Pods framework/module search paths.

repo_root = ENV["REPO_ROOT"] || File.expand_path("../..", __dir__)
ios_dir = File.join(repo_root, "ios")
pods_support_dir = File.join(
  ios_dir,
  "Pods",
  "Target Support Files",
  "Pods-Runner"
)

BEGIN_MARKER = "// BEGIN XCODE CLOUD PODS SETTINGS"
END_MARKER = "// END XCODE CLOUD PODS SETTINGS"

SETTINGS_TO_COPY = %w[
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
].freeze

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

def without_generated_block(content)
  skipping = false
  output = []

  content.lines.each do |line|
    stripped = line.strip

    if stripped == BEGIN_MARKER
      skipping = true
      next
    end

    if stripped == END_MARKER
      skipping = false
      next
    end

    output << line unless skipping
  end

  "#{output.join.rstrip}\n"
end

def patch_flutter_xcconfig(ios_dir, pods_support_dir, flutter_config, pods_config)
  flutter_path = File.join(ios_dir, "Flutter", "#{flutter_config}.xcconfig")
  pods_path = File.join(pods_support_dir, "Pods-Runner.#{pods_config}.xcconfig")

  abort "Missing #{flutter_path}" unless File.exist?(flutter_path)
  abort "Missing #{pods_path}" unless File.exist?(pods_path)

  pods_settings = parse_xcconfig(pods_path)
  generated_settings = []
  SETTINGS_TO_COPY.each do |key|
    value = pods_settings[key]
    generated_settings << "#{key} = #{value}" if value && !value.empty?
  end

  patched = without_generated_block(File.read(flutter_path))
  patched << "\n"
  patched << BEGIN_MARKER << "\n"
  patched << generated_settings.join("\n") << "\n"
  patched << "CLANG_ENABLE_MODULES = YES\n"
  patched << END_MARKER << "\n"

  if ENV["DRY_RUN"] == "1"
    puts "Dry run: would patch #{flutter_path} from #{pods_path}"
  else
    File.write(flutter_path, patched)
    puts "Patched #{flutter_path} with Pods settings from #{pods_path}"
  end
end

patch_flutter_xcconfig(ios_dir, pods_support_dir, "Debug", "debug")
patch_flutter_xcconfig(ios_dir, pods_support_dir, "Release", "release")
