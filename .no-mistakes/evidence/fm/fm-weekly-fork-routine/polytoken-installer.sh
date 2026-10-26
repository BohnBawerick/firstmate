#!/usr/bin/env bash
set -euo pipefail

base_url="${PT_BASE_URL:-https://dl.polytoken.dev}"
channel="${PT_CHANNEL:-latest}"
requested_version="${PT_VERSION:-latest}"
install_dir="${PT_INSTALL_DIR:-}"
dry_run="${PT_DRY_RUN:-0}"
verbose="${PT_VERBOSE:-0}"

log() {
    printf '%s\n' "$*"
}

verbose_log() {
    if [[ "$verbose" == "1" ]]; then
        printf '%s\n' "$*"
    fi
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

case "$base_url" in
    https://*) ;;
    *) fail "PT_BASE_URL must use https://, got '$base_url'" ;;
esac

case "$channel" in
    stable | latest) ;;
    *) fail "PT_CHANNEL must be stable or latest, got '$channel'" ;;
esac

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        fail "missing required tool '$tool'"
    fi
}

normalize_home_path() {
    local path="$1"
    case "$path" in
        \~) printf '%s\n' "$HOME" ;;
        \~/*) printf '%s/%s\n' "$HOME" "${path#\~/}" ;;
        \$HOME) printf '%s\n' "$HOME" ;;
        \$HOME/*) printf '%s/%s\n' "$HOME" "${path#\$HOME/}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

path_contains_dir() {
    local wanted="$1"
    local entry
    local normalized
    IFS=':' read -r -a path_entries <<< "${PATH:-}"
    for entry in "${path_entries[@]}"; do
        normalized="$(normalize_home_path "$entry")"
        if [[ "$normalized" == "$wanted" ]]; then
            return 0
        fi
    done
    return 1
}

choose_install_dir() {
    local local_bin="$HOME/.local/bin"
    local home_bin="$HOME/bin"
    local entry
    local normalized

    if [[ -n "$install_dir" ]]; then
        normalize_home_path "$install_dir"
        return
    fi

    IFS=':' read -r -a path_entries <<< "${PATH:-}"
    for entry in "${path_entries[@]}"; do
        normalized="$(normalize_home_path "$entry")"
        case "$normalized" in
            "$local_bin"|"$home_bin")
                printf '%s\n' "$normalized"
                return
                ;;
        esac
    done

    printf '%s\n' "$local_bin"
}

channel_base_url() {
    printf '%s\n' "${base_url%/}"
}

resolve_version() {
    local version="$requested_version"

    if [[ -z "$version" || "$version" == "latest" ]]; then
        local channels_url
        channels_url="$(channel_base_url)/channels.json"
        verbose_log "Fetching channels.json from $channels_url"
        local channels_path="$tmp_dir/channels.json"
        curl --fail --show-error --silent --proto '=https' --tlsv1.2 \
            --retry 3 --retry-delay 1 --header 'Cache-Control: no-cache' \
            "$channels_url" --output "$channels_path"

        version="$(sed -n 's/.*"'"$channel"'"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$channels_path" | head -1)"
        if [[ -z "$version" ]]; then
            fail "channels.json did not contain a version for channel '$channel'"
        fi
    fi

    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "PT_VERSION must be 'latest' or plain semver X.Y.Z, got '$version'"
    fi

    printf '%s\n' "$version"
}

platform_info() {
    local os
    local arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os:$arch" in
        Linux:x86_64|Linux:amd64)
            printf '%s %s\n' "linux-amd64" "SHA256SUMS.linux"
            ;;
        Linux:aarch64|Linux:arm64)
            printf '%s %s\n' "linux-arm64" "SHA256SUMS.linux"
            ;;
        Darwin:x86_64|Darwin:amd64)
            printf '%s %s\n' "macos-amd64" "SHA256SUMS.macos"
            ;;
        Darwin:arm64|Darwin:aarch64)
            printf '%s %s\n' "macos-arm64" "SHA256SUMS.macos"
            ;;
        *)
            fail "unsupported platform: $os $arch"
            ;;
    esac
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        fail "missing sha256 tool; install sha256sum or shasum"
    fi
}

cleanup() {
    if [[ -n "${tmp_dir:-}" ]]; then
        rm -rf "$tmp_dir"
    fi
}
trap cleanup EXIT

require_tool awk
require_tool curl
require_tool grep
require_tool mkdir
require_tool mv
require_tool sed
require_tool uname

tmp_dir="$(mktemp -d 2>/dev/null || mktemp -d -t polytoken-install)"
version="$(resolve_version)"
platform_fields="$(platform_info)"
read -r platform checksum_file <<< "$platform_fields"
resolved_base_url="$(channel_base_url)"
artifact_path="$platform/polytoken"
artifact_url="$resolved_base_url/$version/$artifact_path"
checksum_url="$resolved_base_url/$version/$checksum_file"
resolved_install_dir="$(choose_install_dir)"
target_path="$resolved_install_dir/polytoken"
path_needs_update=0
if ! path_contains_dir "$resolved_install_dir"; then
    path_needs_update=1
fi

if [[ "$dry_run" == "1" ]]; then
    log "Polytoken installer dry run"
    log "  channel: $channel"
    log "  version: $version"
    log "  platform: $platform"
    log "  artifact: $artifact_url"
    log "  checksums: $checksum_url"
    log "  install dir: $resolved_install_dir"
    log "No files changed."
    exit 0
fi

binary_path="$tmp_dir/polytoken"
checksums_path="$tmp_dir/$checksum_file"

log "Installing Polytoken $version for $platform"
verbose_log "Downloading $artifact_url"
curl --fail --show-error --silent --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --output "$binary_path" "$artifact_url"
verbose_log "Downloading $checksum_url"
curl --fail --show-error --silent --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --output "$checksums_path" "$checksum_url"

expected_sha="$(awk -v rel_path="$artifact_path" '$2 == rel_path { print $1 }' "$checksums_path")"
if [[ -z "$expected_sha" ]]; then
    fail "missing checksum for $artifact_path in $checksum_file"
fi
actual_sha="$(sha256_file "$binary_path")"
if [[ "$actual_sha" != "$expected_sha" ]]; then
    printf 'ERROR: checksum mismatch for %s\n' "$artifact_path" >&2
    exit 2
fi
verbose_log "Checksum verified: $actual_sha"

mkdir -p "$resolved_install_dir"
if [[ ! -w "$resolved_install_dir" ]]; then
    fail "install directory is not writable: $resolved_install_dir"
fi

tmp_target="$resolved_install_dir/.polytoken.tmp.$$"
cp "$binary_path" "$tmp_target"
chmod 0755 "$tmp_target"
mv "$tmp_target" "$target_path"

log "Polytoken $version installed to $target_path"

if [[ "$path_needs_update" == "1" ]]; then
    log ""
    log "Add Polytoken to your PATH:"
    if [[ "$resolved_install_dir" == "$HOME/.local/bin" ]]; then
        log "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    elif [[ "$resolved_install_dir" == "$HOME/bin" ]]; then
        log "  export PATH=\"\$HOME/bin:\$PATH\""
    else
        log "  export PATH=\"$resolved_install_dir:\$PATH\""
    fi
    log ""
    log "Add that line to your shell profile, then restart your shell."
else
    log "Run: polytoken --version"
fi
