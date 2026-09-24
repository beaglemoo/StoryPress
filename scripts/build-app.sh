#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

configuration="${CONFIGURATION:-Release}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/build/DerivedData}"
output_directory="${OUTPUT_DIRECTORY:-$repo_root/dist}"
app_name="StoryPress"

if [[ -z "$output_directory" || "$output_directory" == "/" || "$output_directory" == "$repo_root" ]]; then
    printf '%s\n' "OUTPUT_DIRECTORY must be a dedicated output folder." >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    printf '%s\n' "xcodegen is required. Install it with: brew install xcodegen" >&2
    exit 1
fi

xcodegen generate --spec project.yml

xcodebuild_args=(
    -project "$app_name.xcodeproj"
    -scheme "$app_name"
    -configuration "$configuration"
    -destination "platform=macOS"
    -derivedDataPath "$derived_data_path"
    "ARCHS=arm64 x86_64"
    "ONLY_ACTIVE_ARCH=NO"
    CODE_SIGN_STYLE=Manual
)

if [[ -n "${STORYPRESS_SIGNING_IDENTITY:-}" ]]; then
    xcodebuild_args+=("CODE_SIGNING_ALLOWED=YES" "CODE_SIGN_IDENTITY=$STORYPRESS_SIGNING_IDENTITY")
    if [[ -n "${STORYPRESS_TEAM_ID:-}" ]]; then
        xcodebuild_args+=("DEVELOPMENT_TEAM=$STORYPRESS_TEAM_ID")
    fi
else
    xcodebuild_args+=("CODE_SIGNING_ALLOWED=NO")
fi

xcodebuild "${xcodebuild_args[@]}" build

built_app="$derived_data_path/Build/Products/$configuration/$app_name.app"
if [[ ! -d "$built_app" ]]; then
    printf '%s\n' "Build completed without the expected app bundle: $built_app" >&2
    exit 1
fi

mkdir -p "$output_directory"
packaged_app="$output_directory/$app_name.app"
rm -rf "$packaged_app"
/usr/bin/ditto "$built_app" "$packaged_app"

archive_name="$app_name-macos.zip"
archive_path="$output_directory/$archive_name"
rm -f "$archive_path"

if [[ -n "${STORYPRESS_SIGNING_IDENTITY:-}" ]]; then
    codesign --verify --deep --strict --verbose=2 "$packaged_app"
fi

if [[ -n "${STORYPRESS_NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${STORYPRESS_SIGNING_IDENTITY:-}" ]]; then
        printf '%s\n' "Notarization requires STORYPRESS_SIGNING_IDENTITY to be set." >&2
        exit 1
    fi
    /usr/bin/ditto -c -k --keepParent "$packaged_app" "$archive_path"
    xcrun notarytool submit "$archive_path" --keychain-profile "$STORYPRESS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$packaged_app"
    xcrun stapler validate "$packaged_app"
    rm -f "$archive_path"
fi

/usr/bin/ditto -c -k --keepParent "$packaged_app" "$archive_path"
printf 'App bundle: %s\nArchive: %s\n' "$packaged_app" "$archive_path"
