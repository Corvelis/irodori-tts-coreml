#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/archive-ios.sh --team TEAM_ID --bundle-id BUNDLE_ID [options]
  --version VERSION    Marketing version (default: 0.2.1)
  --build NUMBER       Build number (default: 3; increase for every upload)
  --output PATH        Archive path (default: dist/IrodoriCoreML.xcarchive)
  --help               Show this help
Creates an iOS Release archive. Does not upload or submit it.
EOF
}
team=''
bundle=''
version='0.2.1'
build='3'
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/dist/IrodoriCoreML.xcarchive"
while (($#)); do
  case "$1" in
    --help) usage; exit 0 ;;
    --team|--bundle-id|--version|--build|--output)
      if (($# < 2)); then printf 'Missing value for %s\n' "$1" >&2; exit 2; fi
      case "$1" in
        --team) team="$2" ;; --bundle-id) bundle="$2" ;; --version) version="$2" ;;
        --build) build="$2" ;; --output) output="$2" ;;
      esac
      shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ || ! "$bundle" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ || "$bundle" == org.example.* ]]; then
  printf 'Specify your 10-character Team ID and a unique, non-example bundle ID.\n' >&2; exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ || ! "$build" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Invalid version or build number.\n' >&2; exit 2
fi
if [[ -e "$output" ]]; then printf 'Archive already exists; choose a new --output path.\n' >&2; exit 2; fi
mkdir -p "$(dirname "$output")"
xcodebuild -project "$root/Examples/IrodoriSamples.xcodeproj" -scheme IrodoriiOS \
  -configuration Release -destination 'generic/platform=iOS' -archivePath "$output" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" PRODUCT_BUNDLE_IDENTIFIER="$bundle" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" archive
printf 'Archive created: %s\nOpen it in Xcode Organizer to validate and upload.\n' "$output"
