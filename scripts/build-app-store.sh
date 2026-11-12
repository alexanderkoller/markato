#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

application_identity="${MARKATO_APP_STORE_APPLICATION_IDENTITY:-}"
installer_identity="${MARKATO_APP_STORE_INSTALLER_IDENTITY:-}"
profile_path="${MARKATO_APP_STORE_PROFILE:-}"
build_number="${MARKATO_BUILD_NUMBER:-1}"

if [[ -z "$application_identity" || -z "$installer_identity" || -z "$profile_path" ]]; then
    cat >&2 <<'USAGE'
Usage: set these variables, then run bash scripts/build-app-store.sh
  MARKATO_APP_STORE_APPLICATION_IDENTITY  Mac App Distribution certificate name
  MARKATO_APP_STORE_INSTALLER_IDENTITY    Mac Installer Distribution certificate name
  MARKATO_APP_STORE_PROFILE               Path to Markato's Mac App Store profile
Optional:
  MARKATO_BUILD_NUMBER                    Positive integer (default: 1)
USAGE
    exit 2
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "MARKATO_BUILD_NUMBER must be a positive integer" >&2
    exit 2
fi
if [[ ! -f "$profile_path" ]]; then
    echo "Provisioning profile not found: $profile_path" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | rg -Fq "\"$application_identity\""; then
    echo "Application signing identity is not installed: $application_identity" >&2
    exit 1
fi
if ! security find-certificate -c "$installer_identity" >/dev/null; then
    echo "Installer signing identity is not installed: $installer_identity" >&2
    exit 1
fi

bash scripts/build-app.sh release

output_dir="$PWD/dist/app-store"
mkdir -p "$output_dir"
stage_dir="$(mktemp -d "$output_dir/.package-build.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
app_path="$stage_dir/Markato.app"
ditto "$PWD/dist/Markato.app" "$app_path"

decoded_profile="$stage_dir/profile.plist"
security cms -D -i "$profile_path" -o "$decoded_profile"
application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded_profile" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded_profile")"
team_id="${application_identifier%%.*}"
profile_bundle_id="${application_identifier#"$team_id".}"
if [[ "$profile_bundle_id" != "de.akoller.markato" ]]; then
    echo "Provisioning profile is for $profile_bundle_id, expected de.akoller.markato" >&2
    exit 1
fi

cp "$profile_path" "$app_path/Contents/embedded.provisionprofile"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_path/Contents/Info.plist"
# Downloads and copied dependencies may carry Gatekeeper quarantine metadata.
# App Store packages must contain none, so sanitize the complete staged bundle
# before signing and fail closed if any quarantine attribute remains.
xattr -dr com.apple.quarantine "$app_path" 2>/dev/null || true
if xattr -lr "$app_path" | rg -q 'com\.apple\.quarantine'; then
    echo "Staged app still contains com.apple.quarantine attributes" >&2
    exit 1
fi

main_entitlements="$stage_dir/Markato.entitlements"
cp App/Markato.entitlements "$main_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $application_identifier" "$main_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team_id" "$main_entitlements"

for library in "$app_path/Contents/Frameworks/"*.dylib; do
    codesign --force --sign "$application_identity" --timestamp "$library"
done
codesign --force --sign "$application_identity" --timestamp \
    --entitlements App/MarkatoPrintRenderer.entitlements \
    "$app_path/Contents/Helpers/MarkatoPrintRenderer"
codesign --force --sign "$application_identity" --timestamp \
    --entitlements "$main_entitlements" "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
signed_bundle_id="$(codesign -d --verbose=4 "$app_path" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$signed_bundle_id" != "de.akoller.markato" ]]; then
    echo "Signed bundle identifier is $signed_bundle_id, expected de.akoller.markato" >&2
    exit 1
fi

package_name="Markato-1.0.0-$build_number.pkg"
staged_package="$stage_dir/$package_name"
productbuild --component "$app_path" /Applications --sign "$installer_identity" "$staged_package"
pkgutil --check-signature "$staged_package"

final_app="$output_dir/Markato.app"
if [[ -e "$final_app" ]]; then mv "$final_app" "$stage_dir/previous.app"; fi
mv "$app_path" "$final_app"
mv -f "$staged_package" "$output_dir/$package_name"
echo "$output_dir/$package_name"
