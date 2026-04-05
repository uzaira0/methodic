# Android ProGuard/R8 Obfuscation Review

**Date**: 2026-04-05
**Scope**: `chronicle/app/build.gradle` and `chronicle/app/proguard-rules.pro`

---

## Current Configuration

**R8/ProGuard is ENABLED for release builds.** The configuration is solid.

### build.gradle Settings

```groovy
buildTypes {
    debug {
        debuggable true
        // minifyEnabled NOT set (defaults to false) -- correct for debug
    }
    release {
        minifyEnabled true
        proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
    }
    debugMinified {
        initWith debug
        minifyEnabled true
        proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        debuggable true
    }
    releaseMinified {
        initWith release
        // inherits minifyEnabled true from release
    }
}
```

**Note**: `shrinkResources` is **not enabled**. This is a separate optimization that removes unused resources (drawables, layouts, strings). It does not affect code obfuscation but can reduce APK size.

### proguard-rules.pro Analysis

The rules file is well-organized with clear section comments. Here is the assessment:

| Category | Rules Present | Assessment |
|----------|--------------|------------|
| **Kotlin runtime** | `keep kotlin.jvm.internal.Intrinsics`, `keep kotlin.Metadata`, `keep kotlin.**` | Correct -- R8 in AGP 9 aggressively strips Kotlin internals |
| **Attributes** | `keepattributes Signature, *Annotation*, InnerClasses, EnclosingMethod` | Essential for reflection-based libraries |
| **WorkManager** | Keep all `Worker` and `ListenableWorker` subclasses | Correct -- instantiated via reflection |
| **Jackson** | Keep all `com.fasterxml.jackson.**`, keep `TypeReference` subclasses | Correct -- prevents serialization failures |
| **Jackson polymorphism** | Keep `ChronicleSample`, `SourceDevice` interfaces and concrete types | Correct -- needed for `@JsonTypeInfo` |
| **Apache Olingo** | Keep `org.apache.olingo.**` | Correct -- `FullQualifiedName` serialized via Jackson |
| **chronicle-api models** | Keep `com.openlattice.chronicle.android.**`, `sources.**`, `data.**` | Correct -- these cross the network boundary |
| **Retrofit** | Not explicitly mentioned | See gap analysis below |
| **Room** | Not explicitly mentioned | See gap analysis below |
| **Firebase** | Not explicitly mentioned | See gap analysis below |

---

## Gap Analysis

### 1. Retrofit -- LOW RISK (no gap)

The app uses Retrofit 3.0.0. Retrofit interfaces (`ChronicleStudyApi.kt`) define the API contract but are not subject to R8 issues because:
- Retrofit uses `java.lang.reflect.Proxy` to implement the interface at runtime, which works regardless of obfuscation.
- The request/response model classes (`ChronicleData`, `SourceDevice`, etc.) are already covered by the existing keep rules for `com.openlattice.chronicle.**`.

**No additional rules needed.**

### 2. Room -- LOW RISK

Room entities and DAOs are processed by KSP at compile time, generating concrete implementation classes. The generated code does not rely on reflection for the annotated class names. However, if Room's `@Database` `exportSchema` or migration logic references class names, obfuscation could theoretically cause issues.

The app uses `room.schemaLocation` for schema export. Room 2.8.x with KSP is generally R8-safe, but for defense-in-depth:

**Recommendation**: Add Room entity keep rules if any migration issues are observed. Currently not required.

### 3. Firebase -- LOW RISK

Firebase Crashlytics and Analytics are included via the Firebase BOM. The Firebase SDK includes its own consumer ProGuard rules (`proguard.txt` bundled in the AAR), which are automatically merged by the Android Gradle Plugin. No additional rules needed.

### 4. AndroidX -- COVERED

AndroidX libraries ship with their own consumer ProGuard rules. The `keep class * extends androidx.work.Worker` rule is present for WorkManager, which is the only AndroidX component requiring explicit rules.

### 5. Guava -- LOW RISK

Guava 33.x for Android includes its own ProGuard consumer rules.

---

## Recommended Improvements

### A. Enable `shrinkResources` for release builds

This removes unused resources (images, layouts, strings) from the APK, reducing size without affecting functionality. Add to the release build type:

```groovy
release {
    minifyEnabled true
    shrinkResources true  // <-- ADD THIS
    proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
}
```

### B. Enable source file/line number preservation for Crashlytics

Currently commented out in proguard-rules.pro:

```
#-keepattributes SourceFile,LineNumberTable
#-renamesourcefileattribute SourceFile
```

These should be **uncommented** for production builds. Without them, Crashlytics stack traces show obfuscated names with no line numbers, making crash debugging extremely difficult. The APK size increase is negligible (~2-5KB for the attributes).

### C. Add Kotlin Serialization keep rules

The app uses `org.jetbrains.kotlin.plugin.serialization`. If any `@Serializable` classes are used, R8 may strip the generated `$serializer` companion. Add:

```
-keepclassmembers class * {
    kotlinx.serialization.KSerializer serializer(...);
}
```

### D. Consider adding mapping file upload to CI

R8 generates `mapping.txt` with the obfuscation mapping. This should be uploaded to Firebase Crashlytics (via the Gradle plugin) and archived in CI artifacts for each release build, enabling de-obfuscation of crash reports.

---

## Summary

| Item | Status | Action |
|------|--------|--------|
| R8 enabled for release | Yes | None |
| ProGuard rules for Jackson | Complete | None |
| ProGuard rules for Kotlin | Complete | None |
| ProGuard rules for WorkManager | Complete | None |
| ProGuard rules for Olingo | Complete | None |
| ProGuard rules for API models | Complete | None |
| Retrofit rules | Not needed (Proxy-based) | None |
| Room rules | Not needed (KSP) | None |
| Firebase rules | Auto-merged from AAR | None |
| `shrinkResources` | Missing | Enable for release builds |
| Source/line preservation | Commented out | Uncomment for Crashlytics |
| Kotlin Serialization | Missing | Add if `@Serializable` used |
| mapping.txt archiving | Unknown | Verify CI pipeline |

**Overall assessment**: The obfuscation configuration is production-ready and covers all critical reflection-based dependencies. The recommended improvements are optimizations, not blockers.
