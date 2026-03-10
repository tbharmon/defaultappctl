#!/bin/zsh
# Exit immediately on:
# -e : any command failure
# -u : use of unset variables
# -o pipefail : failures inside pipelines propagate
set -euo pipefail

# Package metadata used by pkgbuild
ORG_ID="com.yourorg.defaultappctl"
VERSION="1.0"
PKG_NAME="DefaultAppCtl-$VERSION.pkg"

# Resolve paths relative to this script’s directory
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/DefaultAppCtl.swift"   # Swift source to compile
RES="$HERE/resources"                # Resource files to include in payload
SCRIPTS="$HERE/pkg_scripts"          # pkgbuild scripts (preinstall/postinstall, etc.)

# Working directories and log location
WORK="$HERE/.work"
ROOT="$WORK/root"                    # Staging root for pkg payload
BUILD_LOG="$WORK/build.log"          # Build log file

# Ensure working directory exists (ignore error if it already exists)
mkdir -p "$WORK" || true

# Simple logger: UTC timestamp + message, append to BUILD_LOG
# Also mirrors output to console via tee (then redirects tee output to /dev/null)
blog() {
  local stamp
  stamp="$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[$stamp] build_pkg: $*" | tee -a "$BUILD_LOG" >/dev/null
}

blog "START"

# Create payload directory structure inside the staging root
mkdir -p \
  "$ROOT/usr/local/bin" \
  "$ROOT/Library/Application Support/DefaultAppCtl"

blog "Compiling Swift CLI (with -parse-as-library to support @main)"
# Compile the Swift CLI into a binary placed in WORK/
# -parse-as-library allows @main in certain compilation setups
# -O enables optimizations
# AppKit + UniformTypeIdentifiers frameworks are linked
# Compiler stdout/stderr is appended to BUILD_LOG (and not printed to console)
/usr/bin/swiftc -parse-as-library -O \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$SRC" \
  -o "$WORK/defaultappctl" \
  2>&1 | tee -a "$BUILD_LOG" >/dev/null

blog "Staging payload"
# Stage the compiled binary into the package payload
install -m 0755 "$WORK/defaultappctl" \
  "$ROOT/usr/local/bin/defaultappctl"

# Stage defaults.json into Application Support inside the package payload
install -m 0644 "$RES/defaults.json" \
  "$ROOT/Library/Application Support/DefaultAppCtl/defaults.json"

blog "Building pkg via pkgbuild"
# Build the .pkg using pkgbuild:
# --root     : payload root directory
# --scripts  : install-time scripts directory
# --identifier/--version : package metadata
# Output pkg written to HERE/PKG_NAME
# pkgbuild output appended to BUILD_LOG (and not printed to console)
/usr/bin/pkgbuild \
  --root "$ROOT" \
  --scripts "$SCRIPTS" \
  --identifier "$ORG_ID" \
  --version "$VERSION" \
  "$HERE/$PKG_NAME" \
  2>&1 | tee -a "$BUILD_LOG" >/dev/null

blog "DONE built $HERE/$PKG_NAME"
``
