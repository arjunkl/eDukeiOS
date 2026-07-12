#!/usr/bin/env ruby
require "xcodeproj"
require "pathname"

project_path = File.expand_path("../EDuke32.xcodeproj", __dir__)
project = Xcodeproj::Project.open(project_path)
duke = project.targets.find { |target| target.name == "EDuke32-iOS" }
abort "EDuke32-iOS target not found" unless duke

if project.targets.any? { |target| target.name == "VoidSW-iOS" }
  puts "VoidSW-iOS target already exists"
  exit 0
end

voidsw = project.new_target(:application, "VoidSW-iOS", :ios, "15.0")

voidsw.build_configurations.each do |configuration|
  template = duke.build_configurations.find { |item| item.name == configuration.name }
  configuration.build_settings.clear
  template.build_settings.each { |key, value| configuration.build_settings[key] = Marshal.load(Marshal.dump(value)) }

  configuration.build_settings["PRODUCT_NAME"] = "VoidSW-iOS"
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.arjunkl.eDukeiOS.voidsw"
  configuration.build_settings["INFOPLIST_FILE"] = "iOS/VoidSW-Info.plist"
  configuration.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
  configuration.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"

  headers = Array(configuration.build_settings["HEADER_SEARCH_PATHS"])
  headers.unshift("$(SRCROOT)/../../source/sw/src")
  configuration.build_settings["HEADER_SEARCH_PATHS"] = headers.uniq
end

duke.frameworks_build_phase.files.each do |build_file|
  next unless build_file.file_ref
  added = voidsw.frameworks_build_phase.add_file_reference(build_file.file_ref, true)
  added.settings = Marshal.load(Marshal.dump(build_file.settings)) if build_file.settings
end

duke.resources_build_phase.files.each do |build_file|
  next unless build_file.file_ref
  added = voidsw.resources_build_phase.add_file_reference(build_file.file_ref, true)
  added.settings = Marshal.load(Marshal.dump(build_file.settings)) if build_file.settings
end

duke.dependencies.each do |dependency|
  voidsw.add_dependency(dependency.target) if dependency.target
end

source_root = File.expand_path("../../../source/sw/src", __dir__)
excluded = %w[
  bldscript.cpp
  brooms.cpp
  jbhlp.cpp
  jnstub.cpp
  startgtk.game.cpp
  startwin.game.cpp
]

group = project.main_group.find_subpath("VoidSW iOS", true)
Dir.glob(File.join(source_root, "*.cpp")).sort.each do |source|
  next if excluded.include?(File.basename(source))
  relative = Pathname.new(source).relative_path_from(Pathname.new(File.dirname(project_path))).to_s
  voidsw.source_build_phase.add_file_reference(group.new_file(relative), true)
end

controls = File.expand_path("VoidSWControls.mm", __dir__)
controls_relative = Pathname.new(controls).relative_path_from(Pathname.new(File.dirname(project_path))).to_s
voidsw.source_build_phase.add_file_reference(group.new_file(controls_relative), true)

project.save
puts "Configured VoidSW-iOS with #{voidsw.source_build_phase.files.count} source files"
