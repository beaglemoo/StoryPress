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
    xcodebuild_args+=(
        "CODE_SIGNING_ALLOWED=YES"
        "CODE_SIGN_IDENTITY=$STORYPRESS_SIGNING_IDENTITY"
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
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

    if ! get_task_allow="$(
        codesign -d --entitlements :- "$packaged_app" 2>/dev/null |
            /usr/bin/python3 -c 'import plistlib, sys; value = plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.get-task-allow"); print("" if value is None else str(value).lower() if isinstance(value, bool) else "unexpected")'
    )"; then
        printf '%s\n' "Could not read the signed app entitlements." >&2
        exit 1
    fi
    if [[ -n "$get_task_allow" && "$get_task_allow" != "false" ]]; then
        printf 'The signed app has unexpected com.apple.security.get-task-allow=%s.\n' "$get_task_allow" >&2
        exit 1
    fi

    signature_details="$(codesign -dv --verbose=4 "$packaged_app" 2>&1)"
    timestamp="$(printf '%s\n' "$signature_details" | sed -n 's/^Timestamp=//p' | head -n 1)"
    if [[ -z "$timestamp" || "$timestamp" == "none" ]]; then
        printf '%s\n' "The signed app has no secure code-signing timestamp." >&2
        exit 1
    fi
fi

if [[ -n "${STORYPRESS_NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${STORYPRESS_SIGNING_IDENTITY:-}" ]]; then
        printf '%s\n' "Notarization requires STORYPRESS_SIGNING_IDENTITY to be set." >&2
        exit 1
    fi
    /usr/bin/ditto -c -k --keepParent "$packaged_app" "$archive_path"
    notary_receipt="$repo_root/build/$app_name-notary-submission.json"
    mkdir -p "$(dirname "$notary_receipt")"
    if ! xcrun notarytool submit "$archive_path" --keychain-profile "$STORYPRESS_NOTARY_PROFILE" --wait --output-format json >"$notary_receipt"; then
        rm -f "$archive_path"
        printf 'Notarization submission failed. Review %s for the submission receipt.\n' "build/$app_name-notary-submission.json" >&2
        exit 1
    fi
    notary_status="$(/usr/bin/plutil -extract status raw -o - "$notary_receipt" 2>/dev/null || true)"
    if [[ "$notary_status" != "Accepted" ]]; then
        rm -f "$archive_path"
        printf 'Notarization status was %s, not Accepted. Review %s and the notary log before retrying.\n' "${notary_status:-unknown}" "build/$app_name-notary-submission.json" >&2
        exit 1
    fi
    rm -f "$archive_path"
    xcrun stapler staple "$packaged_app"
    xcrun stapler validate "$packaged_app"
fi

/usr/bin/ditto -c -k --keepParent "$packaged_app" "$archive_path"
printf 'App bundle: %s\nArchive: %s\n' "$packaged_app" "$archive_path"
