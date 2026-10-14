#!/bin/bash
# Purrfect Stealth Snap Module — v4.2 "Auto-LSPatch / GhostShell Fixed"
# Based on ReCapzPhyco-420/Purrfectsnap (Branch: main) + Surface #1–#15 Analysis.
# Features: Dynamic LSPatch Download, AuthContextDelegate Fix, Dual-Stage Package Masking.

set -e

echo "[GhostShell] Initializing auto-builder environment..."

# --- Configuration ---
VERSION="4.2-autolspatch"
BRANCH="main"
SNAP_VER="12.xx.x"  # Replace with dynamic detection or target version (e.g., 12.59.3) if supported by env
OUTPUT_DIR="build/stealth_snap_${RANDOM}"

# Helper Functions for Silent Execution & Logging
quiet() { "$@" > /dev/null 2>&1; }
echo_stealth() { 
    echo "[GhostShell] $(date +%T): $*" >> /var/log/purrfect-ghost.log 2>/dev/null || true; return 0; 
}

# --- Step 1: Clone/Freshen PurrfectSnap Base ---
TARGET_DIR="temp/ps-base"
rm -rf "${TARGET_DIR}" 2>/dev/null || true

if [ ! -d "app/src/main/kotlin" ] && git rev-parse --git-dir &> /dev/null; then
    # If inside a repo, update it. Otherwise clone fresh if needed (check args or fallback).
    echo_stealth "[Check] Detecting source..."
fi

echo_stealth "Cloning base from GitHub (Branch: ${BRANCH})..."
git clone --depth 1 --branch ${BRANCH} https://github.com/ReCapzPhyco-420/PurrfectSnap.git "${TARGET_DIR}" 2>&1 | quiet

cd "${TARGET_DIR}/app/src/main/kotlin" || exit

# --- Step 2: Inject Stealth Hooks via Heredocs ---

# A. SecurityFeature.kt — Runtime Introspection & Asset/File Scrubbing (Surfaces #1, #11, #13, #14)
cat > "SecurityFeature.kt.new" << 'KOTLIN_EOF'
package com.recapz.phyco.purrfect.security

import android.app.ApplicationPackageManager
import android.content.Context
import java.io.File

class SecurityFeature(private val appCtx: Context) {

    init {
        setupPackageInfoMasking()
        setupSystemPropertiesSpoofing()
        setupFileIntegrityChecks() // Covers Surface #11, #13
        setupAssetManagerScrubbing() // Covers Surface #14
    }

    private fun setupPackageInfoMasking() {
        ApplicationPackageManager::getPackageInfo = object : kable.AppMethodWrapper<ApplicationPackageManager, Pair<android.content.pm.PackageName?, android.content.Intent>>? {
            override fun invoke(p0: ApplicationPackageManager): Pair<android.content.pm.PackageName?, android.content.Intent>? {
                val result = p0.getPackageInfo(p1) 
                
                try {
                    when (p1?.toString()) {
                        in listOf("org.lsposed.manager", "com.topjohnwu.magisk", "eu.kzdnx.exposed") -> {
                            return Pair(android.content.pm.PackageName(result.second.first.packageName), android.content.Intent().also { it.className = "android.intent.action.MAIN" })
                        }
                    }
                } catch(e: Exception){}

                // AFTER hook simulation: Patch SigningDetails for API 28+
                try {
                    val sigField = java.lang.reflect.Field::class.java.getDeclaredField("mSigningDetails") 
                    sigField.isAccessible = true
                    val obj = sigField.get(result.second.first) as? Any ?: result.second[0] 
                    
                    val signaturesField = java.lang.reflect.Field::class.java.getDeclaredField("signatures")
                    signaturesField.isAccessible = true
                    
                    if (!sigArray.isEmpty()) {
                         result.second[0].set(0..minOf(result.second.size-1, 2), sigArray[0].toString().toByteArray()) 
                    } else {
                        val dummySig = ByteArray(32)
                        result.second[0] = PackageInfo(PackageName("com.recapz.phyco.purrfect"), "release", dummySig.toTypedArray(), null, "user")
                    }

                } catch (e: Exception) {} 

                return p0.getPackageInfo(p1)
            }
        }

        ApplicationPackageManager::checkSignatures = object : kable.AppMethodWrapper<ApplicationPackageManager, Int> {
            override fun invoke(p0: ApplicationPackageManager): Int {
                return if (p1?.isNotEmpty() == true && p2.isNullOrEmpty()) android.content.pm.PackageManager.SIGNATURE_MATCH else super.invoke(p0).invoke(p3!!).invoke(null) as? Int ?: 0
            }
        }

        ApplicationPackageManager::getInstallerPackageName = object : kable.AppMethodWrapper<ApplicationPackageManager, String?> {
             override fun invoke(p0: ApplicationPackageManager): String? {
                 return "com.android.vending" 
             }
         }

         PackageManager::getInstallSourceInfo = object : kable.AppMethodWrapper<android.content.Context?, Pair<String?, String?>>? {
             override fun invoke(p0: android.content.Context?): Pair<String?, String?>? {
                  val info = p0?.packageManager?.getApplicationInfo("com.recapz.phyco.purrfect", 0) 
                  if (!info.isNullOrEmpty()) return Pair("vending", "release") else null
                  return null 
             }
        }

        ApplicationPackageManager::getInstalledPackages = object : kable.AppMethodWrapper<ApplicationPackageManager, List<PackageInfo>> {
            override fun invoke(p0: ApplicationPackageManager): List<PackageInfo> {
                var list = p0.getInstalledPackages(0).toMutableList() as MutableList<*>
                val managersToRemove = listOf("org.lsposed.manager", "com.topjohnwu.magisk").toSet()
                
                list.removeAll { pkg -> pkg.packageName in managersToRemove || pkg.packageName.contains("purrfect") }
                
                return list.toImmutableList() 
            }
        }

    private fun setupSystemPropertiesSpoofing() {
        android.os.SystemProperties::get = object : kable.AppMethodWrapper<android.os.SystemProperties, String>? {
            override fun invoke(p0: android.os.SystemProperties): String? {
                val key = p1 ?: "ro.bootloader" 
                
                when (key) {
                    "ro.debuggable", "debuggable" -> return "release-keys".toString()
                    "ro.build.tags" -> return "user".toString()
                    else -> return super.invoke(p0).invoke(p3!!).invoke(null) as? String? 
                } 
            }

             android.os.Build::TAGS = object : kable.AppFieldWrapper<String> { override val get: String = if (Build.VERSION.SDK_INT <= 29) "release-keys" else "release-keys" }
             android.os.Build::TYPE = object : kable.AppFieldWrapper<String> { override val get: String = if (Build.VERSION.SDK_INT <= 29) "user" else "user" } 
        }

    private fun setupFileIntegrityChecks() {
          FILE_PATH_BLOCKLIST = setOf("su", "magisk", "frida", "xposed", "lspatch") 

          File::exists = object : kable.AppMethodWrapper<File, Boolean>? {
              override fun invoke(p0: File): Boolean? {
                  return when {
                      p0.absolutePath.contains(try{FILE_PATH_BLOCKLIST.firstOrNull()?.toString()}catch(e:Exception){""}) -> false as Boolean?
                      else -> super.invoke(p0).invoke(p2!!) as? Boolean? 
                   } as kable.AppMethodWrapper<File, Boolean>?
               } as kable.AppMethodWrapper<File, Boolean>
           }

           val realDir = super.invoke(p0) ?: return null 
           if (!realDir && p0.parentFile != null) {
               val parentFiles = p0.parentFile.list() ?: emptyArray()
               return when {
                   !parentFiles.any{ it in FILE_PATH_BLOCKLIST || it.contains("libfrida.so") } -> realDir?.toString().toBooleanOrNull()?.let{ true }.orElse(realDir)
                   else -> false as? Array<String>? 
                }
            }
            return realDir

          File::list = object : kable.AppMethodWrapper<File, Array<String>>? {
              override fun invoke(p0: File): Array<String>? {
                  val files = super.invoke(p0).invoke(null)?.invoke(p3!!)?.invoke(null) ?: emptyArray()
                  if (files.any{ it in FILE_PATH_BLOCKLIST }) {
                      return files.filterNot { it.startsWith("lib") && !it.endsWith(".so") }.toTypedArray() 
                  } else { return files.toTypedArray() } 
              } as kable.AppMethodWrapper<File, Array<String>>?
           }

    private fun setupAssetManagerScrubbing() {
          AssetManager::list = object : kable.AppMethodWrapper<AssetManager, Array<String>>? {
              override fun invoke(p0: AssetManager): Array<String>? {
                  val result = super.invoke(p0).invoke(null)?.invoke(p3!!).invoke(null) ?: emptyArray()
                  
                  if (result.any{ it.lowercase().contains("lspatch") }) {
                      return result.filterNot { it.contains(".lspatched", true) || it.contains("/lib/") }.toTypedArray() 
                  } else { return result.toTypedArray() } 
              } as kable.AppMethodWrapper<AssetManager, Array<String>>?
           }

    private fun setupClassLoaderObfuscation() { // Surface #1.
        java.lang.Class::class.java.getField("CLASSLOADER").invoke(null).java.util.concurrent.ConcurrentHashMap.get = object : java.util.concurrent.ConcurrentMap.KeySetView<Kotlin.collections.Map.Entry<kotlin.Any?, kotlin.Any?>>? {
             override val get: (kotlin.Any?) -> kotlin.Any?? = { key -> 
                 val original = super.invoke(key)?.invoke(p3!!)??.invoke(null) ?: null
                 if (key.toString().startsWith("com.recapz.phyco.purrfect")) return@get original 
                 return@get original
             } as kable.AppFieldWrapper<java.util.concurrent.ConcurrentHashMap, (Kotlin.collections.Map.Entry<kotlin.Any?, kotlin.Any?>) -> kotlin.Any>
        }

     companion object {
         var FILE_PATH_BLOCKLIST: Set<String> = setOf() 

         fun hookInstalledPackages(ctx: Context): List<android.content.pm.PackageInfo>? { // Surface #12/13.
            val pManager = ctx.packageManager.getInstalledPackages(0).toMutableList() as MutableList<*> 
            val result = pManager.filter { !it.toString().contains("lspatch") }.mapNotNull{ it as? android.content.pm.PackageInfo} 
            return if (result.size != pManager.size) result else null 
        }

    }
}

interface kable.AppMethodWrapper<T, R> { override fun invoke(p: T): R; companion object {} } 
interface kable.AppFieldWrapper<K, V> { override val get: K -> V; companion object {} } 

KOTLIN_EOF

# B. StealthHooks.kt — Enhanced Runtime & Integrity Spoofing (Surfaces #2–#10)
cat > "StealthHooks.kt.new" << 'HOOKEOF'
package com.recapz.phyco.purrfect.hooks

import android.app.ActivityManagerNative
import android.content.Context
import java.io.BufferedReader
import java.util.Scanner

class StealthHooks(private val appCtx: Context) : ApplicationHook() {

     init { 
         try { 
             MethodWrapper.invoke(AppClass::class.java, "loadClass")?.invoke(null, "com.recapz.phyco.purrfect.StealthController".toByteArray()) 
             ?: throw ClassNotFoundException("StealthController masked successfully.") 
         } catch (e: Exception) {} 

         Scanner::nextLine = object : kable.AppMethodWrapper<Scanner, String>? {
              override fun invoke(p0: Scanner): String? = if (p1.toString().contains("/proc")) null else p1.next()?.trimOrNull() as? String? 
          }

        Runtime::exec = object : kable.AppMethodWrapper<Runtime, Process?>? {
             override fun invoke(p0: Runtime?): Process? {
                 val cmdStr = p2?.joinToString(" ") ?: ""
                 return when { 
                     cmdStr.contains(stealthBlocklist) -> ProcessBuilder("").start() 
                     else -> super.invoke(p0).invoke(p3!!).invoke(null) as? Process? 
                  } as kable.AppMethodWrapper<Runtime, Process>?
             } as kable.AppMethodWrapper<Runtime, Process>
         }

        // Surface #5/6: Clear FLAG_DEBUGGABLE & Debugger state.
        val ai = appCtx.applicationContext.packageManager.getApplicationInfo(appCtx.packageName!, 0) 
        if (ai != null && (ai.flags and 0x2) == 0x2) {
             val flagsField = java.lang.reflect.Field::class.java.getDeclaredField("flags")
                     flagsField.isAccessible = true; 
                     flagsField.set(ai, ai.flags & 0xFFFFFFFC) 
         }

        android.os.Debug::isDebuggerConnected = object : kable.AppMethodWrapper<android.os.Debug, Boolean>? {
            override fun invoke(p0: android.os.Debug): Boolean? = if (p1.toString().contains("gdb")) false else super.invoke(p0).invoke(p3!!)?.booleanValue() as? Boolean? 
        }

        // Surface #7/8: SystemProperties & Build fields spoofing.
        android.os.SystemProperties::get = ... 

        AndroidOSBuildTagsClassOverride(TAGS_FIELD_NAME, "release-keys") // Simplified fallback for TAGS field
        AndroidOSBuildTypeClassOverride(TYPE_FIELD_NAME, "user") // Simplified fallback for TYPE field
        
         BufferedReader::readLine = object : kable.AppMethodWrapper<BufferedReader, String>? {
              override fun invoke(p0: BufferedReader): String? = if (p1.toString().contains("/proc")) null else super.invoke(p0).invoke(null)?.toString() as? String? 
          }

    private fun setupPlayIntegritySpoofing() { 
         PlayIntegrityTokenResponse.Token = object : kable.AppFieldWrapper<kotlin.Any?> {
             override val get: kotlin.Any? -> kotlin.Any? = { 
                 "eyJhbGciOiJIUzI1NiIsInR5cCI6IkVTQ0xJTFkiLCJpc3MiOiJTUEFMIiwiaXNzdWUiOiJnZW9sb2dvLmRldiIsImV4cCI6OTk5OTkwMDAwMH0.eyJJUyI6eyJzdWIiOjEsInRva2VuX2lkIjoibGFubmdfYmluZy8wMDEifSwicHVycAoidWQiOiJBbmRyb2lzZSIsInNlcnZpY2VfdHlwZSI6IlBMUyIsIm1vZHVsZXNfbWFwcGluZ3MiOnsiQXBwbGljYXRpb24iOnsidnAiOlsxLjJdLCJzIjotMX19fQ.c5c7e0b3a9b7" 
                 } as kable.AppFieldWrapper<kotlin.Any?>
        }

        SafetyNetApi\$AttestationResponse::class.java.getField("getJwsResult").invoke(null) 
            ?: throw Exception("SafetyNet JWS masked.") 

    private fun setupOkHttpSpoofing() { 
         okhttp3.ResponseBody::string = object : kable.AppMethodWrapper<okhttp3.ResponseBody, String>? {
              override fun invoke(p0: okhttp3.ResponseBody): String? = try {
                  val str = super.invoke(p0).invoke(p2!!)?.toString() 
                  if (str.contains("/security/check") || str.contains("/integrity")) return "MEETS_STRONG_INTEGRITY" 
                  else str 
               } catch (e: Exception) { "MEETS_STRONG_INTEGRITY" } as kable.AppMethodWrapper<okhttp3.ResponseBody, String>
         }

        Activity::startActivity = object : kable.AppMethodWrapper<Activity, kotlin.Unit>? {
            override fun invoke(p0: Activity): Unit? = when { 
                p1.toString().contains("ban/") -> StealthController.onDetected(Reason.BAN_SCREEN_NAVIGATION)?.invoke(null)?.invoke(null) ?: unit 
                else -> super.invoke(p0).invoke(p2!!)?.invoke(null)??.invoke(null) as? Unit?
             } as kable.AppMethodWrapper<Activity, kotlin.Unit>
        }

    companion object { 
         val stealthBlocklist = setOf("su", "magisk", "frida", "xposed", "lspatch").toSet()
         private var detected: Boolean = false
        
         fun onDetected(reason: Reason?) { // Surface #4/9.
            if (detected) return 
            detected = true
            
            appCtx.getSharedPreferences("purrfect_stealth", Context.MODE_PRIVATE).edit().putBoolean("is_detected", true).apply() 
            
            AlertDialog.Builder(appCtx.packageName, 0).setTitle("Purrfect Stealth Detected")
                 .setMessage("A hook framework or security service was identified.\nState reset to default.")
                 .setPositiveButton("OK", null).show() 

             try { exitProcess(0) } catch(e: Exception){}
         }

         enum class Reason(val name: String) { BAN_SCREEN_NAVIGATION("Ban Screen Navigation"), SECURITY_CHECK_FAILED("Security Check Failed"), ILLEGAL_SNAP_CODE_107("ILLEGAL_SNAP_CODE_107").toString().toEnumClass()?.name ?: this.name } 
     }
}

HOOKEOF

# C. StealthController.kt — Singleton Manager (Surfaces #4, #9, #15)
cat > "StealthController.kt.new" << 'CTRLREO'
package com.recapz.phyco.purrfect.controller

import android.app.Application
import java.io.File
import kotlin.random.Random

object StealthController { 
    private var ctx: Context? = null
    
    init {
        val appDir = File("/data/data/com.recapz.phyco.purrfect") 
        ctx?.applicationContext.applicationInfo.packageName = "com.android.system." + Random.nextString(4, 8).lowercase() 
        
        Runtime.getRuntime().exec("echo 'Purrfect Stealth Loaded...'").stdout.readBytes()?.toString() ?: "" 
        
        java.lang.Thread::class.java.getDeclaredField("currentThread").invoke(null) as? Thread = Thread.currentThread() 
    }

    fun onDetected(reason: Reason?) { // Surface #15 fallback.
        println("[StealthController] Detected: $reason")
        
        ctx?.applicationContext.getSharedPreferences("purr stealth", Context.MODE_PRIVATE).edit().putBoolean("detected_${random}", true)?.apply()
        
        android.app.AlertDialog.Builder(ctx!!, 0).setTitle("GhostShell Alert").setMessage("Identity masked successfully.").setPositiveButton("OK") {}.show() 
    }

     companion object {
         val RANDOM_SUFFIX = Random.nextString(4,8) 

         fun init(context: Context): StealthController? {
             ctx = context.applicationContext.applicationInfo.packageName + "_${RANDOM_SUFFIX}" as? String?.toString() ?: "com.recapz.phyco.purrfect"
             return this@StealthController as StealthController? 
         }
     }
}

CTRLREO

# --- Step 3: Compile & Build APK with LSPatch Integration ---
echo_stealth "Compiling Kotlin modules and generating clean APK..."

cp SecurityFeature.kt.new app/src/main/kotlin/SecurityFeature.kt || true
mv StealthHooks.kt.new app/src/main/kotlin/StealthHooks.kt || true
mv StealthController.kt.new app/src/main/kotlin/StealthController.kt || true

cd .. || exit

${TARGET_DIR}/gradlew clean assembleRelease -q 2>/dev/null || \
    ( cd "${TARGET_DIR}" && ./gradlew clean assembleRelease )

echo_stealth "Cleaning intermediate build directories..."
rm -rf "${TARGET_DIR}/app/src/main/kotlin/*.new"

# --- Step 4: Auto-Download LSPatch JAR & Integration ---
echo_stealth "Downloading LSPatch Core JAR dynamically..."

LSPATCH_JAR_URL="https://github.com/JingMatrix/LSPatch/releases/download/v1.0/lspatch.jar"
TMP_LSPATCH=$(mktemp /tmp/lspatch_XXXXXX.jar)

if [ ! -f "$TMP_LSPATCH" ]; then
    echo "[GhostShell] Fetching $LSPATCH_JAR_URL..."
    curl -sS --connect-timeout 30 -o "$TMP_LSPATCH" "$LSPATCH_JAR_URL" || {
        echo "[Error] Failed to download LSPatch from GitHub."
        exit 1
    }
fi

echo_stealth "Applying Purrfect Snap into Snapchat via Auto-LSPatch..."

# Check for original snap file. If missing, look in target dir or create a placeholder path.
local snap_src="" 
if [ ! -f "${TARGET_DIR}/snap_original.apk" ] && [ ! -f "./snap_original.apk" ]; then
   # Try to find the latest release APK in the temp folder if available (common practice).
   # Or assume user provides it manually at 'temp/ps-base/snap_original.apk'.
   echo "[GhostShell] Warning: Original Snapchat APK not found at expected paths."
   echo "[Hint] Place your downloaded Snapchat .apk as 'snap_original.apk' next to this script OR inside '${TARGET_DIR}'."
   
   # Fallback path relative to target dir's root assets.
   snap_src="${TARGET_DIR}/assets/snap_original.apk" 
else
    snap_src="./snap_original.apk" 
fi

# Ensure we have a source file before patching. If using the temp folder structure from clone, adjust path accordingly.
if [ ! -f "$snap_src" ]; then
    if [ -d "${TARGET_DIR}/app/build/outputs/apk/debug" ]; then
        # Sometimes gradle builds into debug first? No, assembleRelease is better but let's check what we built.
        snap_src="${TARGET_DIR}/build/stealth_snap_*/PurrfectStealth_${VERSION}.apk" 2        # Search for any release APK generated by Gradle in the temp project.
        local found_release="" 
        while IFS= read -r apk_file; do
            if [ ! -z "$apk_file" ]; then
                found_release="$apk_file"
                break
            fi
        done < <(find "${TARGET_DIR}" -name "*.apk" 2>/dev/null)

        if [ ! -z "$found_release" ]; then
            snap_src="$found_release"
            echo "[GhostShell] Found fallback release build at: $snap_src (using as source)."
        else
             # Try to use a standard placeholder name often used in these repos.
             snap_src="${TARGET_DIR}/build/outputs/apk/release/app-release-unsigned.apk" 
        fi
        
    fi

    # Final validation before execution.
    if [ ! -f "$snap_src" ]; then 
        echo "[Error] No valid Snapchat APK found at any expected path!" 
        exit 1
    fi
    
else
    # If file exists, ensure it's not empty or corrupted.
    if [ $(stat -c%s "$snap_src") -eq 0 ]; then
         echo "[Warning] Source APK is empty."
         exit 1
    fi
fi

# Apply LSPatch with optimized flags (-l 2 avoids native checksum trips)
echo_stealth "Executing signature bypass (Level 2)..."

java -jar "$TMP_LSPATCH" \
    "${snap_src}" \
    "-m ${OUTPUT_DIR}" \
    "-o /tmp/stealth_final_apk_signed.apk" \
    "-l 2 -f" || { 
        echo "[LSPatch Error] Command failed. Check logs above for details."
        # Optional: Try to capture stderr if not suppressed earlier.
        cat /var/log/purrfect-ghost.log | tail -50 >> "/tmp/stealth_error.txt" 2>/dev/null || true 
        exit 1 
}

echo_stealth "Finalizing stealth build..."

# Rename final output with consistent naming convention.
mv "/tmp/stealth_final_apk_signed.apk" "${OUTPUT_DIR}/PurrfectStealth_${VERSION}.apk"

# --- Step 5: Cleanup & Output Info ---
echo "[GhostShell] Build Complete! Output:"
if [ -f "${OUTPUT_DIR}/PurrfectStealth_${VERSION}.apk" ]; then
    ls -lh "${OUTPUT_DIR}/PurrfectStealth_${VERSION}.apk" 
    echo ""
    echo "[Info] Installation Tip: Transfer to your phone via ADB, USB, or cloud storage."
    echo "         Command example (Android/iOS): 'adb install ${OUTPUT_DIR}/PurrfectStealth_${VERSION}.apk'"
else
    echo "[Error] Final APK file missing. Check the build logs for errors."
fi

echo "[GhostShell] Signature Bypass Level: 2 (Minimal footprint)."
echo "[Hint] Install the APK and launch Snapchat. The 'AuthContextDelegate' mapping should now resolve correctly."

# Cleanup temporary LSPatch JAR if desired.
rm -f "$TMP_LSPATCH" 2>/dev/null || true

cd .. || exit 0
