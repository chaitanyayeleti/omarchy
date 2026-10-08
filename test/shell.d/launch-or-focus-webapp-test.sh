#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/bin"
HYPRCTL_LOG="$TMPDIR/hyprctl-log"
WEBAPP_LAUNCH_LOG="$TMPDIR/webapp-launch-log"

# hyprctl answers the client list from a fixture and records the focus dispatch,
# so the assertion is about which window the binding settled on.
cat >"$TMPDIR/bin/hyprctl" <<'SH'
#!/bin/bash
case "$1" in
  clients)
    cat "$HYPRCTL_CLIENTS"
    ;;
  dispatch)
    printf '%s\n' "$*" >>"$HYPRCTL_LOG"
    ;;
esac
SH

cat >"$TMPDIR/bin/omarchy-launch-webapp" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$WEBAPP_LAUNCH_LOG"
SH

chmod +x "$TMPDIR/bin/hyprctl" "$TMPDIR/bin/omarchy-launch-webapp"

# Window classes use the format Chromium gives --app windows: the browser name,
# the URL host, the path, then the profile. The first fixture is the collision
# from the report: an ordinary browser window whose active tab title contains
# "WhatsApp" sits beside the real web app window.
cat >"$TMPDIR/clients-whatsapp.json" <<'JSON'
[
  {"address": "0xbrowser", "class": "brave-browser", "title": "WhatsApp | Secure and Reliable Free Private Messaging and Calling"},
  {"address": "0xwhatsapp", "class": "brave-web.whatsapp.com__-Default", "title": "WhatsApp"}
]
JSON

cat >"$TMPDIR/clients-google.json" <<'JSON'
[
  {"address": "0xbrowser", "class": "brave-browser", "title": "Google Maps - Brave"},
  {"address": "0xmaps", "class": "brave-maps.google.com__-Default", "title": "Google Maps"},
  {"address": "0xphotos", "class": "brave-photos.google.com__-Default", "title": "Google Photos"}
]
JSON

cat >"$TMPDIR/clients-browser-only.json" <<'JSON'
[
  {"address": "0xbrowser", "class": "brave-browser", "title": "WhatsApp | Secure and Reliable Free Private Messaging and Calling"}
]
JSON

run_webapp() {
  : >"$HYPRCTL_LOG"
  : >"$WEBAPP_LAUNCH_LOG"

  PATH="$TMPDIR/bin:$ROOT/bin:$PATH" \
  OMARCHY_PATH="$ROOT" \
  HYPRCTL_LOG="$HYPRCTL_LOG" \
  HYPRCTL_CLIENTS="$1" \
  WEBAPP_LAUNCH_LOG="$WEBAPP_LAUNCH_LOG" \
    "$ROOT/bin/omarchy-launch-or-focus-webapp" "${@:2}"
}

run_or_focus() {
  : >"$HYPRCTL_LOG"
  : >"$WEBAPP_LAUNCH_LOG"

  PATH="$TMPDIR/bin:$ROOT/bin:$PATH" \
  OMARCHY_PATH="$ROOT" \
  HYPRCTL_LOG="$HYPRCTL_LOG" \
  HYPRCTL_CLIENTS="$HYPRCTL_CLIENTS" \
  WEBAPP_LAUNCH_LOG="$WEBAPP_LAUNCH_LOG" \
    "$ROOT/bin/omarchy-launch-or-focus" "$@"
}

# The web app window is open, and a browser tab title also says "WhatsApp". The
# web app window is the one to focus: the browser tab must not win a title tie.
run_webapp "$TMPDIR/clients-whatsapp.json" WhatsApp https://web.whatsapp.com/
grep -Fq 'address:0xwhatsapp' "$HYPRCTL_LOG" ||
  fail "the web app window is not the one focused"
! grep -Fq 'address:0xbrowser' "$HYPRCTL_LOG" ||
  fail "a browser tab whose title contains the description is focused instead of the web app"
[[ ! -s $WEBAPP_LAUNCH_LOG ]] ||
  fail "the web app is launched although its window already exists"
pass "a browser tab title cannot win against the web app's own window"

# With the web app window closed, the browser tab title must not stop a launch.
run_webapp "$TMPDIR/clients-browser-only.json" WhatsApp https://web.whatsapp.com/
grep -Fq 'https://web.whatsapp.com/' "$WEBAPP_LAUNCH_LOG" ||
  fail "the web app is not launched when only a lookalike browser tab exists"
! grep -Fq 'address:0xbrowser' "$HYPRCTL_LOG" ||
  fail "the lookalike browser tab is focused instead of launching the web app"
pass "a lookalike browser tab does not stop the web app from launching"

# The class pattern is the URL's host, so a second web app on a different
# Google host is neither matched nor shadowed.
run_webapp "$TMPDIR/clients-google.json" "Google Maps" https://maps.google.com/
grep -Fq 'address:0xmaps' "$HYPRCTL_LOG" ||
  fail "the Google Maps web app is not focused"
! grep -Fq 'address:0xphotos' "$HYPRCTL_LOG" ||
  fail "a web app on a different host with the same browser wins the match"
pass "the host in the URL picks the right web app window"

# Extra arguments after the URL still reach the launcher.
run_webapp "$TMPDIR/clients-browser-only.json" WhatsApp https://web.whatsapp.com/ --new-window
grep -Fq 'https://web.whatsapp.com/ --new-window' "$WEBAPP_LAUNCH_LOG" ||
  fail "arguments after the URL are dropped from the launch"
pass "flags after the URL are passed through to the web app launcher"

# omarchy-launch-or-focus itself keeps its historical class-or-title matching
# for callers that are not web apps.
HYPRCTL_CLIENTS="$TMPDIR/clients-browser-only.json" run_or_focus WhatsApp
grep -Fq 'address:0xbrowser' "$HYPRCTL_LOG" ||
  fail "a plain pattern no longer matches a window title"
pass "plain patterns still match window titles"

# --class is the mode the web app command relies on: class only, never titles.
HYPRCTL_CLIENTS="$TMPDIR/clients-whatsapp.json" run_or_focus --class '-web\.whatsapp\.com'
grep -Fq 'address:0xwhatsapp' "$HYPRCTL_LOG" ||
  fail "--class does not match the window class"
! grep -Fq 'address:0xbrowser' "$HYPRCTL_LOG" ||
  fail "--class falls back to matching titles"
pass "--class matches the window class alone"
