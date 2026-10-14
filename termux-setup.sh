#!/data/data/com.termux/files/usr/bin/bash
# termux-setup.sh — one-shot bootstrap for building Purrfect Stealth in Termux.
#
# Run from the folder that has purrfect-stealth-build.sh in it:
#   bash termux-setup.sh
#
# v2 (Nyx review):
#   - fixed: /tmp does not exist on Termux — temp files now use $TMPDIR
#   - fixed: JAVA_HOME pointed at $PREFIX/opt/openjdk-21 (doesn't exist);
#     now auto-detected from $PREFIX/lib/jvm/ BEFORE sdkmanager runs
#   - fixed: Rust Android targets were never actually installed
#     (the old script only mused about cargo-ndk); pkg's rust-std-*
#     packages are installed directly, mirroring the build script
#   - sdkmanager presence is verified after the cmdline-tools install

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()  { echo -e "${GREEN}✓${NC} $1"; }
hdr() { echo -e "\n${CYAN}── $1${NC}"; }
err() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }

hdr "Termux storage access"
termux-setup-storage || true
sleep 1

hdr "Packages"
pkg update -y
pkg upgrade -y
pkg install -y git wget unzip openjdk-21 rust binutils

# Termux has no /tmp — temp files go to $TMPDIR ($PREFIX/tmp).
TMPD="${TMPDIR:-$PREFIX/tmp}"
mkdir -p "$TMPD"

# ── JAVA_HOME — must be correct BEFORE anything invokes java/sdkmanager ──
# Termux's openjdk package installs under $PREFIX/lib/jvm/, e.g.
# $PREFIX/lib/jvm/java-21-openjdk — NOT $PREFIX/opt/openjdk-21.
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
    CANDIDATE=$(ls -d "$PREFIX"/lib/jvm/java-21-openjdk* 2>/dev/null | head -1 || true)
    [[ -n "$CANDIDATE" ]] || err "No JDK found under \$PREFIX/lib/jvm — is openjdk-21 installed?"
    export JAVA_HOME="$CANDIDATE"
fi
export PATH="$JAVA_HOME/bin:$PATH"
java -version
ok "JAVA_HOME=$JAVA_HOME"

# ── Rust Android targets ──
# Termux ships rustc via pkg (no rustup). The std libs for Android targets
# come as separate pkg packages — same approach as purrfect-stealth-build.sh.
hdr "Rust Android targets"
for t in aarch64-linux-android armv7-linux-androideabi x86_64-linux-android; do
    pkg install -y "rust-std-$t" 2>/dev/null \
        || warn "pkg has no 'rust-std-$t' — run 'pkg search rust-std' and install the matching name manually"
done
ok "Rust targets ready"

# ── Android SDK (into Termux's own storage, not /sdcard) ──
hdr "Android SDK"
export ANDROID_HOME="$HOME/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
mkdir -p "$ANDROID_HOME"

if [[ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
    wget -q --show-progress \
        "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -O "$TMPD/cmdtools.zip"
    rm -rf "$TMPD/ct_raw"
    unzip -q "$TMPD/cmdtools.zip" -d "$TMPD/ct_raw"
    mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
    mv "$TMPD"/ct_raw/cmdline-tools/* "$ANDROID_HOME/cmdline-tools/latest/"
    rm -rf "$TMPD/cmdtools.zip" "$TMPD/ct_raw"
fi

export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
command -v sdkmanager &>/dev/null || err "sdkmanager not found after install"

mkdir -p "$ANDROID_HOME/licenses"
echo "24333f8a63b6825ea9c5514f83c2829b004d1fee" > "$ANDROID_HOME/licenses/android-sdk-license"
echo "d56f5187479451eabf01fb78af6dfcb131a6481e" >> "$ANDROID_HOME/licenses/android-sdk-license"
echo "84831b9409646a918e30573bab4c9c91346d8abd" > "$ANDROID_HOME/licenses/android-sdk-preview-license"

sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools" "ndk;28.2.13676358" \
    --sdk_root="$ANDROID_HOME"
ok "SDK ready"

hdr "git tuning for large clones over mobile data"
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000

hdr "Running build"
bash purrfect-stealth-build.sh

echo ""
echo "APK (if build succeeded) is at: ~/Purrfect-stealth-*-debug.apk"
echo "or /sdcard/Download/Purrfect-stealth-*.apk if storage access was granted."
