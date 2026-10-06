// language: Kotlin, file: SecurityFeature.kt
// Drop into:
//   core/src/main/kotlin/me/eternal/purrfect/core/features/impl/security/SecurityFeature.kt
//
// ── HOW TO REGISTER IN FEATUREMANAGER ────────────────────────────────────────
//
// 1. Find FeatureManager.kt:
//    core/src/main/kotlin/me/eternal/purrfect/core/features/FeatureManager.kt
//
// 2. Inside the feature registration block (where all other features are added),
//    add ONE line:
//      SecurityFeature(),
//
//    It will look something like this after:
//      register(
//          MediaDownloader(),
//          StealthMode(),
//          MessageLogger(),
//          ...
//          SecurityFeature(),   // ← add this
//      )
//
// 3. That's it. StealthHooks.hookAll() is called from init() below.
//    StealthController.init() is called automatically from the Application.onCreate hook
//    that's wired inside StealthHooks — no additional wiring needed.
//
// ─────────────────────────────────────────────────────────────────────────────
//
// Settings UI: the two toggles below add "Security Shield" to Purrfect's
// existing settings screen via the standard Purrfect config key pattern.
// If Purrfect's settings renderer auto-discovers config keys, these appear
// automatically. If it uses a manual layout, add them there.

package me.eternal.purrfect.core.features.impl.security

import me.eternal.purrfect.core.features.Feature

class SecurityFeature : Feature("Security Shield", "purrfect.security.shield") {

    companion object {
        // Config key checked by other features that should respect the shield state
        const val KEY_SHIELD_ENABLED = "purrfect.security.shield.enabled"
        // If true, show the detection popup. If false, self-disable silently.
        const val KEY_SILENT_DISABLE  = "purrfect.security.shield.silent"
    }

    override fun init() {
        // Wire all bypass hooks + detection sensors in one call.
        // PackageParam ("this" in Purrfect's Feature context) may be named differently
        // depending on which Feature base class version Purrfect uses.
        //
        // Common patterns — try whichever compiles:
        //   StealthHooks.hookAll(this)           // if Feature extends PackageParam scope
        //   StealthHooks.hookAll(packageParam)   // if it's a named property
        //   StealthHooks.hookAll(param)          // same
        //
        // If none compile, look at StealthMode.kt in the same project for the exact call.
        StealthHooks.hookAll(this)
    }

    // Warm-path activity sync.
    // NOTE: if this doesn't compile, check the exact override method name in
    // StealthMode.kt or Feature.kt — it may be onActivityCreate, onSnapActivityCreate,
    // or similar depending on which version of Purrfect's Feature base you have.
    // The onResume hook in StealthHooks covers this regardless — this is just a backup.
    override fun onSnapMainActivityCreate(activity: android.app.Activity) {
        // Always update the activity reference, regardless of shield state.
        // Previous version had the condition backwards (!isEnabled) — fixed.
        StealthController.setActivity(activity)
    }
}
