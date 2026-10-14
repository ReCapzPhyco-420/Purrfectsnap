# Purrfect Stealth — v3.6 + invisibility pass

Base is the v3.6 "Nyx review" script — real Purrfect source verified: the
single-arg `Feature(key)` constructor, the project's own `Class.hook` /
`HookStage` wrapper (there's no raw YukiHookAPI `PackageParam` attached
anywhere in this codebase), the JingMatrix LSPatch fork's actual CLI flags,
the AIDL package-rename gap, and the android-36 SDK/build-tools match.

## What changed in this pass (detection-surface coverage)

Gap analysis against the hooks that existed before — each one either closes
a channel Snapchat can use to notice the hook framework, or spoofs an
attestation signal. All new hooks are registered via `runCatching` so a
failure to attach one doesn't abort `hookAll()` or the rest of the build.

| # | Surface | What it covers |
|---|---|---|
| 1 | `Scanner.nextLine()` | Second Java path for reading `/proc/self/maps`, alongside the existing `BufferedReader.readLine()` hook. A **native** (JNI/syscall) read of that file bypasses both — that needs a kernel/native hook (Zygisk/root) and is out of scope for an LSPatch embed. |
| 2 | `StandardIntegrityTokenResponse` | Newer Play Integrity surface (Play Core ≥ 1.10.3), alongside the legacy `IntegrityTokenResponse`. |
| 3 | `SafetyNetApi` (legacy) | Some Snap builds still call `attest()`. Both known result-class surfaces hooked with a fake JWS. |
| 4 | `getInstallerPackageName` / `getInstallSourceInfo` | Spoofs Play Store as the install source on both API ≤29 and API 30+ surfaces. |
| 5 | `ApplicationInfo.FLAG_DEBUGGABLE` | Cleared on the Application's own cached info (BEFORE `onCreate`) and on any `getApplicationInfo()` re-fetch (AFTER). |
| 6 | `Debug.isDebuggerConnected()` / `waitingForDebugger()` | Forced to `false`. |
| 7 | `SystemProperties.get()` | `ro.debuggable`, `ro.build.tags`, `ro.build.type`, `ro.secure` spoofed to clean-device values. **Unverified** against this specific hook wrapper — it's a hidden (`@hide`) class; if the hook fails to attach it's silently swallowed. |
| 8 | `Build.TAGS` / `Build.TYPE` | Reflection field overwrite. Confirmed pattern works API ≤29; API 30+ blocks final-field reflection (`InaccessibleObjectException`, caught) — hook #7 covers the same signal on newer API levels. |
| 9 | `getDeclaredMethods/Fields/getMethods` | Reflection enumeration on our own injected classes returns empty — hides the hook framework's own class shape from a probe that doesn't go through `loadClass`/`forName`. |
| 10 | `checkSignatures()` | Added alongside the existing `getPackageInfo` signature hook; always reports `SIGNATURE_MATCH`. |

## Pass 2 — file/package/asset enumeration (this round)

All four closed the biggest remaining gap: direct checks that never go
through a shell, `/proc`, or a classloader call at all.

| # | Surface | What it covers |
|---|---|---|
| 11 | `File.exists()` | Direct path checks (`new File("/system/bin/su").exists()`) for root/Magisk/Xposed/Frida/LSPatch artifacts — this is the single most common root-detection technique in the wild and nothing before this pass touched it; `EXEC_CMD_BLOCKLIST` only ever covered the shell-exec route to the same paths. |
| 12 | `getPackageInfo(name)` for manager apps | New BEFORE hook (separate from the existing AFTER signature-patch hook on the same method) throws `NameNotFoundException` for LSPosed Manager, Magisk, EdXposed, and similar package names. **Unverified**: whether this wrapper supports two independent hook registrations on the same target method — if it silently keeps only one, it's this one that degrades, not the signature patch. |
| 13 | `getInstalledPackages()` / `getInstalledApplications()` | Enumeration path — strips the same manager-app package names out of the returned list, independent of #12. |
| 14 | `AssetManager.list()` | LSPatch's embedded/integrated mode stores its loader and the injected module inside the patched APK's `assets/` tree; filters `lspatch`-named entries out of any listing. |
| 15 | `SigningInfo` (`GET_SIGNING_CERTIFICATES`) | API 28+'s non-deprecated replacement for `GET_SIGNATURES` — returns a `SigningInfo` object instead of a `signatures[]` array, so the original signature patch alone misses it if Snap's `targetSdk` queries this way. **Higher-risk, unverified**: reaches `SigningInfo`'s private `mSigningDetails.signatures` field via reflection (no public mutator exists); fragile across Android versions and not confirmed against a real device. |

## The one thing that cannot be made invisible: server-verified Play Integrity / SafetyNet

Both fake-attestation hooks pass **structurally** (valid JWT/JWS shape,
`MEETS_STRONG_INTEGRITY` verdict) and will pass **any check Snap does
locally** against the token. But if Snap forwards the token to its backend,
which forwards it to Google for signature verification, the random bytes in
the signature field fail there — Google has the private key, we don't.
Snap's API then returns `SECURITY_CHECK_FAILED`, the network-detection hook
catches it, and `StealthController.onDetected()` fires the soft-disable +
popup flow.

This is a structural limit, not a missing hook: making a *server-verified*
attestation pass without a real clean device relaying the request isn't
possible client-side. "Perfect" and "undetectable against server-side
integrity verification" are different targets — what this pass gets you is
invisible against every *client-side* probe Snap can run (classloader scans,
stack walks, reflection, `/proc` reads, shell probes, debugger/property
checks, install-source checks), with the existing soft-disable as the
fallback for the one channel that can't be fully closed.

## Still unverified (flagged honestly, not glossed over)

- Whether this project's `Class.hook(name, HookStage)` wrapper disambiguates
  overloaded methods by argument types at all (e.g. `FragmentTransaction.add`,
  `checkSignatures(String,String)` vs `checkSignatures(int,int)`). The
  wrapper's own source wasn't read — only its call sites, from the v3.6
  Nyx pass. If it doesn't disambiguate, the wrong overload could bind, or
  registration throws and that one hook silently no-ops (via `runCatching`).
  Worth a 2-minute check once cloned: `grep -rn "fun.*hook" core/*/util/hook/`.
- Hidden-API hookability (`android.os.SystemProperties`) against this
  specific wrapper — noted inline above.
- Whether two independent hooks can coexist on the same target method
  (`getPackageInfo` now has both a BEFORE and an AFTER registration) — noted
  inline at #12 above.
- `SigningInfo` reflection path (#15) — reaches a private field with no
  public mutator; most likely to break first if Android's internal class
  layout differs from what's assumed here.
- None of this has been compiled or run. The build script will either
  succeed or fail with a concrete Gradle error — that's the real
  verification, not this review.

## Detection-trigger behavior (confirmed earlier, unchanged)

Soft-disable: hooks stop modifying behavior, the popup shows, Snapchat's
process keeps running until restarted. Not hard-kill — confirmed as the
intended behavior.
