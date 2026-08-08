#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
derived_data_root="$project_dir/.build-release"
output_dir="$project_dir/dist"
output_app="$output_dir/Atmosphere.app"
signing_identity="${ATMOSPHERE_SIGNING_IDENTITY:--}"

derived_data_dir=""
release_work_dir=""
candidate_app=""
backup_app=""
replacement_started=0
release_committed=0

cleanup_release() {
  local exit_status=$?
  local restore_failed=0

  trap - EXIT
  set +e

  if (( ! release_committed && replacement_started )); then
    if [[ -e "$output_app" || -L "$output_app" ]]; then
      rm -rf "$output_app"
    fi

    if [[ -n "$backup_app" && ( -e "$backup_app" || -L "$backup_app" ) ]]; then
      if ! mv "$backup_app" "$output_app"; then
        print -u2 "Could not restore the previous release. It remains at $backup_app"
        restore_failed=1
      fi
    fi
  fi

  if [[ -n "$release_work_dir" ]]; then
    if (( release_committed )); then
      rm -rf "$release_work_dir"
    elif [[ -n "$backup_app" && ( -e "$backup_app" || -L "$backup_app" ) ]]; then
      print -u2 "Preserving release recovery directory at $release_work_dir"
    else
      rm -rf "$release_work_dir"
    fi
  fi

  if [[ -n "$derived_data_dir" ]]; then
    rm -rf "$derived_data_dir"
  fi

  if (( restore_failed )); then
    exit 1
  fi
  exit "$exit_status"
}

trap cleanup_release EXIT

cd "$project_dir"

mkdir -p "$derived_data_root" "$output_dir"
derived_data_dir="$(mktemp -d "$derived_data_root/run.XXXXXX")"
release_work_dir="$(mktemp -d "$output_dir/.Atmosphere.release.XXXXXX")"
candidate_app="$release_work_dir/Atmosphere.app"
backup_app="$release_work_dir/Atmosphere.previous.app"
source_app="$derived_data_dir/Build/Products/Release/Atmosphere.app"

# Release builds deliberately use the checked-in project. Regeneration is an
# explicit developer step so merely having XcodeGen installed cannot change the
# artifact produced from a checkout.
xcodebuild \
  -project Atmosphere.xcodeproj \
  -scheme Atmosphere \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data_dir" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build

# Prepare and validate the complete candidate before touching the current
# release. Both later moves stay on the dist filesystem and are atomic renames.
ditto "$source_app" "$candidate_app"
codesign --force --deep --sign "$signing_identity" "$candidate_app"
codesign --verify --deep --strict --verbose=2 "$candidate_app"

if [[ -e "$output_app" || -L "$output_app" ]]; then
  mv "$output_app" "$backup_app"
fi

replacement_started=1
mv "$candidate_app" "$output_app"
release_committed=1

echo "Built and verified $output_app"
