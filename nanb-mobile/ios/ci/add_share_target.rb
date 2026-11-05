# Idempotently adds the NanbShareExtension app-extension target (the "Chat"
# entry in the iOS share sheet) to Runner.xcodeproj and embeds it into the app.
#
# Same rationale as ci/add_nse_target.rb: this repo is developed on Windows with
# no Xcode, so hand-editing project.pbxproj to add a whole target is error-prone
# and unvalidatable locally. The macOS CI runner has the `xcodeproj` gem, so it
# synthesises the target deterministically before `flutter build`. Re-running is
# a no-op.
#
# Run from nanb-mobile/ios (AFTER add_nse_target.rb, whose run creates the
# shared "Embed App Extensions" phase this script reuses):
#   ruby ci/add_share_target.rb

require 'xcodeproj'

EXT_NAME = 'NanbShareExtension'.freeze
BUNDLE_ID = 'us.nanb.chat.NanbShareExtension'.freeze
DEPLOYMENT_TARGET = '15.0'.freeze
EMBED_PHASE_NAME = 'Embed App Extensions'.freeze

# App Store release signing (opt-in via env), mirroring add_nse_target.rb. The
# unsigned dev/sideload build leaves NANB_RELEASE_SIGNING unset, so the
# extension stays signing-disabled and is re-signed later by zsign.
RELEASE_SIGNING = ENV['NANB_RELEASE_SIGNING'] == '1'
if RELEASE_SIGNING
  TEAM_ID = ENV.fetch('NANB_TEAM_ID')
  SHARE_PROFILE = ENV.fetch('NANB_SHARE_PROFILE_NAME')
  SIGN_IDENTITY = ENV.fetch('NANB_SIGN_IDENTITY', 'Apple Distribution')
end

# The embedded extension's version keys MUST match the containing app or App
# Store validation rejects the upload. Derived from pubspec (the target has no
# Flutter xcconfig in scope, so $(FLUTTER_BUILD_NAME) wouldn't resolve for it).
pubspec_version = File.read(File.join('..', 'pubspec.yaml'))[/^version:\s*(.+)$/, 1]
raise '[add_share_target] no "version:" line in ../pubspec.yaml' if pubspec_version.nil?
app_marketing_version, app_project_version = pubspec_version.strip.split('+', 2)
raise '[add_share_target] pubspec version must be "<name>+<build>"' if app_project_version.nil?

project = Xcodeproj::Project.open('Runner.xcodeproj')

runner = project.targets.find { |t| t.name == 'Runner' }
raise '[add_share_target] Runner target not found' if runner.nil?

if project.targets.any? { |t| t.name == EXT_NAME }
  project.save
  puts "[add_share_target] #{EXT_NAME} target already present; nothing more to do."
  exit 0
end

# 1. The app-extension target (Swift).
ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

# 2. Mirror every project-level configuration (Flutter adds Profile beyond the
#    default Debug/Release) so building any config doesn't fail for the extension.
project_config_names = project.build_configurations.map(&:name)
existing = ext.build_configurations.map(&:name)
(project_config_names - existing).each { |name| ext.add_build_configuration(name, :release) }

# 3. Source files: a group whose path points at ios/NanbShareExtension.
group = project.main_group.find_subpath(EXT_NAME, true)
group.set_source_tree('SOURCE_ROOT')
group.set_path(EXT_NAME)
swift_files = Dir.glob(File.join(EXT_NAME, '*.swift')).sort
raise "[add_share_target] no Swift files under #{EXT_NAME}/" if swift_files.empty?
refs = swift_files.map { |f| group.new_reference(File.basename(f)) }
ext.add_file_references(refs)

# 4. Build settings.
ext.build_configurations.each do |config|
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  bs['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  bs['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  bs['SWIFT_VERSION'] = '5.0'
  # iPhone-only ('1'): must match the Runner app target, or App Store validation
  # rejects the bundle for an extension that claims a wider device family than
  # its host app. Widening to '1,2' means the listing needs iPad screenshots.
  bs['TARGETED_DEVICE_FAMILY'] = '1'
  bs['CURRENT_PROJECT_VERSION'] = app_project_version
  bs['MARKETING_VERSION'] = app_marketing_version
  bs['PRODUCT_NAME'] = '$(TARGET_NAME)'
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['SKIP_INSTALL'] = 'YES'
  if RELEASE_SIGNING
    bs['CODE_SIGN_STYLE'] = 'Manual'
    bs['DEVELOPMENT_TEAM'] = TEAM_ID
    bs['PROVISIONING_PROFILE_SPECIFIER'] = SHARE_PROFILE
    bs['CODE_SIGN_IDENTITY'] = SIGN_IDENTITY
    bs['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = SIGN_IDENTITY
    bs['CODE_SIGNING_ALLOWED'] = 'YES'
    bs['CODE_SIGNING_REQUIRED'] = 'YES'
    bs.delete('PROVISIONING_PROFILE')
  else
    bs['CODE_SIGNING_ALLOWED'] = 'NO'
    bs['CODE_SIGNING_REQUIRED'] = 'NO'
    bs['CODE_SIGN_STYLE'] = 'Manual'
    bs['CODE_SIGN_IDENTITY'] = ''
    bs['DEVELOPMENT_TEAM'] = ''
  end
  bs['LD_RUNPATH_SEARCH_PATHS'] =
    ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end

# 5. Embed the built .appex into Runner.app/PlugIns. REUSE the copy phase
#    add_nse_target.rb already created — a second "Embed App Extensions" phase
#    would leave the NSE and the share extension in separate phases, which Xcode
#    tolerates but makes the ordering fix below ambiguous.
embed = runner.copy_files_build_phases.find { |p| p.display_name == EMBED_PHASE_NAME }
if embed.nil?
  embed = runner.new_copy_files_build_phase(EMBED_PHASE_NAME)
  embed.symbol_dst_subfolder_spec = :plug_ins
end
build_file = embed.add_file_reference(ext.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
runner.add_dependency(ext)

# 6. The Embed phase MUST run BEFORE Flutter's "Thin Binary" script phase or
#    Xcode reports "Cycle inside Runner" (flutter/flutter#135056). Already true
#    when we reused the NSE's phase; only a freshly created one needs moving.
phases = runner.build_phases
thin_index = phases.index { |p| p.display_name == 'Thin Binary' }
embed_index = phases.index(embed)
if thin_index && embed_index && embed_index > thin_index
  phases.delete(embed)
  phases.insert(thin_index, embed)
end

project.save
puts "[add_share_target] added #{EXT_NAME} target (#{swift_files.size} Swift files) + embed phase."
