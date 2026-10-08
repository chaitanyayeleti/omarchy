#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
state_home="$test_tmp/state"
runtime_dir="$test_tmp/runtime"
mkdir -p "$mock_bin" "$state_home" "$runtime_dir"

cat >"$mock_bin/ddcutil" <<'SH'
#!/bin/bash

if [[ $* == *" detect --brief"* ]]; then
  printf '   I2C bus:             /dev/i2c-7\n'
  printf '   DRM connector:       card1-DP-1\n'
elif [[ $* == *" getvcp 10 "* ]]; then
  printf 'VCP 10 C 40 80\n'
fi
SH

chmod +x "$mock_bin/ddcutil"

state_cache="$state_home/omarchy/omarchy-brightness-display-ddc/DP-1.bus"
runtime_cache="$runtime_dir/omarchy-brightness-display-ddc/DP-1.bus"

# Without a session runtime dir the cache falls back to the user's state
# directory, which is private, not to a fixed name in world-writable /tmp.
brightness=$(
  HOME="$test_tmp/home" XDG_STATE_HOME="$state_home" XDG_RUNTIME_DIR= \
    PATH="$mock_bin:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-brightness-display-ddc" DP-1
)
[[ $brightness == "50" ]] || fail "the fallback cache still serves the brightness" "actual: $brightness"
[[ -f $state_cache ]] || fail "the DDC cache falls back to the state directory without a session runtime dir"
[[ $(cut -d' ' -f1,2 "$state_cache") == "7 80" ]] || fail "the fallback cache keeps the detected bus and range"
[[ $(stat -c '%a' "$state_home/omarchy/omarchy-brightness-display-ddc") == "700" ]] || fail "the fallback cache directory is private"
pass "the DDC cache falls back to a private state directory without a session runtime dir"

# The session runtime dir still wins when it is there.
rm -f "$state_cache"
HOME="$test_tmp/home" XDG_STATE_HOME="$state_home" XDG_RUNTIME_DIR="$runtime_dir" \
  PATH="$mock_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-brightness-display-ddc" DP-1 >/dev/null
[[ -f $runtime_cache ]] || fail "the session runtime dir still holds the cache when it is set"
[[ ! -e $state_cache ]] || fail "the state directory is not touched when a session runtime dir is set"
pass "the session runtime dir takes precedence over the state directory"
