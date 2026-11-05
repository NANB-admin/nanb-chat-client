# Idempotently adds the NanbNotificationService app-extension target to
# Runner.xcodeproj and embeds it into the Runner app.
#
# Why a script instead of committing the target in project.pbxproj: this repo is
# developed on Windows with no Xcode, so hand-editing the pbxproj to add a whole
# target (build configs, phases, an Embed-App-Extensions copy phase) is very
# error-prone and unvalidatable locally. The macOS CI runner has the `xcodeproj`
# gem (it ships with the CocoaPods toolchain), so it synthesises the target
# deterministically before `flutter build`. Re-running is a no-op.
#
# Run from nanb-mobile/ios:  ruby ci/add_nse_target.rb

require 'xcodeproj'

EXT_NAME = 'NanbNotificationService'.freeze
BUNDLE_ID = 'us.nanb.chat.NanbNotificationService'.freeze
DEPLOYMENT_TARGET = '15.0'.freeze

# App Store release signing (opt-in via env). The unsigned dev/sideload build
# (ios.yml) leaves NANB_RELEASE_SIGNING unset, so the extension + Runner stay
# signing-disabled and are re-signed later by zsign. The App Store release build
# (ios-release.yml) sets NANB_RELEASE_SIGNING=1 plus the team id + profile names
# (read out of the installed .mobileprovision files by the workflow), so BOTH
# the Runner app and the NSE archive with manual "Apple Distribution" signing
# against their OWN App Store provisioning profile.
RELEASE_SIGNING = ENV['NANB_RELEASE_SIGNING'] == '1'
if RELEASE_SIGNING
  TEAM_ID = ENV.fetch('NANB_TEAM_ID')
  APP_PROFILE = ENV.fetch('NANB_APP_PROFILE_NAME')
  NSE_PROFILE = ENV.fetch('NANB_NSE_PROFILE_NAME')
  SIGN_IDENTITY = ENV.fetch('NANB_SIGN_IDENTITY', 'Apple Distribution')
end

# Apply manual App Store signing to one target build configuration. Sets both
# the plain and the iphoneos-scoped CODE_SIGN_IDENTITY so a project-level
# `CODE_SIGN_IDENTITY[sdk=iphoneos*] = "iPhone Developer"` can't win by being the
# more-specific key.
def apply_appstore_signing(config, team_id, profile_name, identity)
  bs = config.build_settings
  bs['CODE_SIGN_STYLE'] = 'Manual'
  bs['DEVELOPMENT_TEAM'] = team_id
  bs['PROVISIONING_PROFILE_SPECIFIER'] = profile_name
  bs['CODE_SIGN_IDENTITY'] = identity
  bs['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = identity
  bs['CODE_SIGNING_ALLOWED'] = 'YES'
  bs['CODE_SIGNING_REQUIRED'] = 'YES'
  bs.delete('PROVISIONING_PROFILE') # drop any stale legacy UUID key
end

# App version, read from pubspec.yaml (format: "version: <name>+<build>"). The
# embedded extension's CFBundleShortVersionString / CFBundleVersion MUST match
# the containing app or App Store validation rejects the upload, so derive them
# here rather than hardcoding. The NSE target has no Flutter xcconfig in scope,
# so $(FLUTTER_BUILD_NAME)/$(FLUTTER_BUILD_NUMBER) wouldn't resolve for it.
pubspec_version = File.read(File.join('..', 'pubspec.yaml'))[/^version:\s*(.+)$/, 1]
raise '[add_nse_target] no "version:" line in ../pubspec.yaml' if pubspec_version.nil?
app_marketing_version, app_project_version = pubspec_version.strip.split('+', 2)
raise '[add_nse_target] pubspec version must be "<name>+<build>"' if app_project_version.nil?

project_path = 'Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

runner = project.targets.find { |t| t.name == 'Runner' }
raise '[add_nse_target] Runner target not found' if runner.nil?

# Ensure the Runner target compiles the channel sources that were added on
# Windows but aren't reliably in the committed pbxproj — hand-editing the
# pbxproj without Xcode is error-prone and unvalidatable locally, so the
# xcodeproj gem wires them deterministically here. AppDelegate references each,
# so a missing one fails the Runner build. Idempotent: any file already in the
# Sources phase (e.g. one that WAS hand-added to the pbxproj) is skipped, so
# this never double-adds (which would be a "Multiple commands produce" error).
runner_extra_sources = [
  'SharedStoreChannel.swift', # mirrors the NSE's inputs into the App Group
  'IncomingShareChannel.swift', # reads OS-share payloads out of the App Group
  'SecureScreenChannel.swift', # FLAG_SECURE-equivalent screenshot block + detect
  'CallWindowChannel.swift', # keep-screen-awake during a call (Auto-Lock disable)
  'CallKitCenter.swift', # CXProvider: the system incoming-call UI
  'VoipPushChannel.swift', # PushKit receiver + the Dart bridge (uses CallKitCenter)
  # MLS bridge (CoreCrypto). These carry real content now (previously #if false
  # stubs), so NanbCryptoChannel.swift references their types (NanbMlsError,
  # MlsClientHolder, CapturingMlsTransport, Hkdf) — they MUST be compiled into the
  # Runner target or the build fails "Cannot find <type> in scope".
  'MlsClientHolder.swift', # CoreCrypto client + encrypted store singleton
  'CapturingMlsTransport.swift', # captures CommitBundles from add/remove
  'MlsExceptions.swift', # maps CoreCrypto errors to channel codes + NanbMlsError
  'Hkdf.swift', # CryptoKit HKDF for the store key (used by MlsClientHolder)
  'CoreCryptoKeychainSalt.swift', # keychain half of the store (SQLCipher salt)
]
runner_extra_sources.each do |basename|
  next if runner.source_build_phase.files.any? { |bf| bf.file_ref&.display_name == basename }
  ref = project.main_group.new_reference("Runner/#{basename}")
  runner.add_file_references([ref])
  puts "[add_nse_target] added #{basename} to the Runner target."
end

# App Store release: flip the Runner target from the committed Automatic /
# "iPhone Developer" signing to manual "Apple Distribution" against the app's own
# App Store profile. Done per-target (not via a global xcodebuild flag) because
# the NSE needs a DIFFERENT profile — one command-line override can't serve both.
# Debug is left untouched for local dev. Runs before the NSE early-exit so a
# re-run still re-applies it.
if RELEASE_SIGNING
  runner.build_configurations.each do |config|
    next if config.name == 'Debug'
    apply_appstore_signing(config, TEAM_ID, APP_PROFILE, SIGN_IDENTITY)
  end
  puts "[add_nse_target] Runner: manual App Store signing (profile '#{APP_PROFILE}')."
end

if project.targets.any? { |t| t.name == EXT_NAME }
  project.save
  puts "[add_nse_target] #{EXT_NAME} target already present; nothing more to do."
  exit 0
end

# 1. The app-extension target (Swift).
ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

# 2. Mirror every project-level configuration (Flutter adds Profile beyond the
#    default Debug/Release) so building any config doesn't fail for the extension.
project_config_names = project.build_configurations.map(&:name)
existing = ext.build_configurations.map(&:name)
(project_config_names - existing).each { |name| ext.add_build_configuration(name, :release) }

# 3. Source files: a group whose path points at ios/NanbNotificationService.
group = project.main_group.find_subpath(EXT_NAME, true)
group.set_source_tree('SOURCE_ROOT')
group.set_path(EXT_NAME)
swift_files = Dir.glob(File.join(EXT_NAME, '*.swift')).sort
raise "[add_nse_target] no Swift files under #{EXT_NAME}/" if swift_files.empty?
refs = swift_files.map { |f| group.new_reference(File.basename(f)) }
ext.add_file_references(refs)

# 4. Build settings. Signing depends on the build: the unsigned dev build
#    disables it (zsign re-signs the .appex later); the App Store release build
#    signs it with the NSE's own App Store profile.
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
    # Signed App Store build: the extension needs its OWN App Store profile.
    apply_appstore_signing(config, TEAM_ID, NSE_PROFILE, SIGN_IDENTITY)
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

# 5. Embed the built .appex into Runner.app/PlugIns and make Runner depend on it.
embed = runner.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
build_file = embed.add_file_reference(ext.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
runner.add_dependency(ext)

# 6. The Embed phase MUST run BEFORE Flutter's "Thin Binary" script phase, or
# Xcode reports "Cycle inside Runner; building could produce unreliable
# results." (flutter/flutter#135056). new_copy_files_build_phase appends to the
# end (after Thin Binary), so move it ahead of Thin Binary. ObjectList subclasses
# Array and keeps referrer integrity across delete/insert.
phases = runner.build_phases
phases.delete(embed)
thin_index = phases.index { |p| p.display_name == 'Thin Binary' }
phases.insert(thin_index || phases.size, embed)

project.save
puts "[add_nse_target] added #{EXT_NAME} target (#{swift_files.size} Swift files) + embed phase."
