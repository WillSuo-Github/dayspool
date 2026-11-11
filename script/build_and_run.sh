#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
repo="$(pwd -P)"
mode="${1:-run}"
case "$mode" in run|--build-only|--test|--debug|--logs|--telemetry|--verify) ;; *) echo "Unknown option: $mode" >&2; exit 2 ;; esac

key="$(printf '%s' "$repo" | shasum -a 256 | cut -c 1-12)"
base="/Volumes/T5/Codex"
if [[ -d "$base" && -w "$base" ]]; then
  derived="$base/DerivedData/DaySpool-$key"
  isolated="$base/DerivedData/Isolated"
else
  derived="$HOME/Library/Developer/Xcode/DerivedData"
  isolated="$derived/Codex-Isolated"
fi
args=(-project DaySpool.xcodeproj -scheme DaySpool -configuration Debug -destination 'platform=macOS')
action=build
if [[ "$mode" == --test ]]; then action=test; fi

path_args=()
if [[ "$derived" == /Volumes/* ]]; then path_args=(-derivedDataPath "$derived"); fi
if [[ "$mode" != --test && "$mode" != --build-only ]]; then
  pkill -x DaySpool >/dev/null 2>&1 || true
fi
if result="$(xcodebuild "${args[@]}" "${path_args[@]}" "$action" -quiet 2>&1)"; then
  [[ -z "$result" ]] || printf '%s\n' "$result"
elif [[ "$result" == *build.db* && "$result" == *locked* ]]; then
  path_args=(-derivedDataPath "$isolated/DaySpool-$key-$(uuidgen)")
  xcodebuild "${args[@]}" "${path_args[@]}" "$action" -quiet
else
  printf '%s\n' "$result" >&2
  exit 1
fi
if [[ "$mode" == --test || "$mode" == --build-only ]]; then exit 0; fi

product_dir="$(xcodebuild "${args[@]}" "${path_args[@]}" -showBuildSettings | awk '/^[[:space:]]+TARGET_BUILD_DIR = / && !seen++ { sub(/^[^=]*= /, ""); print }')"
bundle="$product_dir/DaySpool.app"
test -x "$bundle/Contents/MacOS/DaySpool"
if [[ "$mode" == --debug ]]; then exec lldb -- "$bundle/Contents/MacOS/DaySpool"; fi
/usr/bin/open -n "$bundle"
case "$mode" in
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "DaySpool"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.willsuo.dayspool"' ;;
  --verify)
    for _ in {1..20}; do
      if pgrep -x DaySpool >/dev/null; then exit 0; fi
      sleep 0.25
    done
    exit 1 ;;
esac
