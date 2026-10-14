#!/usr/bin/env bash
# purrfect-stealth-build.sh  v3
# Clones Purrfect (me.eternal.purrfect), randomises package + module identity,
# injects the security suite (StealthController + StealthHooks + SecurityFeature),
# then builds a signed debug APK covering arm64-v8a, armeabi-v7a, x86_64.
#
# Run in UserLAnd (Ubuntu), Termux (F-Droid), GitHub Actions, or any Linux with JDK 21.
#
# Usage:
#   bash purrfect-stealth-build.sh
#
# First run: generates a random package name saved to .stealth-id.
# Rotate identity: rm .stealth-id && bash purrfect-stealth-build.sh
#
# v3.6 polish (Nyx review):
#   - SDK step now installs ONLY missing packages. The runner image already
#     ships platforms;android-36 and build-tools;36.0.0, so the only real
#     download is the NDK (~1 GB). Also stopped swallowing sdkmanager's
#     output through `tail -3` (which made the step look dead for 15+ min
#     while the NDK downloaded) and switched the declared platform /
#     build-tools from 35 to 36 to match upstream's compileSdk.
#
# v3.5 polish (Nyx review):
#   - added *.aidl to the package-rename file list. The rename moved
#     SyncCallback.aidl into the new package directory but left its
#     `package me.eternal.purrfect.bridge;` declaration untouched, so the
#     AIDL compiler (which requires path == package) failed the build at
#     :common:compileDebugAidl.
#
# v3.4 polish (Nyx review):
#   - LSPatch jar discovery: checks ~/lspatch.jar, then /sdcard/Download and
#     ~/storage/downloads for lspatch*.jar, before downloading.
#   - STEALTH_BUILD_TYPE=release support for the signed workflow:
#     builds assembleAllRelease (universal arm64-v8a + armeabi-v7a flavor);
#     with the release keystore + PS_RELEASE_* gradle properties present,
#     upstream's build.gradle.kts signs the release APK automatically.
#
# v3.3 polish (Nyx review):
#   - SecurityFeature + StealthHooks rewritten against the REAL Purrfect API,
#     verified from the dev-branch source: Feature takes a single key
#     (the old two-arg constructor didn't compile), hooks use the project's
#     own Class.hook/HookStage/HookAdapter wrappers (a raw YukiHookAPI
#     PackageParam is never attached in this codebase, so the old
#     param.run { } approach could never work), and SecurityFeature is now
#     auto-registered in FeatureManager (import + register entry).
#
# v3.2 polish (Nyx review):
#   - LSPatch section verified against the JingMatrix fork's actual CLI:
#     download URL now resolves the versioned release jar via the GitHub
#     API (the fork ships lspatch-vX.Y-N-release.jar, no plain lspatch.jar);
#     fixed flags — --force-debuggable and --sigbypass don't exist
#     (they'd abort with exit 2); -l IS --sigbypasslv, -m is --embed,
#     -o is the output dir; added -f so re-runs overwrite cleanly.
#
# v3.1 polish (Nyx review):
#   - TMPDIR-aware temp paths (Termux has no /tmp)
#   - Termux-aware JAVA_HOME detection ($PREFIX/lib/jvm/...)
#   - whole-subtree package dir move (nested sub-packages were missed)
#   - regex-escaped package name in sed renames
#   - portable grep -oE instead of grep -oP for gradle version sniffing
#   - gradle build failure now reports instead of dying silently via pipefail
#   - curl added to apt deps (rustup installer needs it)
#
# v3 changes:
#   - popup gate-order fix: Activity liveness is checked BEFORE claiming the
#     _popupShown gate, so a detection fired before the first onResume() no
#     longer loses the popup silently on retry.
#   - FragmentTransaction.add() hook now disambiguates with paramCount = 3,
#     avoiding a YukiHookAPI ambiguous-method-resolution throw at hook-init.
#   - XPOSED_CLASS_BLOCKLIST scoped to the injected security sub-package
#     instead of the whole renamed app, so the host's own reflective class
#     loading isn't blocked after the package rename.
#   - x86_64-linux-android added as a build target (Chromebooks / emulators);
#     arm64-v8a and armeabi-v7a remain the primary real-device targets.

set -euo pipefail
GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()  { echo -e "${GREEN}✓${NC} $1"; }
hdr() { echo -e "\n${CYAN}── $1${NC}"; }
err() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn(){ echo -e "${YELLOW}⚠${NC} $1"; }

REPO_URL="https://www.purrfectgit.com/git/particle-box/purrfect.git"
WORK_DIR="$HOME/purrfect-stealth"
ID_FILE="$WORK_DIR/.stealth-id"
ORIG_PKG="me.eternal.purrfect"        # real package in the repo
RUST_TARGETS=(aarch64-linux-android armv7-linux-androideabi x86_64-linux-android)
NDK_VERSION="28.2.13676358"

# ── DEPS ──────────────────────────────────────────────────────────────────────
hdr "Dependencies"
if command -v apt-get &>/dev/null; then
    sudo apt-get install -y --no-install-recommends git openjdk-21-jdk wget unzip curl 2>/dev/null || true
elif command -v pkg &>/dev/null; then
    pkg install -y git openjdk-21 wget unzip 2>/dev/null || true
fi
java -version 2>&1 | grep -q "21\." || err "JDK 21 required"
command -v git &>/dev/null           || err "git not found"

# Rust + Android targets (idempotent — safe to re-run)
#
# Termux ships rustc/cargo directly via pkg — it does NOT use rustup, and
# running the rustup installer on top of a pkg-installed Rust fails two ways:
# it refuses to install over an existing toolchain, and Termux's sandboxed
# euid reports a different home dir than $HOME, which breaks rustup's lock
# file. Detect Termux (pkg present) and use pkg's rust-std-* target packages
# instead of `rustup target add`.
if command -v pkg &>/dev/null; then
    TERMUX_RUST_TARGET_PKGS=(
        rust-std-aarch64-linux-android
        rust-std-armv7-linux-androideabi
        rust-std-x86_64-linux-android
    )
    for p in "${TERMUX_RUST_TARGET_PKGS[@]}"; do
        pkg install -y "$p" 2>/dev/null || warn "pkg has no '$p' — run 'pkg search rust-std' and install the matching name manually"
    done
elif command -v apt-get &>/dev/null; then
    if ! command -v rustup &>/dev/null; then
        curl https://sh.rustup.rs -sSf | sh -s -- -y --no-modify-path
        source "$HOME/.cargo/env"
    fi
    source "$HOME/.cargo/env" 2>/dev/null || true
    rustup target add "${RUST_TARGETS[@]}"
fi

ok "Deps ready"

# ── ANDROID SDK ───────────────────────────────────────────────────────────────
hdr "Android SDK"
SDK_ROOT="${ANDROID_HOME:-$HOME/android-sdk}"

# Termux has no /tmp — use $TMPDIR ($PREFIX/tmp) when present.
TMPD="${TMPDIR:-/tmp}"
mkdir -p "$TMPD"

if [[ ! -d "$SDK_ROOT/cmdline-tools/latest/bin" ]]; then
    mkdir -p "$SDK_ROOT/cmdline-tools"
    wget -q --show-progress \
        "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -O "$TMPD/cmdtools.zip"
    rm -rf "$TMPD/ct_raw"
    unzip -q "$TMPD/cmdtools.zip" -d "$TMPD/ct_raw"
    rm -rf "$SDK_ROOT/cmdline-tools/latest"
    mkdir -p "$SDK_ROOT/cmdline-tools/latest"
    mv "$TMPD"/ct_raw/cmdline-tools/* "$SDK_ROOT/cmdline-tools/latest/"
    rm -rf "$TMPD/cmdtools.zip" "$TMPD/ct_raw"
fi
export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
command -v sdkmanager &>/dev/null || err "sdkmanager not found — cmdline-tools install failed"

mkdir -p "$ANDROID_HOME/licenses"
echo "24333f8a63b6825ea9c5514f83c2829b004d1fee" > "$ANDROID_HOME/licenses/android-sdk-license"
echo "d56f5187479451eabf01fb78af6dfcb131a6481e" >> "$ANDROID_HOME/licenses/android-sdk-license"
echo "84831b9409646a918e30573bab4c9c91346d8abd" > "$ANDROID_HOME/licenses/android-sdk-preview-license"

# Install only SDK packages that are missing. The GitHub runner image
# already ships the platform and build-tools; the NDK is the only big
# download, so say so instead of looking stuck.
INSTALLED_PKGS="$(sdkmanager --list_installed --sdk_root="$ANDROID_HOME" 2>/dev/null || true)"
NEED_PKGS=()
for pkg in "platforms;android-36" "build-tools;36.0.0" "platform-tools" "ndk;${NDK_VERSION}"; do
    if grep -qF "$pkg" <<<"$INSTALLED_PKGS"; then
        echo "  already installed: $pkg"
    else
        NEED_PKGS+=("$pkg")
    fi
done
if (( ${#NEED_PKGS[@]} )); then
    echo "  downloading: ${NEED_PKGS[*]}"
    sdkmanager "${NEED_PKGS[@]}" --sdk_root="$ANDROID_HOME"
else
    echo "  everything already installed — no download needed"
fi
ok "SDK ready (arm64-v8a / armeabi-v7a / x86_64 NDK installed)"

# ── CLONE / UPDATE ────────────────────────────────────────────────────────────
hdr "Repository"
git config --global http.version HTTP/1.1 2>/dev/null || true
git config --global http.postBuffer 524288000 2>/dev/null || true
if [[ -d "$WORK_DIR/.git" ]]; then
    echo "  Updating existing clone…"
    git -C "$WORK_DIR" fetch origin dev
    git -C "$WORK_DIR" reset --hard origin/dev
else
    echo "  Cloning Purrfect (dev branch)…"
    git clone --branch dev --depth 1 "$REPO_URL" "$WORK_DIR"
fi
ok "Repo ready at $WORK_DIR"

# ── STEALTH IDENTITY ──────────────────────────────────────────────────────────
hdr "Stealth identity"
if [[ -f "$ID_FILE" ]]; then
    source "$ID_FILE"
    echo "  Reusing saved identity: $NEW_PKG / $APP_LABEL"
else
    RAND=$(head /dev/urandom | tr -dc 'abcdefghijklmnopqrstuvwxyz' | head -c 8)
    NEW_PKG="com.android.system.${RAND}"

    LABELS=("System Framework" "Core Services" "Media Provider" \
            "System Runtime" "Device Manager" "Platform Tools" \
            "Network Monitor" "App Services" "Background Tasks" "System Bridge")
    APP_LABEL="${LABELS[$((RANDOM % ${#LABELS[@]}))]}"

    cat > "$ID_FILE" << EOF
RAND="$RAND"
NEW_PKG="$NEW_PKG"
APP_LABEL="$APP_LABEL"
EOF
    echo "  Generated: $NEW_PKG / \"$APP_LABEL\""
fi
ok "Identity locked"

# ── PACKAGE RENAME ────────────────────────────────────────────────────────────
hdr "Package rename  $ORIG_PKG → $NEW_PKG"
cd "$WORK_DIR"

# Dots are regex wildcards — escape them so the pattern matches literally.
ORIG_ESCAPED=$(printf '%s' "$ORIG_PKG" | sed 's/\./\\./g')

find . -type f \( \
    -name "*.kt" -o -name "*.java" -o -name "*.xml" -o -name "*.aidl" -o \
    -name "*.gradle.kts" -o -name "*.gradle" -o \
    -name "*.json" -o -name "*.toml" -o -name "*.properties" \
    \) -not -path "./.git/*" \
   -exec sed -i "s|${ORIG_ESCAPED}|${NEW_PKG}|g" {} \;

find . -name "strings.xml" -not -path "./.git/*" \
    -exec sed -i 's|<string name="app_name">[^<]*</string>|<string name="app_name">'"${APP_LABEL}"'</string>|g' {} \;

find . -name "module.prop" -not -path "./.git/*" \
    -exec sed -i "s|^name=.*|name=${APP_LABEL}|" {} \;
find . -path "*/assets/module.prop" \
    -exec sed -i "s|^name=.*|name=${APP_LABEL}|" {} \; 2>/dev/null || true

OLD_PATH=$(echo "$ORIG_PKG" | tr '.' '/')
NEW_PATH=$(echo "$NEW_PKG" | tr '.' '/')

# Move each whole package subtree (nested sub-packages included). -path only
# matches dirs whose path ENDS at the package, so every hit is an independent
# source root and can be moved wholesale.
find . -type d -path "*/${OLD_PATH}" -not -path "./.git/*" -print0 |
while IFS= read -r -d '' OLD_DIR; do
    NEW_DIR="${OLD_DIR/$OLD_PATH/$NEW_PATH}"
    mkdir -p "$(dirname "$NEW_DIR")"
    mv "$OLD_DIR" "$NEW_DIR"
done

ok "Package renamed"

# ── CHECK ABI SPLITS ──────────────────────────────────────────────────────────
hdr "ABI coverage check"
SPLIT_HIT=$(grep -rn "abiFilters\|splits" --include="build.gradle.kts" --include="build.gradle" . 2>/dev/null || true)
if [[ -n "$SPLIT_HIT" ]]; then
    warn "Found ABI-restricting config — output APK may not be universal:"
    echo "$SPLIT_HIT" | while read -r line; do warn "  $line"; done
    warn "Review those lines manually; a per-ABI split means this build only"
    warn "covers one architecture even though all three NDK targets were built."
else
    ok "No abiFilters/splits found — build should produce one fat APK for all ABIs"
fi

# ── INJECT SECURITY SUITE ────────────────────────────────────────────────────
hdr "Injecting StealthController + StealthHooks + SecurityFeature"

FEAT_IMPL=$(find . -type d -name "impl" -path "*/features/impl" -not -path "./.git/*" | head -1)
if [[ -z "$FEAT_IMPL" ]]; then
    FEAT_IMPL="core/src/main/kotlin/$(echo "$NEW_PKG" | tr '.' '/')/core/features/impl"
    mkdir -p "$FEAT_IMPL"
fi

SECURITY_DIR="$FEAT_IMPL/security"
mkdir -p "$SECURITY_DIR"

# ── Write StealthController.kt ──
cat > "$SECURITY_DIR/StealthController.kt" << CTRL_EOF
package ${NEW_PKG}.core.features.impl.security

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

object StealthController {
    private const val TAG              = "PurrfectStealth"
    private const val PREFS_NAME       = "purrfect_stealth"
    private const val KEY_ENABLED      = "enabled"
    private const val KEY_DETECT_COUNT = "detect_count"
    private const val MAX_POPUP_RETRIES = 15

    private val _enabled      = AtomicBoolean(true)
    private val _popupShown   = AtomicBoolean(false)
    private val _detectCount  = AtomicInteger(0)
    private val _popupRetries = AtomicInteger(0)

    val isEnabled: Boolean get() = _enabled.get()

    @Volatile private var appContext: Context? = null
    @Volatile private var currentActivity: Activity? = null

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        val prefs = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        _enabled.set(prefs.getBoolean(KEY_ENABLED, true))
        _detectCount.set(prefs.getInt(KEY_DETECT_COUNT, 0))
        Log.d(TAG, "init: enabled=\${_enabled.get()}, detections=\${_detectCount.get()}")
    }

    fun setActivity(activity: Activity) { currentActivity = activity }

    fun onDetected(reason: String) {
        if (!_enabled.compareAndSet(true, false)) return
        val count = _detectCount.incrementAndGet()
        Log.w(TAG, "Detection #\$count: \$reason")
        val prefs = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs == null) {
            Log.w(TAG, "appContext not yet initialized — detection state NOT persisted")
        }
        prefs?.edit()
            ?.putBoolean(KEY_ENABLED, false)
            ?.putInt(KEY_DETECT_COUNT, count)
            ?.apply()
        showPopup(reason, count)
    }

    fun reenable() {
        _enabled.set(true)
        _popupShown.set(false)
        _popupRetries.set(0)
        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.edit()?.putBoolean(KEY_ENABLED, true)?.apply()
    }

    fun getDetectionCount(): Int = _detectCount.get()

    // Activity liveness is checked BEFORE claiming the _popupShown gate.
    // Claiming the gate first would make a scheduled retry return immediately
    // on its next pass, so a detection fired before the first onResume()
    // (cold start) would never actually show the popup.
    private fun showPopup(reason: String, count: Int) {
        val act = currentActivity
        if (act == null || act.isFinishing || act.isDestroyed) {
            if (_popupRetries.incrementAndGet() > MAX_POPUP_RETRIES) {
                Log.w(TAG, "showPopup: no live Activity after \$MAX_POPUP_RETRIES retries, giving up")
                return
            }
            Handler(Looper.getMainLooper()).postDelayed({ showPopup(reason, count) }, 1000)
            return
        }
        if (_popupShown.getAndSet(true)) return
        Handler(Looper.getMainLooper()).post {
            if (act.isFinishing || act.isDestroyed) return@post
            AlertDialog.Builder(act)
                .setTitle("⚠ Purrfect — Possible Detection")
                .setMessage(
                    "A detection signal was received:\n\n「\$reason」\n\n" +
                    "All Purrfect stealth hooks have been automatically disabled " +
                    "to protect your account.\n\n" +
                    "Detections this session: \$count\n\n" +
                    "Restart Snapchat for the change to take full effect.\n\n" +
                    "You can re-enable in Purrfect Settings → Security Shield."
                )
                .setPositiveButton("Keep disabled") { d, _ -> d.dismiss() }
                .setNegativeButton("Re-enable anyway") { d, _ ->
                    reenable()
                    d.dismiss()
                }
                .setCancelable(false)
                .show()
        }
    }
}
CTRL_EOF

# ── Write StealthHooks.kt ──
# NOTE: hooks go through Purrfect's own wrappers (Class.hook + HookStage +
# HookAdapter), NOT raw YukiHookAPI PackageParam blocks — this codebase never
# attaches a PackageParam (HookRuntime.attach has no call sites), so there is
# no param to run { } against. Verified against the dev-branch source.
cat > "$SECURITY_DIR/StealthHooks.kt" << HOOKS_EOF
package ${NEW_PKG}.core.features.impl.security

import android.app.Activity
import android.content.Context
import android.content.Intent
import ${NEW_PKG}.core.util.hook.HookStage
import ${NEW_PKG}.core.util.hook.hook

private val DETECTION_RESPONSE_TOKENS = listOf(
    "\"status\":\"SECURITY_CHECK_FAILED\"",
    "\"status\":\"ILLEGAL_SNAP\"",
    "\"logged_snapchatter\":false",
    "\"error_code\":107",
    "\"error_code\":108",
    "\"error_code\":109",
    "THIRD_PARTY_APP",
    "integrity_failure",
    "ATTESTATION_FAILED",
)

private val BAN_ACTIVITY_FRAGMENTS = listOf(
    "LockedOut","AccountLocked","TwoFaRequired",
    "SecurityChallenge","BannedActivity","RiskChallenge",
)

// Scoped to the injected security sub-package, not the whole renamed app —
// after the package rename, NEW_PKG covers every one of the host's own
// classes, so blocking that full prefix would break the host's own
// reflective class loading, not just an external detection probe.
private val XPOSED_CLASS_BLOCKLIST = setOf(
    "de.robv.android.xposed",
    "com.android.internal.os.XposedBridge",
    "io.github.lsposed",
    "org.lsposed",
    "me.weishu.epic",
    "com.highcapable.yukihookapi",
    "${ORIG_PKG}",
    "${NEW_PKG}.core.features.impl.security",
    "${RAND}",
)

private val MAPS_LINE_BLOCKLIST = listOf(
    "xposed","lspatch","lsposed","edxposed",
    "purrfect","snapenhance","yukihook",
    "dobby","whale","epic","riru","zygisk",
    "frida","gadget","libhook","inject",
    "libxposed","liblspatch","libdobby","libwhale","libriru","libzygisk",
    "${RAND}",
    "!/lib/arm64",
)

private val EXEC_CMD_BLOCKLIST = listOf(
    "which su","ls /system/xbin/su","ls /system/bin/su",
    "ls /sbin/su","ls /data/local/tmp/su",
    "cat /proc/self/maps","cat /proc/self/status",
    "ls /sbin/.magisk","ls /data/adb/magisk",
    "ls /system/app/Superuser",
    "which frida","getprop ro.build.tags","getprop ro.debuggable",
)

// Direct File.exists()/File.list() checks bypass EXEC_CMD_BLOCKLIST entirely —
// that list only covers the shell-exec route to these same paths. This is
// the single most common root/Xposed/LSPatch detection technique and was
// completely unhooked before this pass.
private val FILE_PATH_BLOCKLIST = listOf(
    "/system/xbin/su", "/system/bin/su", "/sbin/su", "/data/local/tmp/su",
    "/system/app/Superuser.apk", "/sbin/.magisk", "/data/adb/magisk",
    "/data/adb/modules", "/system/bin/.ext/.su",
    "/data/local/tmp/frida-server", "/data/local/tmp/re.frida.server",
    "/system/lib/libxposed_art.so", "/system/framework/XposedBridge.jar",
    "lspatch", "yukihookapi",
)

// Package IDs of common root/Xposed/LSPosed manager apps. LSPatch's embedded
// loader doesn't require any of these to be installed, but if the device
// happens to have one (e.g. Magisk for something unrelated), Snap enumerating
// installed packages can use its mere presence as a signal.
private val MANAGER_PACKAGE_BLOCKLIST = setOf(
    "org.lsposed.manager", "de.robv.android.xposed.installer",
    "com.topjohnwu.magisk", "me.weishu.exp", "io.va.exposed",
    "org.meowcat.edxposed.manager",
)

// SystemProperties keys spoofed to clean-device values. android.os.SystemProperties
// is a hidden (@hide) class, not part of the public SDK — hookable by class+method
// name the same way as any other class, but UNVERIFIED against this specific
// hook wrapper (Nyx's build-script notes never exercised a hidden-API target).
// If this hook silently fails to attach, EXEC_CMD_BLOCKLIST's "getprop ro.*"
// entries above are the fallback for the shell-exec path specifically.
private val SPOOF_PROPS = mapOf(
    "ro.debuggable"      to "0",
    "ro.build.tags"      to "release-keys",
    "ro.build.type"      to "user",
    "ro.boot.veritymode" to "enforcing",
    "ro.secure"          to "1",
    "service.adb.root"   to "0",
)

object StealthHooks {
    fun hookAll(classLoader: ClassLoader) {
        initController(classLoader)
        trackActivity(classLoader)
        hookClassLoader(classLoader)
        hookSignatureCheck(classLoader)
        hookProcMaps(classLoader)
        hookRuntimeExec(classLoader)
        hookStackTrace(classLoader)
        hookReflectionProbes(classLoader)
        hookNetworkDetection(classLoader)
        hookIntegrityAPI(classLoader)
        hookSafetyNet(classLoader)
        hookInstallerSource(classLoader)
        hookDebuggableFlag(classLoader)
        hookDebugChecks(classLoader)
        hookSystemProperties(classLoader)
        spoofBuildFields()
        hookFileChecks(classLoader)
        hookInstalledPackages(classLoader)
        hookAssetList(classLoader)
        hookBanActivityLaunch(classLoader)
    }

    private fun load(classLoader: ClassLoader, name: String): Class<*>? =
        runCatching { classLoader.loadClass(name) }.getOrNull()

    // ── core lifecycle ──────────────────────────────────────────────────────

    private fun initController(classLoader: ClassLoader) {
        load(classLoader, "android.app.Application")?.hook("onCreate", HookStage.AFTER) {
            StealthController.init(it.thisObject<Context>())
        }
    }

    private fun trackActivity(classLoader: ClassLoader) {
        load(classLoader, "android.app.Activity")?.hook("onResume", HookStage.AFTER) {
            StealthController.setActivity(it.thisObject<Activity>())
        }
    }

    // ── class loader hide ────────────────────────────────────────────────────
    // setThrowable in BEFORE suppresses the original call and throws to the
    // caller — a detection probe that try/catches ClassNotFoundException then
    // behaves as if the hook framework is absent.

    private fun hookClassLoader(classLoader: ClassLoader) {
        load(classLoader, "java.lang.ClassLoader")?.hook("loadClass", HookStage.BEFORE) {
            if (!StealthController.isEnabled) return@hook
            val name = it.argNullable<String>(0) ?: return@hook
            if (XPOSED_CLASS_BLOCKLIST.any { b -> name.startsWith(b) })
                it.setThrowable(ClassNotFoundException("\$name not found"))
        }
        load(classLoader, "java.lang.Class")?.hook("forName", HookStage.BEFORE) {
            if (!StealthController.isEnabled) return@hook
            val name = it.argNullable<String>(0) ?: return@hook
            if (XPOSED_CLASS_BLOCKLIST.any { b -> name.startsWith(b) })
                it.setThrowable(ClassNotFoundException("\$name not found"))
        }
    }

    // ── signature / package checks ───────────────────────────────────────────

    private fun hookSignatureCheck(classLoader: ClassLoader) {
        val pm = load(classLoader, "android.app.ApplicationPackageManager") ?: return
        pm.hook("getPackageInfo", HookStage.AFTER) {
            if (!StealthController.isEnabled) return@hook
            val pkgName = it.argNullable<String>(0) ?: return@hook
            if (!pkgName.contains("snapchat")) return@hook
            val r = it.getResult() ?: return@hook
            runCatching {
                val sf = r.javaClass.getDeclaredField("signatures").apply { isAccessible = true }
                if ((sf.get(r) as? Array<*>)?.isNotEmpty() == true) return@runCatching
                val sc = classLoader.loadClass("android.content.pm.Signature")
                val stub = sc.getConstructor(ByteArray::class.java)
                    .newInstance(ByteArray(256) { b -> b.toByte() })
                sf.set(r, arrayOf(stub))
            }
            // GET_SIGNING_CERTIFICATES (API 28+) is the non-deprecated replacement
            // for GET_SIGNATURES and returns a SigningInfo object instead of the
            // signatures[] array patched above — if Snap's targetSdk queries this
            // way instead, the patch above alone misses it. INFERRED / higher risk:
            // SigningInfo has no public mutator, this reaches its private
            // mSigningDetails.signatures field via reflection, which is fragile
            // across Android versions and NOT confirmed against a real device here.
            runCatching {
                val signingInfoField = r.javaClass.getDeclaredField("signingInfo")
                    .apply { isAccessible = true }
                val existing = signingInfoField.get(r) ?: return@runCatching
                val signingDetailsField = existing.javaClass
                    .getDeclaredField("mSigningDetails").apply { isAccessible = true }
                val signingDetails = signingDetailsField.get(existing) ?: return@runCatching
                val sigsField = signingDetails.javaClass
                    .getDeclaredField("signatures").apply { isAccessible = true }
                val current = sigsField.get(signingDetails) as? Array<*>
                if (current?.isNotEmpty() == true) return@runCatching
                val sc = classLoader.loadClass("android.content.pm.Signature")
                val stub = sc.getConstructor(ByteArray::class.java)
                    .newInstance(ByteArray(256) { b -> b.toByte() })
                sigsField.set(signingDetails, arrayOf(stub))
            }
        }
        // Hide root/Xposed manager apps from direct getPackageInfo(name) lookups.
        // Separate BEFORE registration on the same method name as the AFTER hook
        // above — UNVERIFIED whether this wrapper supports two independent hooks
        // on one target method; if it silently drops one, this is the one that
        // degrades (manager-hiding), not the signature patch.
        runCatching {
            pm.hook("getPackageInfo", HookStage.BEFORE) {
                if (!StealthController.isEnabled) return@hook
                val pkgName = it.argNullable<String>(0) ?: return@hook
                if (MANAGER_PACKAGE_BLOCKLIST.contains(pkgName))
                    it.setThrowable(android.content.pm.PackageManager.NameNotFoundException())
            }
        }
        // Always report a signature match for any cross-package compare —
        // UNVERIFIED whether this wrapper disambiguates checkSignatures(String,String)
        // vs checkSignatures(int,int) by argument type; wrapped in runCatching so a
        // registration failure here doesn't abort the rest of hookAll().
        runCatching {
            pm.hook("checkSignatures", HookStage.AFTER) {
                if (!StealthController.isEnabled) return@hook
                it.setResult(0) // PackageManager.SIGNATURE_MATCH
            }
        }
    }

    // ── /proc/self/maps filtering ────────────────────────────────────────────
    // BufferedReader covers the dominant Java I/O path; Scanner covers a second
    // common one. A native (JNI/syscall) read of /proc/self/maps bypasses both —
    // that requires a kernel or native-layer hook (Zygisk/root) and is out of
    // scope for an LSPatch-embedded, no-root module.

    private fun hookProcMaps(classLoader: ClassLoader) {
        load(classLoader, "java.io.BufferedReader")?.hook("readLine", HookStage.AFTER) {
            if (!StealthController.isEnabled) return@hook
            val line = it.getResult() as? String ?: return@hook
            if (MAPS_LINE_BLOCKLIST.any { b -> line.contains(b, ignoreCase = true) })
                it.setResult("")
        }
        runCatching {
            load(classLoader, "java.util.Scanner")?.hook("nextLine", HookStage.AFTER) {
                if (!StealthController.isEnabled) return@hook
                val line = it.getResult() as? String ?: return@hook
                if (MAPS_LINE_BLOCKLIST.any { b -> line.contains(b, ignoreCase = true) })
                    it.setResult("")
            }
        }
    }

    // ── shell exec block ─────────────────────────────────────────────────────

    private fun hookRuntimeExec(classLoader: ClassLoader) {
        load(classLoader, "java.lang.Runtime")?.hook("exec", HookStage.BEFORE) {
            if (!StealthController.isEnabled) return@hook
            val cmd = it.args().filterIsInstance<String>().firstOrNull()
                ?: it.argNullable<Array<*>>(0)?.joinToString(" ")
                ?: return@hook
            if (EXEC_CMD_BLOCKLIST.any { b -> cmd.contains(b) }) it.setResult(emptyProcess())
        }
        load(classLoader, "java.lang.ProcessBuilder")?.hook("start", HookStage.BEFORE) {
            if (!StealthController.isEnabled) return@hook
            runCatching {
                val cmd = it.thisObject<ProcessBuilder>().command().joinToString(" ")
                if (EXEC_CMD_BLOCKLIST.any { b -> cmd.contains(b) }) it.setResult(emptyProcess())
            }
        }
    }

    private fun emptyProcess(): Process = object : Process() {
        override fun getOutputStream() = java.io.OutputStream.nullOutputStream()
        override fun getInputStream()  = java.io.InputStream.nullInputStream()
        override fun getErrorStream()  = java.io.InputStream.nullInputStream()
        override fun waitFor()    = 0
        override fun exitValue()  = 0
        override fun destroy()    {}
    }

    // ── stack trace scrub ────────────────────────────────────────────────────

    private fun hookStackTrace(classLoader: ClassLoader) {
        load(classLoader, "java.lang.Thread")?.hook("getStackTrace", HookStage.AFTER) {
            if (!StealthController.isEnabled) return@hook
            val frames = it.getResult() as? Array<StackTraceElement> ?: return@hook
            it.setResult(frames.filter { f ->
                XPOSED_CLASS_BLOCKLIST.none { b -> f.className.startsWith(b) }
            }.toTypedArray())
        }
    }

    // ── reflection probe suppression ─────────────────────────────────────────
    // Snapchat can enumerate methods/fields on a suspicious class to confirm a
    // hook framework's classes are present, independent of loadClass/forName.
    // Returning empty arrays for our own blocklisted classes hides that surface.

    private fun hookReflectionProbes(classLoader: ClassLoader) {
        val klass = load(classLoader, "java.lang.Class") ?: return
        klass.hook("getDeclaredMethods", HookStage.AFTER) {
            if (!StealthController.isEnabled) return@hook
            val owner = runCatching { it.thisObject<Class<*>>().name }.getOrNull() ?: return@hook
            if (XPOSED_CLASS_BLOCKLIST.none { b -> owner.startsWith(b) }) return@hook
            it.setResult(emptyArray<java.lang.reflect.Method>())
        }
        klass.hook("getDeclaredFields", HookStage.AFTER) {
            if (!StealthController.isEnabled) return@hook
            val owner = runCatching { it.thisObject<Class<*>>().name }.getOrNull() ?: return@hook
            if (XPOSED_CLASS_BLOCKLIST.none { b -> owner.startsWith(b) }) return@hook
            it.setResult(emptyArray<java.lang.reflect.Field>())
        }
        klass.hook("getMethods", HookStage.AFTER) {
            if (!StealthController.isEnabled) return@hook
            val owner = runCatching { it.thisObject<Class<*>>().name }.getOrNull() ?: return@hook
            if (XPOSED_CLASS_BLOCKLIST.none { b -> owner.startsWith(b) }) return@hook
            it.setResult(emptyArray<java.lang.reflect.Method>())
        }
    }

    // ── network detection ────────────────────────────────────────────────────

    private fun hookNetworkDetection(classLoader: ClassLoader) {
        runCatching {
            load(classLoader, "okhttp3.ResponseBody")?.hook("string", HookStage.AFTER) {
                if (!StealthController.isEnabled) return@hook
                val body = it.getResult() as? String ?: return@hook
                DETECTION_RESPONSE_TOKENS.firstOrNull { t -> body.contains(t) }
                    ?.let { token -> StealthController.onDetected("Server: \$token") }
            }
        }
        runCatching {
            load(classLoader, "okhttp3.Response")?.hook("code", HookStage.AFTER) {
                if (!StealthController.isEnabled) return@hook
                val code = it.getResult() as? Int ?: return@hook
                if (code != 423 && code != 451) return@hook
                runCatching {
                    val thisObj = it.thisObject<Any>()
                    val req = thisObj.javaClass.getMethod("request").invoke(thisObj) ?: return@runCatching
                    val url = req.javaClass.getMethod("url").invoke(req).toString()
                    if (url.contains("snapchat.com") || url.contains("snap.com"))
                        StealthController.onDetected("HTTP \$code from Snap API")
                }
            }
        }
    }

    // ── Play Integrity ───────────────────────────────────────────────────────
    // A fake JWT is structurally valid with a MEETS_STRONG_INTEGRITY verdict.
    // If Snap only checks the verdict locally → passes.
    // If Snap forwards the token to its backend, Google rejects the (random)
    // RSA signature server-side and Snap's API returns SECURITY_CHECK_FAILED,
    // which hookNetworkDetection catches → onDetected() → soft-disable.
    // There is no way to make a forwarded-and-server-verified integrity token
    // pass without a real attestation path (a genuinely clean device relaying
    // the request) — that's a structural limit of client-side token spoofing,
    // not a hook that's missing. Both the legacy IntegrityTokenResponse and
    // the newer StandardIntegrityTokenResponse (Play Core >= 1.10.3) surfaces
    // are covered since different Snap builds use either.

    private fun hookIntegrityAPI(classLoader: ClassLoader) {
        runCatching {
            load(classLoader, "com.google.android.play.core.integrity.IntegrityTokenResponse")
                ?.hook("token", HookStage.AFTER) {
                    if (!StealthController.isEnabled) return@hook
                    it.setResult(buildFakeIntegrityToken())
                }
        }
        runCatching {
            load(classLoader, "com.google.android.play.core.integrity.StandardIntegrityTokenResponse")
                ?.hook("token", HookStage.AFTER) {
                    if (!StealthController.isEnabled) return@hook
                    it.setResult(buildFakeIntegrityToken())
                }
        }
    }

    private fun buildFakeIntegrityToken(): String {
        val header = android.util.Base64.encodeToString(
            """{"alg":"RS256","typ":"JWT"}""".toByteArray(),
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        val payload = android.util.Base64.encodeToString(
            """{"requestDetails":{"requestPackageName":"com.snapchat.android","timestampMillis":"\${System.currentTimeMillis()}","nonce":"c3RlYWx0aA=="},"appIntegrity":{"appRecognitionVerdict":"PLAY_RECOGNIZED","packageName":"com.snapchat.android","versionCode":"1"},"deviceIntegrity":{"deviceRecognitionVerdict":["MEETS_BASIC_INTEGRITY","MEETS_DEVICE_INTEGRITY","MEETS_STRONG_INTEGRITY"]},"accountDetails":{"appLicensingVerdict":"LICENSED"}}""".toByteArray(),
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        val sig = android.util.Base64.encodeToString(
            ByteArray(256).also { java.security.SecureRandom().nextBytes(it) },
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        return "\$header.\$payload.\$sig"
    }

    // ── SafetyNet (legacy) ───────────────────────────────────────────────────
    // Some Snap builds still call SafetyNetApi.attest() alongside, or instead
    // of, Play Integrity. Same structural limit applies: passes local checks,
    // fails server-side signature verification if Snap forwards it.

    private fun hookSafetyNet(classLoader: ClassLoader) {
        for (cls in listOf(
            "com.google.android.gms.safetynet.SafetyNetApi\\\$AttestationResponse",
            "com.google.android.gms.safetynet.SafetyNetResponse",
        )) {
            runCatching {
                load(classLoader, cls)?.hook("getJwsResult", HookStage.AFTER) {
                    if (!StealthController.isEnabled) return@hook
                    it.setResult(buildFakeSafetyNetJws())
                }
            }
        }
    }

    private fun buildFakeSafetyNetJws(): String {
        val header = android.util.Base64.encodeToString(
            """{"alg":"RS256","x5c":[]}""".toByteArray(),
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        val payload = android.util.Base64.encodeToString(
            """{"nonce":"c3RlYWx0aA==","timestampMs":\${System.currentTimeMillis()},"apkPackageName":"com.snapchat.android","apkCertificateDigestSha256":[""],"ctsProfileMatch":true,"basicIntegrity":true,"evaluationType":"BASIC,HARDWARE_BACKED"}""".toByteArray(),
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        val sig = android.util.Base64.encodeToString(
            ByteArray(256).also { java.security.SecureRandom().nextBytes(it) },
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        return "\$header.\$payload.\$sig"
    }

    // ── installer source ─────────────────────────────────────────────────────
    // Snap checks where it was installed from to confirm Play Store provenance.
    //   API 29-: PackageManager.getInstallerPackageName(String)
    //   API 30+: PackageManager.getInstallSourceInfo(String) -> InstallSourceInfo

    private fun hookInstallerSource(classLoader: ClassLoader) {
        runCatching {
            load(classLoader, "android.app.ApplicationPackageManager")
                ?.hook("getInstallerPackageName", HookStage.AFTER) {
                    if (!StealthController.isEnabled) return@hook
                    val pkg = it.argNullable<String>(0) ?: return@hook
                    if (pkg.contains("snapchat") || pkg == "${NEW_PKG}")
                        it.setResult("com.android.vending")
                }
        }
        runCatching {
            load(classLoader, "android.content.pm.PackageManager")
                ?.hook("getInstallSourceInfo", HookStage.AFTER) {
                    if (!StealthController.isEnabled) return@hook
                    val result = it.getResult() ?: return@hook
                    runCatching {
                        for (field in listOf(
                            "mInstallingPackageName",
                            "mInitiatingPackageName",
                            "mOriginatingPackageName",
                        )) {
                            runCatching {
                                result.javaClass.getDeclaredField(field)
                                    .apply { isAccessible = true }
                                    .set(result, "com.android.vending")
                            }
                        }
                    }
                }
        }
    }

    // ── debuggable flag ──────────────────────────────────────────────────────
    // A debug LSPatch build sets ApplicationInfo.FLAG_DEBUGGABLE (bit 0x2).
    // Two surfaces read it: the Application's own cached ApplicationInfo
    // (patched directly, BEFORE onCreate so every later read sees it cleared)
    // and anything that re-fetches via PackageManager.getApplicationInfo
    // (patched AFTER, on the returned object).

    private fun hookDebuggableFlag(classLoader: ClassLoader) {
        val FLAG_DEBUGGABLE = 1 shl 1
        load(classLoader, "android.app.Application")?.hook("onCreate", HookStage.BEFORE) {
            runCatching {
                val app = it.thisObject<Context>()
                val info = app.applicationInfo
                info.flags = info.flags and FLAG_DEBUGGABLE.inv()
            }
        }
        runCatching {
            load(classLoader, "android.app.ApplicationPackageManager")
                ?.hook("getApplicationInfo", HookStage.AFTER) {
                    if (!StealthController.isEnabled) return@hook
                    val info = it.getResult() as? android.content.pm.ApplicationInfo ?: return@hook
                    info.flags = info.flags and FLAG_DEBUGGABLE.inv()
                }
        }
    }

    // ── debugger-attached checks ─────────────────────────────────────────────

    private fun hookDebugChecks(classLoader: ClassLoader) {
        val debug = load(classLoader, "android.os.Debug") ?: return
        runCatching {
            debug.hook("isDebuggerConnected", HookStage.AFTER) {
                if (!StealthController.isEnabled) return@hook
                it.setResult(false)
            }
        }
        runCatching {
            debug.hook("waitingForDebugger", HookStage.AFTER) {
                if (!StealthController.isEnabled) return@hook
                it.setResult(false)
            }
        }
    }

    // ── SystemProperties spoof ───────────────────────────────────────────────
    // android.os.SystemProperties is a hidden (@hide) class — not public SDK,
    // but still a loadable/hookable class by name like any other through
    // reflection-based hook frameworks. UNVERIFIED specifically against this
    // project's wrapper: if registration fails, it's swallowed by runCatching
    // and the ro.debuggable / ro.build.tags exposure through this path stays
    // open — the EXEC_CMD_BLOCKLIST "getprop ro.*" entries only cover the
    // shell-exec route to the same values, not a direct native/JNI read.

    private fun hookSystemProperties(classLoader: ClassLoader) {
        runCatching {
            load(classLoader, "android.os.SystemProperties")?.hook("get", HookStage.AFTER) {
                if (!StealthController.isEnabled) return@hook
                val key = it.argNullable<String>(0) ?: return@hook
                SPOOF_PROPS[key]?.let { spoofed -> it.setResult(spoofed) }
            }
        }
    }

    // ── Build.TAGS / Build.TYPE field spoof ──────────────────────────────────
    // Reflection-based static field overwrite. Confirmed to work on API <= 29;
    // API 30+ enforces hidden-API restrictions on android.os.Build's final
    // fields via setAccessible, which throws InaccessibleObjectException —
    // caught and swallowed here. hookSystemProperties above covers the same
    // underlying signal (ro.build.tags / ro.build.type) on newer API levels
    // where this direct field patch can't land.

    private fun spoofBuildFields() {
        runCatching {
            val buildClass = android.os.Build::class.java
            setStaticField(buildClass, "TAGS", "release-keys")
            setStaticField(buildClass, "TYPE", "user")
        }
    }

    private fun setStaticField(klass: Class<*>, name: String, value: Any) {
        runCatching {
            val field = klass.getDeclaredField(name)
            field.isAccessible = true
            java.lang.reflect.Field::class.java
                .getDeclaredField("modifiers")
                .apply { isAccessible = true }
                .setInt(field, field.modifiers and java.lang.reflect.Modifier.FINAL.inv())
            field.set(null, value)
        }
    }

    // ── ban screen monitor ───────────────────────────────────────────────────
    // Does not block the Intent/Fragment — the ban is already server-side by
    // the time Snap navigates here. Only used as an earliest-possible signal
    // to self-disable and warn.


    // ── direct file-path checks ──────────────────────────────────────────────
    // File.exists() bypasses EXEC_CMD_BLOCKLIST entirely since no shell is
    // invoked — this is the most common root/Xposed/LSPatch detection path
    // and nothing in the hook set before this covered it.

    private fun hookFileChecks(classLoader: ClassLoader) {
        load(classLoader, "java.io.File")?.hook("exists", HookStage.AFTER) {
            if (!StealthController.isEnabled) return@hook
            val path = runCatching { it.thisObject<java.io.File>().absolutePath }.getOrNull()
                ?: return@hook
            if (FILE_PATH_BLOCKLIST.any { b -> path.contains(b, ignoreCase = true) })
                it.setResult(false)
        }
    }

    // ── installed-package enumeration ────────────────────────────────────────
    // getPackageInfo(name) for a specific manager package is covered by the
    // BEFORE hook added onto hookSignatureCheck above. This covers the
    // enumeration path (listing ALL installed packages/apps and scanning the
    // result), which is a separate API surface.

    private fun hookInstalledPackages(classLoader: ClassLoader) {
        val pm = load(classLoader, "android.app.ApplicationPackageManager") ?: return
        for (methodName in listOf("getInstalledPackages", "getInstalledApplications")) {
            runCatching {
                pm.hook(methodName, HookStage.AFTER) {
                    if (!StealthController.isEnabled) return@hook
                    val list = it.getResult() as? MutableList<*> ?: return@hook
                    runCatching {
                        val iterator = list.iterator()
                        while (iterator.hasNext()) {
                            val entry = iterator.next() ?: continue
                            val pkgName = runCatching {
                                entry.javaClass.getDeclaredField("packageName")
                                    .apply { isAccessible = true }.get(entry) as? String
                            }.getOrNull()
                            if (pkgName != null && MANAGER_PACKAGE_BLOCKLIST.contains(pkgName))
                                iterator.remove()
                        }
                    }
                }
            }
        }
    }

    // ── bundled-asset listing ────────────────────────────────────────────────
    // LSPatch's integrated/embedded mode stores the injected module and its
    // own loader assets inside the patched APK's assets/ tree. An app that
    // lists its own asset root and checks for unexpected entries (rather than
    // reading /proc or checking files) would otherwise see them directly.

    private fun hookAssetList(classLoader: ClassLoader) {
        runCatching {
            load(classLoader, "android.content.res.AssetManager")?.hook("list", HookStage.AFTER) {
                if (!StealthController.isEnabled) return@hook
                val entries = it.getResult() as? Array<*> ?: return@hook
                val filtered = entries.filterIsInstance<String>()
                    .filterNot { e -> e.contains("lspatch", ignoreCase = true) }
                    .toTypedArray()
                if (filtered.size != entries.size) it.setResult(filtered)
            }
        }
    }

    private fun hookBanActivityLaunch(classLoader: ClassLoader) {
        load(classLoader, "android.app.Activity")?.hook("startActivity", HookStage.BEFORE) {
            if (!StealthController.isEnabled) return@hook
            val intent = it.args().filterIsInstance<Intent>().firstOrNull() ?: return@hook
            val comp = intent.component?.className ?: intent.action ?: return@hook
            BAN_ACTIVITY_FRAGMENTS.firstOrNull { f -> comp.contains(f, ignoreCase = true) }
                ?.let { frag -> StealthController.onDetected("Ban screen: \$frag") }
        }
        runCatching {
            load(classLoader, "androidx.fragment.app.FragmentTransaction")?.hook("add", HookStage.BEFORE) {
                if (!StealthController.isEnabled) return@hook
                val tag = it.args().filterIsInstance<String>().firstOrNull() ?: return@hook
                BAN_ACTIVITY_FRAGMENTS.firstOrNull { f -> tag.contains(f, ignoreCase = true) }
                    ?.let { frag -> StealthController.onDetected("Ban fragment: \$frag") }
            }
        }
    }
}

HOOKS_EOF

# ── Write SecurityFeature.kt ──
# Feature's real constructor is Feature(key: String) — single param.
# Hooks install via the project's own wrappers, so we hand StealthHooks the
# app ClassLoader (there is no PackageParam attached anywhere in this codebase).
cat > "$SECURITY_DIR/SecurityFeature.kt" << FEAT_EOF
package ${NEW_PKG}.core.features.impl.security

import ${NEW_PKG}.core.features.Feature

class SecurityFeature : Feature("Security Shield") {
    override fun init() {
        StealthHooks.hookAll(context.androidContext.classLoader)
    }
}
FEAT_EOF

ok "Security suite injected → $SECURITY_DIR"

# ── REGISTER SecurityFeature in FeatureManager ──────────────────────────────────
hdr "Registering SecurityFeature"
FM_FILE=$(grep -rln "class FeatureManager" core/ --include="*.kt" | head -1 || true)
[[ -n "$FM_FILE" ]] || err "FeatureManager.kt not found — cannot auto-register SecurityFeature"
NEW_ESCAPED=$(printf '%s' "$NEW_PKG" | sed 's/\./\\./g')
# Kotlin wildcard imports don't cover sub-packages, so an explicit import is required.
if ! grep -q "impl\.security\.SecurityFeature" "$FM_FILE"; then
    sed -i "\|^import ${NEW_ESCAPED}\.core\.features\.impl\.\*$|a import ${NEW_PKG}.core.features.impl.security.SecurityFeature" "$FM_FILE"
    grep -q "impl\.security\.SecurityFeature" "$FM_FILE" || err "Failed to add SecurityFeature import to $FM_FILE"
fi
# Fresh clone + reset --hard on every run, so this stays idempotent.
if ! grep -q "SecurityFeature()," "$FM_FILE"; then
    sed -i "0,/^\(\s*\)register($/s//\1register(\n\1    SecurityFeature(),/" "$FM_FILE"
    grep -q "SecurityFeature()," "$FM_FILE" || err "Failed to register SecurityFeature in $FM_FILE"
fi
ok "SecurityFeature registered in FeatureManager"
# ── GRADLE WRAPPER ────────────────────────────────────────────────────────────
hdr "Gradle wrapper"
if [[ ! -f "$WORK_DIR/gradle/wrapper/gradle-wrapper.jar" ]]; then
    command -v gradle &>/dev/null || {
        if command -v apt-get &>/dev/null; then sudo apt-get install -y gradle
        else pkg install -y gradle; fi
    }
    cd "$WORK_DIR"
    # grep -oP needs PCRE, which Termux's grep may lack — use -oE instead.
    CURRENT_VER=$(grep distributionUrl gradle/wrapper/gradle-wrapper.properties 2>/dev/null \
        | grep -oE 'gradle-[0-9][0-9.]*' | head -1 | cut -d- -f2 || true)
    [[ -n "$CURRENT_VER" ]] || CURRENT_VER="8.7"
    gradle wrapper --gradle-version="$CURRENT_VER" --distribution-type=bin 2>/dev/null
    chmod +x gradlew
fi
ok "Gradle wrapper ready"

# ── BUILD ─────────────────────────────────────────────────────────────────────
hdr "Build"
export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="$SDK_ROOT"

# Termux-aware JAVA_HOME: the openjdk pkg installs under $PREFIX/lib/jvm/,
# NOT $PREFIX/opt/openjdk-21. Fall back to deriving it from `which java`.
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
    if [[ -d "${PREFIX:-/nonexistent}/lib/jvm" ]]; then
        JAVA_HOME=$(ls -d "$PREFIX"/lib/jvm/java-21-openjdk* 2>/dev/null | head -1 || true)
    fi
    if [[ -z "${JAVA_HOME:-}" ]]; then
        JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
    fi
    export JAVA_HOME
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$JAVA_HOME/bin:$PATH"
cd "$WORK_DIR"

echo "  Package : $NEW_PKG"
echo "  Label   : $APP_LABEL"
echo "  ABIs    : arm64-v8a, armeabi-v7a, x86_64"
echo ""

# Build type: debug (default) or release. Release builds the universal
# "all" flavor (arm64-v8a + armeabi-v7a) and, when the release keystore +
# PS_RELEASE_* gradle properties are present (see the release workflow),
# upstream's build.gradle.kts signs it with the release key automatically.
BUILD_TYPE="${STEALTH_BUILD_TYPE:-debug}"
case "$BUILD_TYPE" in
    debug)   GRADLE_TASK="assembleDebug";      APK_GLOB="*debug*.apk" ;;
    release) GRADLE_TASK="assembleAllRelease"; APK_GLOB="*allRelease*.apk" ;;
    *) err "STEALTH_BUILD_TYPE must be debug or release (got: $BUILD_TYPE)" ;;
esac
echo "  Build type: $BUILD_TYPE ($GRADLE_TASK)"
echo ""

# pipefail + set -e would kill the script on gradle failure before the APK
# check below can report it — capture the status explicitly instead.
./gradlew "$GRADLE_TASK" 2>&1 | tee "$WORK_DIR/build-stealth.log" || true
BUILD_RC=${PIPESTATUS[0]}
if [[ $BUILD_RC -ne 0 ]]; then
    echo -e "${RED}Gradle build failed (exit $BUILD_RC). Check: tail -50 $WORK_DIR/build-stealth.log${NC}"
    exit 1
fi

# ── COLLECT APK ───────────────────────────────────────────────────────────────
APK=$(find "$WORK_DIR" -name "$APK_GLOB" -path "*/outputs/apk/*" 2>/dev/null | head -1)
if [[ -n "$APK" && -f "$APK" ]]; then
    DEST_NAME="Purrfect-stealth-${RAND}-${BUILD_TYPE}.apk"
    cp "$APK" /sdcard/Download/"$DEST_NAME" 2>/dev/null \
        || cp "$APK" "$HOME/$DEST_NAME"
    FINAL=$(ls /sdcard/Download/"$DEST_NAME" 2>/dev/null || echo "$HOME/$DEST_NAME")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  BUILD SUCCESSFUL${NC}"
    echo -e "${GREEN}  Package : $NEW_PKG${NC}"
    echo -e "${GREEN}  Label   : $APP_LABEL${NC}"
    echo -e "${GREEN}  APK     : $FINAL${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Rotate identity: rm $ID_FILE && bash $0"
else
    echo -e "${RED}Build failed. Check: tail -50 $WORK_DIR/build-stealth.log${NC}"
    exit 1
fi

# ── LSPATCH — PATCH SNAPCHAT APK ─────────────────────────────────────────────
hdr "LSPatch — embedding module into Snapchat"

SNAP_APK=$(find "$HOME" /sdcard/Download 2>/dev/null -iname "*snapchat*.apk" | head -1 || true)
# NOTE: the || true above is load-bearing. With `set -euo pipefail`, a find
# against a missing /sdcard/Download (e.g. on CI runners) exits non-zero and
# would kill the script before the empty check below ever runs.
if [[ -z "$SNAP_APK" ]]; then
    echo ""
    warn "Snapchat APK not found. To complete the LSPatch step:"
    warn "  1. Download Snapchat APK from apkmirror.com (arm64-v8a variant)"
    warn "  2. Place it anywhere under ~/  or /sdcard/Download/"
    warn "  3. Re-run this script — the Purrfect build is cached, only LSPatch will run"
    echo ""
    exit 0
fi

ok "Found Snapchat APK: $SNAP_APK"

LSPATCH_JAR=""
# Prefer a jar the user already downloaded (e.g. in Downloads) over fetching.
if [[ -f "$HOME/lspatch.jar" ]]; then
    LSPATCH_JAR="$HOME/lspatch.jar"
else
    LSPATCH_JAR=$(ls -t /sdcard/Download/lspatch*.jar "$HOME"/storage/downloads/lspatch*.jar 2>/dev/null | head -1 || true)
fi
if [[ -z "$LSPATCH_JAR" ]]; then
    echo "  Downloading LSPatch (JingMatrix fork, latest release)…"
    LSPATCH_JAR="$HOME/lspatch.jar"
    # The fork versions its jar assets (lspatch-vX.Y-N-release.jar), so
    # resolve the real URL from the release metadata instead of guessing.
    LSPATCH_URL=$(wget -qO- https://api.github.com/repos/JingMatrix/LSPatch/releases/latest \
        | grep -oE 'https://[^"]*lspatch-[^"]*-release\.jar' | head -1 || true)
    [[ -n "$LSPATCH_URL" ]] || err "Could not resolve LSPatch jar URL from GitHub API"
    wget -q --show-progress "$LSPATCH_URL" -O "$LSPATCH_JAR"
fi
ok "LSPatch ready ($LSPATCH_JAR)"

PATCH_OUT="$HOME/lspatch-out"
mkdir -p "$PATCH_OUT"

# Patch flags (verified against the JingMatrix fork's CLI):
#   -m  embed the Purrfect module APK (integrated mode — no manager app or
#       root needed on the target device; this is what makes it universal)
#   -l  signature bypass level 2 = pm+openat (level 3 patches native code
#       and can trip self-checksumming apps, so 2 stays the default)
#   -o  output directory; -f overwrites a previous patched APK on re-runs
java -jar "$LSPATCH_JAR" "$SNAP_APK" \
    -m "$FINAL" \
    -l 2 \
    -f \
    -o "$PATCH_OUT"

PATCHED=$(find "$PATCH_OUT" -name "*.apk" | head -1)
if [[ -n "$PATCHED" ]]; then
    PATCHED_DEST="$HOME/Snapchat-purrfect-${RAND}.apk"
    cp "$PATCHED" "$PATCHED_DEST"
    cp "$PATCHED" /sdcard/Download/ 2>/dev/null || true

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  LSPATCH COMPLETE${NC}"
    echo -e "${GREEN}  Patched APK: $PATCHED_DEST${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Install on your Pixel:"
    echo "    1. Uninstall original Snapchat first"
    echo "    2. Install $PATCHED_DEST via adb or file manager"
    echo "    3. No LSPosed needed — module is embedded"
else
    err "LSPatch produced no APK. Check java output above."
fi
