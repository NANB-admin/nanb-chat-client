# Third-party licences

NANb Chat is licensed under GPL-3.0-only (see `LICENSE`). It includes or links the components below, each under its own licence.

## Native / non-Dart components

| Component | Version | Licence | Notes |
|---|---|---|---|
| Wire CoreCrypto (MLS) | 9.3.4 | GPL-3.0 | The reason this project is GPL-3.0. Fetched from <https://github.com/wireapp/core-crypto> releases, not copied into this repo. |
| Arti (Rust Tor client) | 0.43 | MIT OR Apache-2.0 | Built from `nanb-arti-ffi/`. Rust transitive dependencies are not yet inventoried (no `Cargo.lock`). |
| Inter | variable | OFL-1.1 | `nanb-mobile/assets/fonts/OFL-Inter.txt` |
| IBM Plex Mono | 4 weights | OFL-1.1 | `nanb-mobile/assets/fonts/OFL-IBMPlexMono.txt` |
| Roboto | Regular, Bold | Apache-2.0 | `LICENSES/Apache-2.0.txt` |
| Fluent Emoji (stickers) | 3 packs | MIT | `nanb-mobile/assets/stickers/LICENSE-FluentEmoji.txt` |

## Dart / Flutter packages (from `pubspec.lock`)

Licence is read from each package's own `LICENSE` file.

### MIT (35)

archive 4.0.9, audio_session 0.1.25, cupertino_icons 1.0.9, dart_webrtc 1.8.1, dio 5.9.2, dio_web_adapter 2.1.2, file_picker 8.3.7, flutter_launcher_icons 0.14.4, flutter_riverpod 2.6.1, flutter_webrtc 1.5.1, html 0.15.6, image 4.8.0, just_audio_platform_interface 4.6.0, just_audio_web 0.4.16, logger 2.7.0, mocktail 1.0.5, permission_handler 12.0.3, permission_handler_android 13.0.1, permission_handler_apple 9.4.9, permission_handler_html 0.1.3+5, permission_handler_platform_interface 4.3.0, permission_handler_windows 0.2.1, petitparser 7.0.2, pointycastle 3.9.1, posix 6.5.0, riverpod 2.6.1, socks5_proxy 1.0.6, sqflite_sqlcipher 3.4.0, state_notifier 1.0.0, synchronized 3.4.0+1, uuid 4.5.3, video_thumbnail 0.5.6, webrtc_interface 1.5.1, xml 6.6.1, yaml 3.1.3

### BSD-3 (116)

_flutterfire_internals 1.3.59, args 2.7.0, async 2.13.1, bip39 1.0.6, boolean_selector 2.1.2, characters 1.4.1, checked_yaml 2.0.4, cli_util 0.4.2, code_assets 1.0.0, collection 1.19.1, connectivity_plus 6.1.5, connectivity_plus_platform_interface 2.1.0, convert 3.1.2, cross_file 0.3.5+2, crypto 3.0.7, csslib 1.0.2, ffi 2.2.0, file 7.0.1, file_selector_linux 0.9.4, file_selector_macos 0.9.5, file_selector_platform_interface 2.7.0, file_selector_windows 0.9.3+5, firebase_core 3.15.2, firebase_core_platform_interface 6.0.3, firebase_core_web 2.24.1, firebase_messaging 15.2.10, firebase_messaging_platform_interface 4.6.10, firebase_messaging_web 3.10.10, fixnum 1.1.1, flutter_lints 6.0.0, flutter_local_notifications 17.2.4, flutter_local_notifications_linux 4.0.1, flutter_local_notifications_platform_interface 7.2.0, flutter_plugin_android_lifecycle 2.0.34, flutter_secure_storage 9.2.4, flutter_secure_storage_linux 1.2.3, flutter_secure_storage_macos 3.1.3, flutter_secure_storage_platform_interface 1.1.2, flutter_secure_storage_web 1.2.1, flutter_secure_storage_windows 3.1.2, gal 2.3.2, glob 2.1.3, go_router 14.8.1, hooks 1.0.3, http 1.6.0, http_parser 4.1.2, image_picker_for_web 3.1.1, image_picker_linux 0.2.2, image_picker_macos 0.2.2+1, image_picker_platform_interface 2.11.1, image_picker_windows 0.2.2, intl 0.20.2, jni 1.0.0, jni_flutter 1.0.1, js 0.6.7, json_annotation 4.12.0, leak_tracker 11.0.2, leak_tracker_flutter_testing 3.0.10, leak_tracker_testing 3.0.2, lints 6.1.0, local_auth 2.3.0, local_auth_android 1.0.56, local_auth_darwin 1.6.1, local_auth_platform_interface 1.1.0, local_auth_windows 1.0.11, logging 1.3.0, matcher 0.12.19, meta 1.18.0, mime 2.0.0, mobile_scanner 7.2.0, native_toolchain_c 0.17.6, objective_c 9.3.0, open_filex 4.7.0, package_config 2.2.0, package_info_plus 8.3.1, package_info_plus_platform_interface 3.2.1, path 1.9.1, path_provider 2.1.5, path_provider_android 2.3.1, path_provider_foundation 2.6.0, path_provider_linux 2.2.1, path_provider_platform_interface 2.1.2, path_provider_windows 2.3.0, platform 3.1.6, plugin_platform_interface 2.1.8, pub_semver 2.2.0, qr 3.0.2, qr_flutter 4.1.0, record_use 0.6.0, source_span 1.10.2, stack_trace 1.12.1, stream_channel 2.1.4, string_scanner 1.4.1, term_glyph 1.2.2, test_api 0.7.11, typed_data 1.4.0, url_launcher 6.3.2, url_launcher_android 6.3.32, url_launcher_ios 6.4.1, url_launcher_linux 3.2.2, url_launcher_macos 3.2.5, url_launcher_platform_interface 2.3.2, url_launcher_web 2.4.3, url_launcher_windows 3.1.5, vector_math 2.2.0, video_player 2.11.1, video_player_android 2.9.6, video_player_avfoundation 2.9.7, video_player_platform_interface 6.7.0, video_player_web 2.4.0, vm_service 15.2.0, web 1.1.1, web_socket 1.0.1, web_socket_channel 3.0.3, win32 5.15.0, xdg_directories 1.1.0

### BSD-2 (2)

sqflite_common 2.5.7, timezone 0.9.4

### Apache-2.0 (9)

clock 1.1.2, cryptography 2.9.0, fake_async 1.3.3, image_picker 1.2.2, image_picker_android 0.8.13+19, image_picker_ios 0.8.13+6, just_audio 0.9.46, material_color_utilities 0.13.0, rxdart 0.28.0

### MPL-2.0 (5)

dbus 0.7.12, flutter_sound 9.30.0, flutter_sound_platform_interface 9.30.0, flutter_sound_web 9.30.0, nm 0.5.0

### Unlicense (1)

hex 0.2.0

### Flutter SDK (BSD-3-Clause) (4)

flutter 0.0.0, flutter_test 0.0.0, flutter_web_plugins 0.0.0, sky_engine 0.0.0

### Local packages (this repo) (1)

nanb_crypto 1.0.0

MPL-2.0 packages are file-level copyleft and compatible with GPL-3.0.
