import 'package:flutter/foundation.dart';

/// Registers the licences of the bundled components that are not Dart packages
/// (so Flutter's own licence page does not list them): the native crypto and Tor
/// libraries, the bundled fonts and the sticker art. Dart packages are picked up
/// by Flutter automatically. Safe to call more than once.
bool _registered = false;

void registerOpenSourceNotices() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['Wire CoreCrypto'],
      'Wire CoreCrypto (MLS), version 9.3.4.\n'
      'https://github.com/wireapp/core-crypto\n\n'
      'Licensed under the GNU General Public License, version 3. This app is '
      'therefore distributed under the same licence; the full text is in the '
      'LICENSE file of the source repository.',
    );
    yield const LicenseEntryWithLineBreaks(
      ['Arti (Tor)'],
      'Arti, a Rust implementation of Tor, version 0.43.\n'
      'https://gitlab.torproject.org/tpo/core/arti\n\n'
      'Licensed under the MIT licence or the Apache License 2.0, at your option.',
    );
    yield const LicenseEntryWithLineBreaks(
      ['Inter', 'IBM Plex Mono'],
      'Inter (c) The Inter Project Authors, https://github.com/rsms/inter\n'
      'IBM Plex Mono (c) IBM Corp., https://github.com/IBM/plex\n\n'
      'Both are licensed under the SIL Open Font License 1.1. The full text is '
      'in nanb-mobile/assets/fonts/ of the source repository.',
    );
    yield const LicenseEntryWithLineBreaks(
      ['Roboto'],
      'Roboto Copyright 2011 Google Inc., https://github.com/googlefonts/roboto\n\n'
      'Licensed under the Apache License, Version 2.0.',
    );
    yield const LicenseEntryWithLineBreaks(
      ['Fluent Emoji'],
      'Fluent Emoji (c) Microsoft Corporation, '
      'https://github.com/microsoft/fluentui-emoji\n\n'
      'Licensed under the MIT licence.',
    );
  });
}
