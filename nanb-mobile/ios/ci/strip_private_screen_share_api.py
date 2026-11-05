"""Remove the private-API call from flutter_webrtc's iOS screen-share code.

App Review rejected build 38 under guideline 2.5.1: the binary referenced the
non-public selector `RPSystemBroadcastPickerView.buttonPressed:`. It comes from
flutter_webrtc (FlutterRTCDesktopCapturer.m, getDisplayMedia), which fires that
selector through NSSelectorFromString to pop the broadcast picker. This app
never screen-shares, so the call is dead code for us - we only need it gone from
the binary.

Run after `flutter pub get` and before `flutter build ipa`. Idempotent.

usage: python3 strip_private_screen_share_api.py [PLUGIN_DIR]
  PLUGIN_DIR defaults to the flutter_webrtc dir named in
  .dart_tool/package_config.json (run from the Flutter project root).
"""
import json
import pathlib
import re
import sys
from urllib.parse import urlparse
from urllib.request import url2pathname

PRIVATE_SELECTOR = "buttonPressed:"

# `SEL selector = NSSelectorFromString(@"buttonPressed:");` through the
# `performSelector` guard that follows it.
CALL = re.compile(
    r'[ \t]*SEL\s+selector\s*=\s*NSSelectorFromString\(@"buttonPressed:"\);\s*'
    r"if\s*\(\[picker respondsToSelector:selector\]\)\s*\{\s*"
    r"\[picker performSelector:selector withObject:nil\];\s*\}"
)


def plugin_dir():
    if len(sys.argv) > 1:
        return pathlib.Path(sys.argv[1])
    config = json.loads(pathlib.Path(".dart_tool/package_config.json").read_text())
    for package in config["packages"]:
        if package["name"] == "flutter_webrtc":
            root = package["rootUri"]
            base = pathlib.Path(".dart_tool").resolve()
            if root.startswith("file://"):
                return pathlib.Path(url2pathname(urlparse(root).path))
            return (base / root).resolve()
    sys.exit("flutter_webrtc not found in package_config.json")


def patch(path):
    text = path.read_text(encoding="utf-8")
    if PRIVATE_SELECTOR not in text:
        print(f"already clean: {path}")
        return
    patched, count = CALL.subn("", text)
    if count != 1 or PRIVATE_SELECTOR in patched:
        sys.exit(f"could not strip {PRIVATE_SELECTOR} from {path} (matches: {count})")
    path.write_text(patched, encoding="utf-8")
    print(f"stripped private selector: {path}")


def main():
    root = plugin_dir()
    # The iOS pod compiles one of these depending on the plugin version.
    candidates = [
        root / "ios" / "Classes" / "FlutterRTCDesktopCapturer.m",
        root / "common" / "darwin" / "Classes" / "FlutterRTCDesktopCapturer.m",
    ]
    found = [c for c in candidates if c.is_file()]
    if not found:
        sys.exit(f"FlutterRTCDesktopCapturer.m not found under {root}")
    for path in found:
        patch(path)


main()
