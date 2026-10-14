// language: Kotlin, file: StealthController.kt
// Drop into:
//   core/src/main/kotlin/me/eternal/purrfect/core/features/impl/security/StealthController.kt
//
// Central detection-state manager.
// Every hook in StealthHooks.kt checks StealthController.isEnabled before acting.
// When a detection signal fires → all hooks self-disable → user popup appears.
//
// SharedPreferences stored in Snapchat's own data dir (accessible from the hook process).

package me.eternal.purrfect.core.features.impl.security

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

    // ── State ──────────────────────────────────────────────────────────────
    private val _enabled     = AtomicBoolean(true)
    private val _popupShown  = AtomicBoolean(false)
    private val _detectCount = AtomicInteger(0)

    val isEnabled: Boolean get() = _enabled.get()

    @Volatile private var appContext: Context? = null
    @Volatile private var currentActivity: Activity? = null

    // ── Init (called from Application.onCreate hook inside StealthHooks) ──
    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        val prefs = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        _enabled.set(prefs.getBoolean(KEY_ENABLED, true))
        _detectCount.set(prefs.getInt(KEY_DETECT_COUNT, 0))
        Log.d(TAG, "init: enabled=${_enabled.get()}, detections=${_detectCount.get()}")
    }

    fun setActivity(activity: Activity) { currentActivity = activity }

    // ── Detection trigger ──────────────────────────────────────────────────
    // Thread-safe. Only the first caller wins — subsequent signals are no-ops.
    fun onDetected(reason: String) {
        if (!_enabled.compareAndSet(true, false)) return

        val count = _detectCount.incrementAndGet()
        Log.w(TAG, "Detection #$count: $reason")

        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.edit()
            ?.putBoolean(KEY_ENABLED, false)
            ?.putInt(KEY_DETECT_COUNT, count)
            ?.apply()

        showPopup(reason, count)
    }

    // Manual re-enable from settings UI or the popup button
    fun reenable() {
        _enabled.set(true)
        _popupShown.set(false)
        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.edit()?.putBoolean(KEY_ENABLED, true)?.apply()
        Log.i(TAG, "Re-enabled")
    }

    fun getDetectionCount(): Int = _detectCount.get()

    fun isFirstRun(): Boolean {
        val prefs = appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?: return false
        return !prefs.contains(KEY_ENABLED)
    }

    // ── Popup ──────────────────────────────────────────────────────────────
    private fun showPopup(reason: String, count: Int) {
        // Do NOT set _popupShown here — check activity first.
        // If we set it before the null-check, the scheduled retry hits the
        // gate and returns immediately, so the popup never shows.
        val act = currentActivity
        if (act == null || act.isFinishing || act.isDestroyed) {
            // Retry after 1 s — detection fired before first Activity onResume
            Handler(Looper.getMainLooper()).postDelayed({ showPopup(reason, count) }, 1000)
            return
        }

        // We have a live Activity — claim the slot now.
        if (_popupShown.getAndSet(true)) return

        Handler(Looper.getMainLooper()).post {
            if (act.isFinishing || act.isDestroyed) return@post
            AlertDialog.Builder(act)
                .setTitle("⚠ Purrfect — Possible Detection")
                .setMessage(
                    "A detection signal was received:\n\n「$reason」\n\n" +
                    "All Purrfect stealth hooks have been automatically disabled " +
                    "to protect your account.\n\n" +
                    "Detections this session: $count\n\n" +
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
