#!/usr/bin/env bash
# purrfect-stealth-build.sh  v2
# Clones Purrfect (me.eternal.purrfect), randomises package + module identity,
# injects the security suite (StealthController + StealthHooks + SecurityFeature),
# then builds a signed debug APK.
#
# Run in UserLAnd (Ubuntu), Termux (F-Droid), or any Linux with JDK 21.
#
# Usage:
#   bash purrfect-stealth-build.sh
#
# First run: generates a random package name saved to .stealth-id.
# Rotate identity: rm .stealth-id && bash purrfect-stealth-build.sh

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

# ── DEPS ──────────────────────────────────────────────────────────────────────
hdr "Dependencies"
if command -v apt-get &>/dev/null; then
    sudo apt-get install -y --no-install-recommends git openjdk-21-jdk wget unzip 2>/dev/null || true
elif command -v pkg &>/dev/null; then
    pkg install -y git openjdk-21 wget 2>/dev/null || true
fi
java -version 2>&1 | grep -q "21\." || err "JDK 21 required"
command -v git &>/dev/null           || err "git not found"
ok "Deps ready"

# ── ANDROID SDK ───────────────────────────────────────────────────────────────
hdr "Android SDK"
SDK_ROOT="${ANDROID_HOME:-$HOME/android-sdk}"
if [[ ! -d "$SDK_ROOT/cmdline-tools/latest/bin" ]]; then
    mkdir -p "$SDK_ROOT/cmdline-tools"
    wget -q --show-progress \
        "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -O /tmp/cmdtools.zip
    unzip -q /tmp/cmdtools.zip -d /tmp/ct_raw
    mv /tmp/ct_raw/cmdline-tools "$SDK_ROOT/cmdline-tools/latest"
    rm -rf /tmp/cmdtools.zip /tmp/ct_raw
fi
export ANDROID_HOME="$SDK_ROOT"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
yes | sdkmanager --licenses > /dev/null 2>&1 || true
sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools" \
    --sdk_root="$ANDROID_HOME" 2>&1 | tail -3
ok "SDK ready"

# ── CLONE / UPDATE ────────────────────────────────────────────────────────────
hdr "Repository"
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

# Text replacement in all source/config files
find . -type f \( \
    -name "*.kt" -o -name "*.java" -o -name "*.xml" -o \
    -name "*.gradle.kts" -o -name "*.gradle" -o \
    -name "*.json" -o -name "*.toml" -o -name "*.properties" \
    \) -not -path "./.git/*" \
   -exec sed -i "s|${ORIG_PKG}|${NEW_PKG}|g" {} \;

# App label in strings resources
find . -name "strings.xml" -not -path "./.git/*" \
    -exec sed -i 's|<string name="app_name">[^<]*</string>|<string name="app_name">'"${APP_LABEL}"'</string>|g' {} \;

# Module title visible in LSPosed manager
find . -name "module.prop" -not -path "./.git/*" \
    -exec sed -i "s|^name=.*|name=${APP_LABEL}|" {} \;
find . -path "*/assets/module.prop" \
    -exec sed -i "s|^name=.*|name=${APP_LABEL}|" {} \; 2>/dev/null || true

# Move source directory tree to match new package
OLD_PATH=$(echo "$ORIG_PKG" | tr '.' '/')
NEW_PATH=$(echo "$NEW_PKG" | tr '.' '/')

find . -type d -path "*/${OLD_PATH}" -not -path "./.git/*" | while read -r OLD_DIR; do
    NEW_DIR="${OLD_DIR/$OLD_PATH/$NEW_PATH}"
    mkdir -p "$NEW_DIR"
    find "$OLD_DIR" -maxdepth 1 -type f \( -name "*.kt" -o -name "*.java" \) \
        -exec mv {} "$NEW_DIR/" \; 2>/dev/null || true
done

ok "Package renamed"

# ── INJECT SECURITY SUITE ────────────────────────────────────────────────────
hdr "Injecting StealthController + StealthHooks + SecurityFeature"

# Locate the features/impl directory in the renamed tree
FEAT_IMPL=$(find . -type d -name "impl" -path "*/features/impl" -not -path "./.git/*" | head -1)
if [[ -z "$FEAT_IMPL" ]]; then
    # Fallback: construct path manually from new package
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

    private val _enabled     = AtomicBoolean(true)
    private val _popupShown  = AtomicBoolean(false)
    private val _detectCount = AtomicInteger(0)

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
        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.edit()
            ?.putBoolean(KEY_ENABLED, false)
            ?.putInt(KEY_DETECT_COUNT, count)
            ?.apply()
        showPopup(reason, count)
    }

    fun reenable() {
        _enabled.set(true)
        _popupShown.set(false)
        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.edit()?.putBoolean(KEY_ENABLED, true)?.apply()
    }

    fun getDetectionCount(): Int = _detectCount.get()

    private fun showPopup(reason: String, count: Int) {
        if (_popupShown.getAndSet(true)) return
        val act = currentActivity
        if (act == null || act.isFinishing || act.isDestroyed) {
            Handler(Looper.getMainLooper()).postDelayed({ showPopup(reason, count) }, 1000)
            return
        }
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
cat > "$SECURITY_DIR/StealthHooks.kt" << HOOKS_EOF
package ${NEW_PKG}.core.features.impl.security

import android.app.Activity
import com.highcapable.yukihookapi.hook.factory.method
import com.highcapable.yukihookapi.hook.log.YLog
import com.highcapable.yukihookapi.hook.param.PackageParam
import com.highcapable.yukihookapi.hook.type.java.BooleanType
import com.highcapable.yukihookapi.hook.type.java.StringClass

private val DETECTION_RESPONSE_TOKENS = listOf(
    "\"status\":\"SECURITY_CHECK_FAILED\"",
    "\"status\":\"ILLEGAL_SNAP\"",
    "\"logged_snapchatter\":false",
    "\"error_code\":107",
    "\"error_code\":108",
    "\"error_code\":109",
    "THIRD_PARTY_APP",
)

private val BAN_ACTIVITY_FRAGMENTS = listOf(
    "LockedOut","AccountLocked","TwoFaRequired",
    "SecurityChallenge","BannedActivity","RiskChallenge",
)

private val XPOSED_CLASS_BLOCKLIST = setOf(
    "de.robv.android.xposed.XposedBridge",
    "de.robv.android.xposed.XposedHelpers",
    "de.robv.android.xposed.callbacks.XC_MethodHook",
    "com.android.internal.os.XposedBridge",
    "io.github.lsposed.lspatch.loader.LSPLoader",
    "org.lsposed.lspatch",
    "me.weishu.epic.art.Epic",
    "com.highcapable.yukihookapi",
    "${ORIG_PKG}",
    "${NEW_PKG}",
    "${RAND}",
)

private val MAPS_LINE_BLOCKLIST = listOf(
    "xposed","lspatch","lsposed","edxposed",
    "purrfect","snapenhance","yukihook",
    "dobby","whale","epic","riru","zygisk",
    "arm64-v8a/libxposed","arm64-v8a/liblspatch","arm64-v8a/libdobby",
    "arm64-v8a/libwhale","arm64-v8a/libriru","arm64-v8a/libzygisk",
    "!/lib/arm64",
    "${RAND}",
)

private val EXEC_CMD_BLOCKLIST = listOf(
    "which su","ls /system/xbin/su","ls /system/bin/su",
    "ls /sbin/su","ls /data/local/tmp/su",
    "cat /proc/self/maps",
    "ls /sbin/.magisk","ls /data/adb/magisk",
    "ls /system/app/Superuser",
)

object StealthHooks {
    fun hookAll(param: PackageParam) = param.run {
        initController(); trackActivity(); hookClassLoader()
        hookSignatureCheck(); hookProcMaps(); hookRuntimeExec()
        hookStackTrace(); hookNetworkDetection(); hookIntegrityAPI()
        hookBanActivityLaunch()
    }

    private fun PackageParam.initController() {
        "android.app.Application".toClass().method { name = "onCreate" }.hook {
            after { StealthController.init(instance<android.app.Application>()) }
        }
    }

    private fun PackageParam.trackActivity() {
        "android.app.Activity".toClass().method { name = "onResume" }.hook {
            after { StealthController.setActivity(instance<Activity>()) }
        }
    }

    private fun PackageParam.hookClassLoader() {
        if (!StealthController.isEnabled) return
        "java.lang.ClassLoader".toClass().apply {
            method { name = "loadClass"; param(StringClass) }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val name = args[0] as? String ?: return@before
                    if (XPOSED_CLASS_BLOCKLIST.any { name.startsWith(it) })
                        throwToApp(ClassNotFoundException("\$name not found"))
                }
            }
            method { name = "loadClass"; param(StringClass, BooleanType) }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val name = args[0] as? String ?: return@before
                    if (XPOSED_CLASS_BLOCKLIST.any { name.startsWith(it) })
                        throwToApp(ClassNotFoundException("\$name not found"))
                }
            }
        }
        "java.lang.Class".toClass().method { name = "forName"; param(StringClass) }.hook {
            before {
                if (!StealthController.isEnabled) return@before
                val name = args[0] as? String ?: return@before
                if (XPOSED_CLASS_BLOCKLIST.any { name.startsWith(it) })
                    throwToApp(ClassNotFoundException("\$name not found"))
            }
        }
    }

    private fun PackageParam.hookSignatureCheck() {
        "android.app.ApplicationPackageManager".toClass()
            .method { name = "getPackageInfo"; paramCount = 2 }.hook {
            after {
                if (!StealthController.isEnabled) return@after
                val pkgName = args[0] as? String ?: return@after
                if (!pkgName.contains("snapchat")) return@after
                val r = result ?: return@after
                runCatching {
                    val sf = r.javaClass.getDeclaredField("signatures")
                        .apply { isAccessible = true }
                    if ((sf.get(r) as? Array<*>)?.isNotEmpty() == true) return@after
                    val sc = Class.forName("android.content.pm.Signature")
                    val stub = sc.getConstructor(ByteArray::class.java)
                        .newInstance(ByteArray(256) { it.toByte() })
                    sf.set(r, arrayOf(stub))
                }
            }
        }
    }

    private fun PackageParam.hookProcMaps() {
        "java.io.BufferedReader".toClass().method { name = "readLine" }.hook {
            after {
                if (!StealthController.isEnabled) return@after
                val line = result as? String ?: return@after
                if (MAPS_LINE_BLOCKLIST.any { line.contains(it, ignoreCase = true) })
                    result = ""
            }
        }
    }

    private fun PackageParam.hookRuntimeExec() {
        "java.lang.Runtime".toClass().apply {
            method { name = "exec"; param(StringClass) }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val cmd = args[0] as? String ?: return@before
                    if (EXEC_CMD_BLOCKLIST.any { cmd.contains(it) }) result = empty()
                }
            }
            method { name = "exec"; param(Array<String>::class.java) }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val cmd = (args[0] as? Array<*>)?.joinToString(" ") ?: return@before
                    if (EXEC_CMD_BLOCKLIST.any { cmd.contains(it) }) result = empty()
                }
            }
        }
        "java.lang.ProcessBuilder".toClass().method { name = "start" }.hook {
            before {
                if (!StealthController.isEnabled) return@before
                runCatching {
                    val cf = instance<ProcessBuilder>().javaClass
                        .getDeclaredField("command").apply { isAccessible = true }
                    val cmd = (cf.get(instance) as? List<*>)?.joinToString(" ") ?: return@before
                    if (EXEC_CMD_BLOCKLIST.any { cmd.contains(it) }) result = empty()
                }
            }
        }
    }

    private fun empty(): Process = object : Process() {
        override fun getOutputStream() = java.io.OutputStream.nullOutputStream()
        override fun getInputStream()  = java.io.InputStream.nullInputStream()
        override fun getErrorStream()  = java.io.InputStream.nullInputStream()
        override fun waitFor()  = 0
        override fun exitValue() = 0
        override fun destroy()   = Unit
    }

    private fun PackageParam.hookStackTrace() {
        "java.lang.Thread".toClass().method { name = "getStackTrace" }.hook {
            after {
                if (!StealthController.isEnabled) return@after
                val frames = result as? Array<StackTraceElement> ?: return@after
                result = frames.filter { f ->
                    XPOSED_CLASS_BLOCKLIST.none { f.className.startsWith(it) }
                }.toTypedArray()
            }
        }
    }

    private fun PackageParam.hookNetworkDetection() {
        runCatching {
            "okhttp3.ResponseBody".toClass().method { name = "string"; paramCount = 0 }.hook {
                after {
                    if (!StealthController.isEnabled) return@after
                    val body = result as? String ?: return@after
                    val token = DETECTION_RESPONSE_TOKENS.firstOrNull { body.contains(it) }
                    if (token != null) StealthController.onDetected("Server: \$token")
                }
            }
        }.onFailure {}
        runCatching {
            "okhttp3.Response".toClass().method { name = "code"; paramCount = 0 }.hook {
                after {
                    if (!StealthController.isEnabled) return@after
                    val code = result as? Int ?: return@after
                    if (code !in listOf(423, 451)) return@after
                    runCatching {
                        val rf = instance<Any>().javaClass
                            .getDeclaredField("request").apply { isAccessible = true }
                        val req = rf.get(instance) ?: return@runCatching
                        val url = req.javaClass.getMethod("url").invoke(req).toString()
                        if (url.contains("snapchat.com") || url.contains("snap.com"))
                            StealthController.onDetected("HTTP \$code from Snap API")
                    }
                }
            }
        }.onFailure {}
    }

    private fun PackageParam.hookIntegrityAPI() {
        runCatching {
            "com.google.android.play.core.integrity.IntegrityTokenResponse".toClass()
                .method { name = "token"; paramCount = 0 }.hook {
                after {
                    if (!StealthController.isEnabled) return@after
                    result = buildFakeIntegrityToken()
                }
            }
        }.onFailure {}
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

    private fun PackageParam.hookBanActivityLaunch() {
        "android.app.Activity".toClass().method { name = "startActivity"; paramCount = 1 }.hook {
            before {
                if (!StealthController.isEnabled) return@before
                val intent = args[0] as? android.content.Intent ?: return@before
                val comp = intent.component?.className ?: intent.action ?: return@before
                BAN_ACTIVITY_FRAGMENTS.firstOrNull { comp.contains(it, ignoreCase = true) }
                    ?.let { StealthController.onDetected("Ban screen: \$it") }
            }
        }
        runCatching {
            "androidx.fragment.app.FragmentTransaction".toClass().method { name = "add" }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val tag = args.filterIsInstance<String>().firstOrNull() ?: return@before
                    BAN_ACTIVITY_FRAGMENTS.firstOrNull { tag.contains(it, ignoreCase = true) }
                        ?.let { StealthController.onDetected("Ban fragment: \$it") }
                }
            }
        }.onFailure {}
    }
}
HOOKS_EOF

# ── Write SecurityFeature.kt ──
cat > "$SECURITY_DIR/SecurityFeature.kt" << FEAT_EOF
package ${NEW_PKG}.core.features.impl.security

import ${NEW_PKG}.core.features.Feature

class SecurityFeature : Feature("Security Shield", "purrfect.security.shield") {
    override fun init() {
        StealthHooks.hookAll(this)
    }
}
FEAT_EOF

ok "Security suite injected → $SECURITY_DIR"

# ── REGISTRATION HINT ─────────────────────────────────────────────────────────
warn "One manual step: register SecurityFeature in FeatureManager.kt"
warn "  Find FeatureManager.kt and add:  SecurityFeature(),"
warn "  alongside existing feature registrations."
warn ""
warn "  Quick locate:"
warn "    grep -rn 'class FeatureManager' core/ --include='*.kt'"

# ── GRADLE WRAPPER ────────────────────────────────────────────────────────────
hdr "Gradle wrapper"
if [[ ! -f "$WORK_DIR/gradle/wrapper/gradle-wrapper.jar" ]]; then
    command -v gradle &>/dev/null || {
        if command -v apt-get &>/dev/null; then sudo apt-get install -y gradle
        else pkg install -y gradle; fi
    }
    cd "$WORK_DIR"
    CURRENT_VER=$(grep distributionUrl gradle/wrapper/gradle-wrapper.properties \
        | grep -oP 'gradle-\K[0-9]+\.[0-9.]+' || echo "8.7")
    gradle wrapper --gradle-version="$CURRENT_VER" --distribution-type=bin 2>/dev/null
    chmod +x gradlew
fi
ok "Gradle wrapper ready"

# ── BUILD ─────────────────────────────────────────────────────────────────────
hdr "Build"
export ANDROID_HOME="$SDK_ROOT"
export JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$JAVA_HOME/bin:$PATH"
cd "$WORK_DIR"

echo "  Package : $NEW_PKG"
echo "  Label   : $APP_LABEL"
echo ""

./gradlew assembleDebug 2>&1 | tee "$WORK_DIR/build-stealth.log"

# ── COLLECT APK ───────────────────────────────────────────────────────────────
APK=$(find "$WORK_DIR" -name "*debug*.apk" -path "*/outputs/apk/*" 2>/dev/null | head -1)
if [[ -n "$APK" && -f "$APK" ]]; then
    DEST_NAME="Purrfect-stealth-${RAND}-debug.apk"
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

SNAP_APK=$(find "$HOME" /sdcard/Download 2>/dev/null -iname "*snapchat*.apk" | head -1)
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

# Download lspatch.jar if not already present
LSPATCH_JAR="$HOME/lspatch.jar"
if [[ ! -f "$LSPATCH_JAR" ]]; then
    echo "  Downloading LSPatch…"
    wget -q --show-progress \
        "https://github.com/LSPosed/LSPatch/releases/latest/download/lspatch.jar" \
        -O "$LSPATCH_JAR"
fi
ok "LSPatch ready"

# Output dir for patched APK
PATCH_OUT="$HOME/lspatch-out"
mkdir -p "$PATCH_OUT"

# Patch: embed Purrfect module (-m), portable mode (-l 2), no forced debuggable,
# sigbypass level 2 (handles most signature checks without needing root).
java -jar "$LSPATCH_JAR" "$SNAP_APK" \
    -m "$FINAL" \
    -l 2 \
    --force-debuggable false \
    --sigbypass 2 \
    -o "$PATCH_OUT"

PATCHED=$(find "$PATCH_OUT" -name "*.apk" | head -1)
if [[ -n "$PATCHED" ]]; then
    # Copy to a predictable location
    PATCHED_DEST="$HOME/Snapchat-purrfect-${RAND}.apk"
    cp "$PATCHED" "$PATCHED_DEST"
    # Also try sdcard for easy phone transfer
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
