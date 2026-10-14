// language: Kotlin, file: StealthHooks.kt
// Drop into:
//   core/src/main/kotlin/me/eternal/purrfect/core/features/impl/security/StealthHooks.kt
//
// Registration — one line to add in SecurityFeature.kt (or wherever your features register):
//   StealthHooks.hookAll(this)   // "this" = PackageParam from YukiHookAPI module entry
//
// All hooks check StealthController.isEnabled before acting.
// When detection fires, StealthController.onDetected() disables everything atomically.
//
// Risk ratings are in RiskGuide.md.
// This file covers the bypass hooks only — the detection sensors are wired separately below.

package me.eternal.purrfect.core.features.impl.security

import android.app.Activity
import android.util.Log
import com.highcapable.yukihookapi.hook.factory.method
import com.highcapable.yukihookapi.hook.factory.constructor
import com.highcapable.yukihookapi.hook.log.YLog
import com.highcapable.yukihookapi.hook.param.PackageParam
import com.highcapable.yukihookapi.hook.type.java.BooleanType
import com.highcapable.yukihookapi.hook.type.java.StringClass

// HTTP status codes Snap returns on account action — checked as a val to
// avoid allocating a new list on every single OkHttp response.
private val DETECTION_HTTP_CODES = setOf(423, 451)

// ── Detection tokens that appear in Snap's server responses ───────────────
// READ-ONLY watch — never block or modify these responses.
private val DETECTION_RESPONSE_TOKENS = listOf(
    "\"status\":\"SECURITY_CHECK_FAILED\"",
    "\"status\":\"ILLEGAL_SNAP\"",
    "\"logged_snapchatter\":false",
    "\"error_code\":107",    // account locked
    "\"error_code\":108",    // device banned
    "\"error_code\":109",    // integrity failed
    "THIRD_PARTY_APP",       // Snap's internal modified-client label
)

// Activity / Fragment class names Snap navigates to on detection/ban
private val BAN_ACTIVITY_FRAGMENTS = listOf(
    "LockedOut", "AccountLocked", "TwoFaRequired",
    "SecurityChallenge", "BannedActivity", "RiskChallenge",
)

// Xposed/hook framework class names Snap probes for
private val XPOSED_CLASS_BLOCKLIST = setOf(
    "de.robv.android.xposed.XposedBridge",
    "de.robv.android.xposed.XposedHelpers",
    "de.robv.android.xposed.callbacks.XC_MethodHook",
    "com.android.internal.os.XposedBridge",
    "io.github.lsposed.lspatch.loader.LSPLoader",
    "org.lsposed.lspatch",
    "me.weishu.epic.art.Epic",
    "com.highcapable.yukihookapi",
    "me.eternal.purrfect",   // ← build script updates this after package rename
)

// /proc/self/maps path fragments to blank out
private val MAPS_LINE_BLOCKLIST = listOf(
    "xposed", "lspatch", "lsposed", "edxposed",
    "purrfect", "snapenhance", "yukihook",
    "dobby", "whale", "epic", "riru", "zygisk",
    // arm64-v8a native lib paths — Pixel 3 XL / LSPatch specific
    "arm64-v8a/libxposed",
    "arm64-v8a/liblspatch",
    "arm64-v8a/libdobby",
    "arm64-v8a/libwhale",
    "arm64-v8a/libriru",
    "arm64-v8a/libzygisk",
    "!/lib/arm64",
)

// Shell probe commands Snap fires to check for root / hook framework
private val EXEC_CMD_BLOCKLIST = listOf(
    "which su", "ls /system/xbin/su", "ls /system/bin/su",
    "ls /sbin/su", "ls /data/local/tmp/su",
    "cat /proc/self/maps",
    "ls /sbin/.magisk", "ls /data/adb/magisk",
    "ls /system/app/Superuser",
)

// ─────────────────────────────────────────────────────────────────────────────
object StealthHooks {

    fun hookAll(param: PackageParam) = param.run {
        initController()
        trackActivity()
        hookClassLoader()
        hookSignatureCheck()
        hookProcMaps()
        hookRuntimeExec()
        hookStackTrace()
        hookNetworkDetection()
        hookIntegrityAPI()
        hookBanActivityLaunch()
    }

    // ── 0. Bootstrap StealthController with Snap's Application context ────
    private fun PackageParam.initController() {
        "android.app.Application".toClass().method {
            name = "onCreate"
        }.hook {
            after {
                val ctx = instance<android.app.Application>()
                StealthController.init(ctx)
            }
        }
    }

    // ── 0b. Track foreground Activity for popup display ───────────────────
    // Hook onResume so the reference is always the currently visible Activity.
    private fun PackageParam.trackActivity() {
        "android.app.Activity".toClass().method {
            name = "onResume"
        }.hook {
            after {
                StealthController.setActivity(instance<Activity>())
            }
        }
    }

    // ── 1. ClassLoader probe suppression ──────────────────────────────────
    // Snap calls ClassLoader.loadClass("de.robv.android.xposed.XposedBridge")
    // to confirm an Xposed environment before sending a detection report.
    // Throw CNF → Snap's check returns false → no server report.
    private fun PackageParam.hookClassLoader() {
        if (!StealthController.isEnabled) return

        "java.lang.ClassLoader".toClass().apply {
            method { name = "loadClass"; param(StringClass) }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val name = args[0] as? String ?: return@before
                    if (XPOSED_CLASS_BLOCKLIST.any { name.startsWith(it) })
                        throwToApp(ClassNotFoundException("$name not found"))
                }
            }
            method { name = "loadClass"; param(StringClass, BooleanType) }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val name = args[0] as? String ?: return@before
                    if (XPOSED_CLASS_BLOCKLIST.any { name.startsWith(it) })
                        throwToApp(ClassNotFoundException("$name not found"))
                }
            }
        }
        "java.lang.Class".toClass().method {
            name = "forName"; param(StringClass)
        }.hook {
            before {
                if (!StealthController.isEnabled) return@before
                val name = args[0] as? String ?: return@before
                if (XPOSED_CLASS_BLOCKLIST.any { name.startsWith(it) })
                    throwToApp(ClassNotFoundException("$name not found"))
            }
        }
    }

    // ── 2. Signature spoof ────────────────────────────────────────────────
    // LSPatch re-signs the APK with a different cert. Snap null-checks its
    // own signature on startup. Inject a stub array so the check passes.
    private fun PackageParam.hookSignatureCheck() {
        "android.app.ApplicationPackageManager".toClass().method {
            name = "getPackageInfo"; paramCount = 2
        }.hook {
            after {
                if (!StealthController.isEnabled) return@after
                val pkgName = args[0] as? String ?: return@after
                if (!pkgName.contains("snapchat")) return@after
                result?.let { injectFakeSignature(it) }
            }
        }
    }

    private fun injectFakeSignature(pkgInfo: Any) {
        runCatching {
            val sigField = pkgInfo.javaClass.getDeclaredField("signatures")
                .apply { isAccessible = true }
            val existing = sigField.get(pkgInfo) as? Array<*>
            if (existing?.isNotEmpty() == true) return
            val sigClass = Class.forName("android.content.pm.Signature")
            val stub = sigClass.getConstructor(ByteArray::class.java)
                .newInstance(ByteArray(256) { it.toByte() })
            sigField.set(pkgInfo, arrayOf(stub))
        }.onFailure { YLog.warn("injectFakeSignature: ${it.message}") }
    }

    // ── 3. /proc/self/maps filter ─────────────────────────────────────────
    // Snap reads this file scanning for known hook library paths.
    // Blank matching lines — empty lines are valid map file syntax.
    private fun PackageParam.hookProcMaps() {
        "java.io.BufferedReader".toClass().method {
            name = "readLine"
        }.hook {
            after {
                if (!StealthController.isEnabled) return@after
                val line = result as? String ?: return@after
                if (MAPS_LINE_BLOCKLIST.any { line.contains(it, ignoreCase = true) })
                    result = ""
            }
        }
    }

    // ── 4. Runtime.exec / ProcessBuilder probe suppression ───────────────
    // Snap probes for su, Magisk dirs via shell commands.
    // Return a no-output dummy Process → probes come back clean.
    private fun PackageParam.hookRuntimeExec() {
        "java.lang.Runtime".toClass().apply {
            method { name = "exec"; param(StringClass) }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val cmd = args[0] as? String ?: return@before
                    if (EXEC_CMD_BLOCKLIST.any { cmd.contains(it) })
                        result = emptyProcess()
                }
            }
            method { name = "exec"; param(Array<String>::class.java) }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val cmd = (args[0] as? Array<*>)?.joinToString(" ") ?: return@before
                    if (EXEC_CMD_BLOCKLIST.any { cmd.contains(it) })
                        result = emptyProcess()
                }
            }
        }
        "java.lang.ProcessBuilder".toClass().method {
            name = "start"
        }.hook {
            before {
                if (!StealthController.isEnabled) return@before
                runCatching {
                    val cmdField = instance<ProcessBuilder>().javaClass
                        .getDeclaredField("command").apply { isAccessible = true }
                    val cmd = (cmdField.get(instance) as? List<*>)?.joinToString(" ")
                        ?: return@before
                    if (EXEC_CMD_BLOCKLIST.any { cmd.contains(it) })
                        result = emptyProcess()
                }
            }
        }
    }

    private fun emptyProcess(): Process = object : Process() {
        override fun getOutputStream() = java.io.OutputStream.nullOutputStream()
        override fun getInputStream()  = java.io.InputStream.nullInputStream()
        override fun getErrorStream()  = java.io.InputStream.nullInputStream()
        override fun waitFor()         = 0
        override fun exitValue()       = 0
        override fun destroy()         = Unit
    }

    // ── 5. Stack trace filter ─────────────────────────────────────────────
    // Snap walks the call stack for Xposed/YukiHookAPI frame names.
    // Strip those frames before the array is returned.
    private fun PackageParam.hookStackTrace() {
        "java.lang.Thread".toClass().method {
            name = "getStackTrace"
        }.hook {
            after {
                if (!StealthController.isEnabled) return@after
                val frames = result as? Array<StackTraceElement> ?: return@after
                result = frames.filter { f ->
                    XPOSED_CLASS_BLOCKLIST.none { f.className.startsWith(it) }
                }.toTypedArray()
            }
        }
    }

    // ── 6. Network detection monitor ──────────────────────────────────────
    // READ-ONLY. Watches response bodies for Snap's detection tokens.
    // Never blocks or modifies — that causes retries and more noise.
    // Self-disables before Snap can act further on the signal.
    private fun PackageParam.hookNetworkDetection() {
        // OkHttp is bundled inside Snap — class names are stable across updates.
        runCatching {
            "okhttp3.ResponseBody".toClass().method {
                name = "string"; paramCount = 0
            }.hook {
                after {
                    if (!StealthController.isEnabled) return@after
                    val body = result as? String ?: return@after
                    val token = DETECTION_RESPONSE_TOKENS.firstOrNull { body.contains(it) }
                    if (token != null) {
                        YLog.warn("Detection token: $token")
                        StealthController.onDetected("Server response: $token")
                    }
                }
            }
        }.onFailure { YLog.warn("hookNetworkDetection body: ${it.message}") }

        // Also watch HTTP status codes — 423 = locked, 451 = policy violation
        runCatching {
            "okhttp3.Response".toClass().method {
                name = "code"; paramCount = 0
            }.hook {
                after {
                    if (!StealthController.isEnabled) return@after
                    val code = result as? Int ?: return@after
                    if (code !in DETECTION_HTTP_CODES) return@after
                    runCatching {
                        val reqField = instance<Any>().javaClass
                            .getDeclaredField("request").apply { isAccessible = true }
                        val req = reqField.get(instance) ?: return@runCatching
                        val url = req.javaClass.getMethod("url").invoke(req).toString()
                        if (url.contains("snapchat.com") || url.contains("snap.com")) {
                            StealthController.onDetected("HTTP $code from Snap API: $url")
                        }
                    }
                }
            }
        }.onFailure { YLog.warn("hookNetworkDetection code: ${it.message}") }
    }

    // ── 7. Play Integrity spoof ───────────────────────────────────────────
    // On non-root LSPatch installs (Pixel 3 XL / Titan M), the re-signed APK
    // always fails hardware attestation — monitoring and self-disabling on that
    // signal would kill the session on every cold start.
    //
    // Instead: spoof a passing JWT client-side. Snap reads the token locally
    // first; if it forwards to Google's servers for RSA signature verification
    // the fake sig fails there, but the network monitor (hook 6 above) catches
    // the resulting 423/451 and self-disables at that point instead — which is
    // the correct time to do so, not at startup before anything happened.
    private fun PackageParam.hookIntegrityAPI() {
        runCatching {
            "com.google.android.play.core.integrity.IntegrityTokenResponse".toClass()
                .method { name = "token"; paramCount = 0 }
                .hook {
                    after {
                        if (!StealthController.isEnabled) return@after
                        result = buildFakeIntegrityToken()
                    }
                }
        }.onFailure { /* Play Integrity absent on this device — silent skip */ }
    }

    private fun buildFakeIntegrityToken(): String {
        val header = android.util.Base64.encodeToString(
            """{"alg":"RS256","typ":"JWT"}""".toByteArray(),
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        val payload = android.util.Base64.encodeToString(
            """{"requestDetails":{"requestPackageName":"com.snapchat.android","timestampMillis":"${System.currentTimeMillis()}","nonce":"c3RlYWx0aA=="},"appIntegrity":{"appRecognitionVerdict":"PLAY_RECOGNIZED","packageName":"com.snapchat.android","versionCode":"1"},"deviceIntegrity":{"deviceRecognitionVerdict":["MEETS_BASIC_INTEGRITY","MEETS_DEVICE_INTEGRITY","MEETS_STRONG_INTEGRITY"]},"accountDetails":{"appLicensingVerdict":"LICENSED"}}""".toByteArray(),
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        // Random bytes for the signature field — fails Google RSA verify server-side
        // but passes any client-side format check Snap does locally.
        val sig = android.util.Base64.encodeToString(
            ByteArray(256).also { java.security.SecureRandom().nextBytes(it) },
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP
        )
        return "$header.$payload.$sig"
    }

    // ── 8. Ban Activity launch monitor ───────────────────────────────────
    // Before Snap bans, it navigates to a lock/ban screen.
    // Watch for those names and self-disable at the earliest moment.
    // We do NOT block the Intent — the ban is already server-side at this point.
    private fun PackageParam.hookBanActivityLaunch() {
        "android.app.Activity".toClass().method {
            name = "startActivity"; paramCount = 1
        }.hook {
            before {
                if (!StealthController.isEnabled) return@before
                val intent = args[0] as? android.content.Intent ?: return@before
                val component = intent.component?.className ?: intent.action ?: return@before
                val match = BAN_ACTIVITY_FRAGMENTS
                    .firstOrNull { component.contains(it, ignoreCase = true) }
                if (match != null) {
                    StealthController.onDetected("Ban screen: $match")
                }
            }
        }

        runCatching {
            // add(containerViewId: Int, fragment: Fragment, tag: String)
            // paramCount = 3 disambiguates from the other add() overloads so
            // YukiHookAPI doesn't throw on ambiguous method resolution.
            "androidx.fragment.app.FragmentTransaction".toClass().method {
                name = "add"; paramCount = 3
            }.hook {
                before {
                    if (!StealthController.isEnabled) return@before
                    val tag = args.filterIsInstance<String>().firstOrNull() ?: return@before
                    val match = BAN_ACTIVITY_FRAGMENTS
                        .firstOrNull { tag.contains(it, ignoreCase = true) }
                    if (match != null) {
                        StealthController.onDetected("Ban fragment: $match")
                    }
                }
            }
        }.onFailure {}
    }
}
