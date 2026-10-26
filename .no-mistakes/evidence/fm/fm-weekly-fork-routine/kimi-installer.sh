#!/usr/bin/env bash
#
# kimi-code installer for macOS and Linux.
#
# Usage:
#   curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
#   curl -fsSL https://code.kimi.com/kimi-code/install.sh | KIMI_VERSION=0.5.0 bash
#   curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash -s -- --version 0.5.0
#   curl -fsSL https://code.kimi.com/kimi-code/install.sh | sudo env KIMI_INSTALL_DIR=/usr/local bash
#
# Optional env:
#   KIMI_VERSION         Explicit version; if unset, fetch from https://code.kimi.com/kimi-code/latest
#   KIMI_INSTALL_DIR     Installation directory, default $HOME/.kimi-code
#   KIMI_NO_MODIFY_PATH  Skip PATH modification when set to a non-empty value
#
# Optional args:
#   --version VERSION    Explicit version; equivalent to KIMI_VERSION=VERSION

set -euo pipefail

KIMI_DOWNLOAD_BASE="https://code.kimi.com/kimi-code"
KIMI_BINARY_BASE="${KIMI_DOWNLOAD_BASE}/binaries"

KIMI_VERSION="${KIMI_VERSION:-}"
KIMI_INSTALL_DIR="${KIMI_INSTALL_DIR:-$HOME/.kimi-code}"
KIMI_NO_MODIFY_PATH="${KIMI_NO_MODIFY_PATH:-}"

# Region marker: which channel this install came from. Follows the download
# domain — sync.sh rewrites code.kimi.com → code.kimi.ai for the global
# mirror, so no extra publish-side rule is needed. The CLI reads
# <home>/region only until the first login, then the persisted login's
# oauthHost takes over.
KIMI_REGION="mainland-cn"
case "${KIMI_DOWNLOAD_BASE}" in
  *kimi.ai*) KIMI_REGION="global" ;;
esac
KIMI_HOME_DIR="${KIMI_CODE_HOME:-$HOME/.kimi-code}"

KIMI_PATH_UPDATED_RC=""

# ---------- helpers ----------

_have() { command -v "$1" >/dev/null 2>&1; }

_log() {
  if [ -t 1 ]; then
    printf '\033[1;36m==>\033[0m %s\n' "$*"
  else
    printf '==> %s\n' "$*"
  fi
}

_err() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
  curl -fsSL https://code.kimi.com/kimi-code/install.sh | KIMI_VERSION=0.5.0 bash
  curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash -s -- --version 0.5.0
  curl -fsSL https://code.kimi.com/kimi-code/install.sh | sudo env KIMI_INSTALL_DIR=/usr/local bash

Options:
  --version VERSION    Install a specific kimi-code version
  -h, --help           Show this help

Environment:
  KIMI_VERSION         Explicit version; if unset, fetch latest
  KIMI_INSTALL_DIR     Installation directory, default $HOME/.kimi-code
  KIMI_NO_MODIFY_PATH  Skip PATH modification when set
EOF
}

_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        _usage
        exit 0
        ;;
      --version)
        [ -n "${2:-}" ] || _err "--version requires a value"
        KIMI_VERSION="$2"
        shift 2
        ;;
      --version=*)
        KIMI_VERSION="${1#--version=}"
        [ -n "$KIMI_VERSION" ] || _err "--version requires a value"
        shift
        ;;
      -*)
        _err "unknown option: $1"
        ;;
      *)
        [ -z "$KIMI_VERSION" ] || _err "unexpected extra argument: $1"
        KIMI_VERSION="$1"
        shift
        ;;
    esac
  done
}

_detect_target() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux"  ;;
    MINGW*|MSYS*|CYGWIN*)
      _err "Windows is not supported by install.sh — use install.ps1 (PowerShell)"
      ;;
    *) _err "unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) _err "unsupported architecture: $(uname -m)" ;;
  esac

  # Rosetta 2: when running under an x64 shell on an ARM Mac, switch back to the native arm64 binary
  if [ "$os" = "darwin" ] && [ "$arch" = "x64" ]; then
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
      arch="arm64"
    fi
  fi

  # musl detection (Alpine, etc.) — we currently only ship glibc binaries, so failing early is better than a runtime dlopen error
  if [ "$os" = "linux" ]; then
    if [ -f "/lib/libc.musl-x86_64.so.1" ] || \
       [ -f "/lib/libc.musl-aarch64.so.1" ] || \
       ldd /bin/ls 2>&1 | grep -q musl; then
      _err "Alpine / musl Linux is not currently supported. Use Node.js + 'npm install -g @moonshot-ai/kimi-code' instead."
    fi
  fi

  echo "${os}-${arch}"
}

_download() {
  local url="$1" dest="${2:-}"
  if _have curl; then
    if [ -n "$dest" ]; then
      if [ -t 1 ]; then
        local headers download_size
        if headers="$(curl --fail --location --silent --head --max-time 10 "$url" 2>/dev/null)"; then
          download_size="$(printf '%s\n' "$headers" | awk '
            /^HTTP\// { size = "" }
            tolower($1) == "content-length:" { size = $2; sub(/\r$/, "", size) }
            END { if (size ~ /^[0-9]+$/ && size > 0) printf "%.1f MiB", size / 1048576 }
          ')"
          [ -z "$download_size" ] || _log "Download size: $download_size"
        fi
        curl --fail --location --progress-bar -o "$dest" "$url"
      else
        curl --fail --location --silent -o "$dest" "$url"
      fi
    else
      curl --fail --location --silent "$url"
    fi
  elif _have wget; then
    if [ -n "$dest" ]; then
      wget -q -O "$dest" "$url"
    else
      wget -q -O - "$url"
    fi
  else
    _err "curl or wget is required"
  fi
}

# Prefer jq; otherwise parse the bare fields before any nested objects.
_manifest_field() {
  local manifest_json="$1" target="$2" field="$3"
  if _have jq; then
    printf '%s' "$manifest_json" | jq -er ".platforms[\"$target\"].$field // empty"
  else
    local one_line
    one_line="$(printf '%s' "$manifest_json" | tr -d '\n\r\t' | sed 's/ \+/ /g')"
    if [[ $one_line =~ \"$target\"[[:space:]]*:[[:space:]]*\{[^{}]*\"$field\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
    fi
  fi
}

_sha256_check() {
  local file="$1" expected="$2"
  local actual
  if _have shasum; then
    actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  elif _have sha256sum; then
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
  else
    _err "shasum or sha256sum required to verify download"
  fi
  if [ "$actual" != "$expected" ]; then
    _err "checksum mismatch: expected $expected, got $actual"
  fi
}

_detect_shell_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash)
      if [ -f "$HOME/.bashrc" ]; then echo "$HOME/.bashrc"
      elif [ -f "$HOME/.bash_profile" ]; then echo "$HOME/.bash_profile"
      elif [ -f "$HOME/.profile" ]; then echo "$HOME/.profile"
      else echo "$HOME/.bashrc"; fi
      ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

_update_path() {
  if [ -n "$KIMI_NO_MODIFY_PATH" ]; then
    _log "Skipping PATH update (KIMI_NO_MODIFY_PATH set)"
    return
  fi
  case ":$PATH:" in
    *":${KIMI_INSTALL_DIR}/bin:"*)
      _log "${KIMI_INSTALL_DIR}/bin already in PATH"
      return
      ;;
  esac
  local rc
  rc="$(_detect_shell_rc)"
  mkdir -p "$(dirname "$rc")"
  local export_line
  if [[ "$rc" == *fish* ]]; then
    export_line="fish_add_path -g \"${KIMI_INSTALL_DIR}/bin\""
  else
    export_line="export PATH=\"${KIMI_INSTALL_DIR}/bin:\$PATH\""
  fi
  if ! grep -qsF "${KIMI_INSTALL_DIR}/bin" "$rc"; then
    printf '\n# kimi-code\n%s\n' "$export_line" >> "$rc"
    _log "Added ${KIMI_INSTALL_DIR}/bin to PATH in $rc"
  else
    _log "${KIMI_INSTALL_DIR}/bin already configured in $rc"
  fi
  KIMI_PATH_UPDATED_RC="$rc"
}

# ---------- legacy kimi-cli migration ----------
#
# Mirror of the Node postinstall logic (apps/kimi-code/scripts/postinstall*):
# detect every previous Python `kimi-cli` shim on PATH, rename the first to
# `kimi-legacy` so users keep a fallback, and remove subsequent duplicates so
# the new CLI isn't shadowed. The native binary installer prepends
# ${KIMI_INSTALL_DIR}/bin to PATH, so reachability is guaranteed after rc is
# sourced — no first-match check needed.

LEGACY_BIN="kimi"
LEGACY_RENAME="kimi-legacy"
PYTHON_MARKER="kimi_cli"
SHIM_SNIFF_BYTES=4096

# Try to resolve symlinks. macOS pre-Monterey lacks GNU `realpath` and its
# `readlink` has no `-f`; in that case fall back to the original path so the
# marker sniff at least inspects the file (works fine for non-symlinked
# shims, which is the common case).
_realpath_safe() {
  local p="$1"
  if _have realpath; then
    realpath "$p" 2>/dev/null || printf '%s' "$p"
  elif _have readlink && readlink -f / >/dev/null 2>&1; then
    readlink -f "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# True iff the file at $1 looks like a Python `kimi-cli` shim (setuptools
# entry-point or uv-style launcher). Realpath-resolves first so we read the
# real binary, not a symlink stub.
_is_legacy_shim() {
  local p="$1"
  [ -f "$p" ] || return 1
  local real
  real="$(_realpath_safe "$p")"
  # Defense in depth: never classify our own binary as legacy even if
  # something in the bundled JS happens to contain the marker substring.
  # Also resolve ${KIMI_INSTALL_DIR} so the comparison is symmetric — on
  # macOS `realpath` rewrites `/tmp/...` to `/private/tmp/...` and an
  # un-resolved literal prefix would never match.
  local own_real
  own_real="$(_realpath_safe "$KIMI_INSTALL_DIR")"
  case "$real" in
    "${own_real}"/*) return 1 ;;
  esac
  head -c "$SHIM_SNIFF_BYTES" "$real" 2>/dev/null \
    | grep -q "$PYTHON_MARKER"
}

# Walk $PATH and print every legacy `kimi` shim, one per line, in PATH order.
# Skips ${KIMI_INSTALL_DIR}/bin (our own install location) and dedups dirs.
_detect_legacy_shims() {
  local own_bin="${KIMI_INSTALL_DIR}/bin"
  local IFS=':'
  local seen=":"
  local dir
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    case "$seen" in
      *":${dir}:"*) continue ;;
    esac
    seen="${seen}${dir}:"
    [ "$dir" = "$own_bin" ] && continue

    local shim="${dir}/${LEGACY_BIN}"
    [ -f "$shim" ] || continue
    [ -x "$shim" ] || continue
    if _is_legacy_shim "$shim"; then
      printf '%s\n' "$shim"
    fi
  done
}

# Classify one legacy shim. Emits "<kind>\t<target>" where kind is one of:
#   renameable   — target slot free, `mv` should succeed.
#   consolidate  — target exists and is itself a legacy shim; drop source.
#   delete-only  — target exists but is user-managed; delete source only.
#   blocked      — parent dir not writable (sudo/admin needed).
_classify_shim() {
  local shim="$1"
  local dir target
  dir="$(dirname "$shim")"
  target="${dir}/${LEGACY_RENAME}"

  if [ ! -w "$dir" ] || [ ! -x "$dir" ]; then
    printf 'blocked\t%s\n' "$target"
    return
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    if _is_legacy_shim "$target"; then
      printf 'consolidate\t%s\n' "$target"
    else
      printf 'delete-only\t%s\n' "$target"
    fi
    return
  fi

  printf 'renameable\t%s\n' "$target"
}

# True iff the parent dir of $1 is owned by uid 0 (sudo-installed shim).
# Used for sudo-aware remediation hints on `blocked` outcomes.
#
# GNU `stat -c` first so Linux gets a clean answer. macOS BSD stat doesn't
# accept `-c` (prints a usage error to stderr, no stdout), so the OR chain
# cleanly falls through to `stat -f`. The reverse order would be wrong on
# Linux: GNU stat treats `-f` as "show filesystem info" and prints multi-line
# stdout *before* exiting non-zero, which contaminates the captured value.
_is_system_owned_dir() {
  local dir uid
  dir="$(dirname "$1")"
  uid="$(stat -c '%u' "$dir" 2>/dev/null \
        || stat -f '%u' "$dir" 2>/dev/null \
        || printf '')"
  [ "$uid" = "0" ]
}

_migrate_legacy_shims() {
  local shims
  shims="$(_detect_legacy_shims)"
  [ -n "$shims" ] || return 0

  # If the user opted out of PATH management AND our bin dir isn't already
  # on PATH, renaming legacy would strand them with no `kimi` command at
  # all. List what we found and skip.
  if [ -n "$KIMI_NO_MODIFY_PATH" ]; then
    case ":$PATH:" in
      *":${KIMI_INSTALL_DIR}/bin:"*) ;;
      *)
        _log "Found previous kimi-cli on PATH but skipping migration"
        _log "(KIMI_NO_MODIFY_PATH set and ${KIMI_INSTALL_DIR}/bin is not"
        _log "on PATH — renaming would leave no working kimi command)."
        _log "Affected shim(s):"
        while IFS= read -r s; do
          [ -n "$s" ] && printf '      %s\n' "$s"
        done <<< "$shims"
        _log "Add ${KIMI_INSTALL_DIR}/bin to PATH and re-run to migrate."
        return 0
        ;;
    esac
  fi

  local renames="" consolidates="" skipped_foreign=""
  local deletes="" blocked_paths="" errors=""
  local first_done=0
  local shim class_line kind target

  while IFS= read -r shim; do
    [ -n "$shim" ] || continue
    class_line="$(_classify_shim "$shim")"
    kind="${class_line%%	*}"
    target="${class_line#*	}"

    if [ "$kind" = "blocked" ]; then
      blocked_paths="${blocked_paths}${shim}"$'\n'
      continue
    fi

    if [ "$first_done" -eq 0 ]; then
      first_done=1
      case "$kind" in
        renameable)
          if mv -- "$shim" "$target" 2>/dev/null; then
            renames="${renames}${shim} -> ${target}"$'\n'
          else
            errors="${errors}${shim} (rename failed)"$'\n'
          fi
          ;;
        consolidate)
          if rm -f -- "$shim" 2>/dev/null; then
            consolidates="${consolidates}${shim} (existing ${target} kept)"$'\n'
          else
            errors="${errors}${shim} (delete failed)"$'\n'
          fi
          ;;
        delete-only)
          if rm -f -- "$shim" 2>/dev/null; then
            skipped_foreign="${skipped_foreign}${shim} (left ${target} alone)"$'\n'
          else
            errors="${errors}${shim} (delete failed)"$'\n'
          fi
          ;;
      esac
    else
      # Not the first actionable shim — keeping it as a dormant duplicate
      # adds no value, just remove it.
      if rm -f -- "$shim" 2>/dev/null; then
        deletes="${deletes}${shim}"$'\n'
      else
        errors="${errors}${shim} (delete failed)"$'\n'
      fi
    fi
  done <<< "$shims"

  _log "Migrated previous kimi-cli installation:"
  local line
  if [ -n "$renames" ]; then
    printf '    Renamed (preserved as kimi-legacy):\n'
    while IFS= read -r line; do
      [ -n "$line" ] && printf '      %s\n' "$line"
    done <<< "$renames"
  fi
  if [ -n "$consolidates" ]; then
    printf '    Removed duplicate (existing kimi-legacy kept):\n'
    while IFS= read -r line; do
      [ -n "$line" ] && printf '      %s\n' "$line"
    done <<< "$consolidates"
  fi
  if [ -n "$skipped_foreign" ]; then
    printf '    Removed (kimi-legacy slot was a user-managed file):\n'
    while IFS= read -r line; do
      [ -n "$line" ] && printf '      %s\n' "$line"
    done <<< "$skipped_foreign"
  fi
  if [ -n "$deletes" ]; then
    printf '    Also removed (would have shadowed the new CLI):\n'
    while IFS= read -r line; do
      [ -n "$line" ] && printf '      %s\n' "$line"
    done <<< "$deletes"
  fi
  if [ -n "$blocked_paths" ]; then
    printf '    Note: could not remove these (no write permission), but\n'
    printf '    PATH order means they no longer shadow the new CLI:\n'
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '      %s\n' "$line"
      if _is_system_owned_dir "$line"; then
        printf "        Remove manually: sudo rm '%s'\n" "$line"
      else
        printf "        Remove manually: rm '%s'\n" "$line"
      fi
    done <<< "$blocked_paths"
  fi
  if [ -n "$errors" ]; then
    printf '    The following operations failed unexpectedly:\n'
    while IFS= read -r line; do
      [ -n "$line" ] && printf '      %s\n' "$line"
    done <<< "$errors"
  fi
}

# ---------- main ----------

TMPDIR_INSTALL=""
_cleanup() {
  if [ -n "$TMPDIR_INSTALL" ] && [ -d "$TMPDIR_INSTALL" ]; then
    rm -rf "$TMPDIR_INSTALL"
  fi
}
trap _cleanup EXIT

main() {
  local target version manifest_url manifest filename checksum binary_url tarball_url bin_path tmpdir

  _parse_args "$@"

  target="$(_detect_target)"
  _log "Detected target: $target"

  # 1. Resolve version
  if [ -n "$KIMI_VERSION" ]; then
    version="$KIMI_VERSION"
    _log "Using pinned version $version"
  else
    _log "Resolving latest version from ${KIMI_DOWNLOAD_BASE}/latest"
    version="$(_download "${KIMI_DOWNLOAD_BASE}/latest" | tr -d '[:space:]')"
    [ -n "$version" ] || _err "could not resolve latest version"
    _log "Latest version: $version"
  fi

  # 2. Fetch manifest
  manifest_url="${KIMI_BINARY_BASE}/${version}/manifest.json"
  _log "Fetching manifest ${manifest_url}"
  manifest="$(_download "$manifest_url")"
  [ -n "$manifest" ] || _err "manifest is empty or unreachable: $manifest_url"

  # 3. Find current platform entry
  filename="$(_manifest_field "$manifest" "$target" "filename")"
  checksum="$(_manifest_field "$manifest" "$target" "checksum")"
  [ -n "$filename" ] || _err "platform $target not found in manifest"
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || _err "invalid checksum for $target: $checksum"

  # 4. Prefer tar.gz; download/extraction failures fall back to the bare binary.
  TMPDIR_INSTALL="$(mktemp -d 2>/dev/null || mktemp -d -t kimi-install)"
  tmpdir="$TMPDIR_INSTALL"
  bin_path=""
  tarball_url="${KIMI_BINARY_BASE}/${version}/kimi-code-${target}.tar.gz"
  if _have tar; then
    _log "Downloading ${tarball_url}"
    if _download "$tarball_url" "${tmpdir}/kimi-code.tar.gz"; then
      _log "Extracting tarball"
      mkdir -p "${tmpdir}/extract"
      if tar -xzf "${tmpdir}/kimi-code.tar.gz" -C "${tmpdir}/extract" \
        && [ -f "${tmpdir}/extract/kimi" ]; then
        bin_path="${tmpdir}/extract/kimi"
      else
        _log "Tarball extract failed; falling back to bare binary"
      fi
    else
      _log "Tarball download failed; falling back to bare binary"
    fi
  fi
  if [ -z "$bin_path" ]; then
    binary_url="${KIMI_BINARY_BASE}/${version}/${filename}"
    _log "Downloading ${binary_url}"
    _download "$binary_url" "${tmpdir}/${filename}"
    bin_path="${tmpdir}/${filename}"
  fi

  # 5. Verify checksum
  _log "Verifying checksum"
  _sha256_check "$bin_path" "$checksum"

  # 6. Install
  chmod +x "$bin_path"
  mkdir -p "${KIMI_INSTALL_DIR}/bin"
  if [ -f "${KIMI_INSTALL_DIR}/bin/kimi" ]; then
    cp "${KIMI_INSTALL_DIR}/bin/kimi" "${KIMI_INSTALL_DIR}/bin/kimi.bak"
    _log "Backed up existing kimi to ${KIMI_INSTALL_DIR}/bin/kimi.bak"
  fi
  install -m 0755 "$bin_path" "${KIMI_INSTALL_DIR}/bin/kimi"
  _log "Installed to ${KIMI_INSTALL_DIR}/bin/kimi"

  # 7. PATH
  _update_path

  # 8. Migrate previous Python `kimi-cli` installations: rename the first
  #    `kimi` on PATH to `kimi-legacy` (preserve fallback) and drop later
  #    duplicates so the new CLI isn't shadowed.
  _migrate_legacy_shims

  # 9. Region marker (first-login default only). Never overwrite an existing
  #    one — a reinstall must not clobber the channel the user installed from.
  if [ ! -f "${KIMI_HOME_DIR}/region" ]; then
    mkdir -p "${KIMI_HOME_DIR}"
    printf '%s\n' "${KIMI_REGION}" > "${KIMI_HOME_DIR}/region"
  fi

  _log "Done. Run: kimi --version"

  if [ -n "$KIMI_PATH_UPDATED_RC" ]; then
    if [ -t 1 ]; then
      printf '\033[1;33m==> If `kimi` is not found, restart your shell or run:\033[0m \033[1;4msource %s\033[0m\n' "$KIMI_PATH_UPDATED_RC"
    else
      printf '==> If `kimi` is not found, restart your shell or run: source %s\n' "$KIMI_PATH_UPDATED_RC"
    fi
  fi
}

main "$@"
