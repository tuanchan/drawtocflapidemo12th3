// android/app/build.gradle — thêm block signingConfigs + buildTypes này
// vào trong android { ... } của build.gradle hiện tại.
//
// Nếu dùng Kotlin DSL (build.gradle.kts) thì xem phần dưới.

// ─── GROOVY DSL (build.gradle) ────────────────────────────────────────────────

android {
    // ... các config hiện có giữ nguyên ...

    signingConfigs {
        release {
            def keystorePropertiesFile = rootProject.file("key.properties")
            if (keystorePropertiesFile.exists()) {
                def keystoreProperties = new Properties()
                keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
                keyAlias        keystoreProperties['keyAlias']
                keyPassword     keystoreProperties['keyPassword']
                storeFile       file(keystoreProperties['storeFile'])
                storePassword   keystoreProperties['storePassword']
            }
            // Fallback: lấy từ env vars (CI/CD nếu không dùng key.properties)
            else {
                keyAlias        System.getenv("KEY_ALIAS")        ?: "upload"
                keyPassword     System.getenv("KEY_PASSWORD")     ?: ""
                storeFile       file(System.getenv("KEYSTORE_PATH") ?: "release.jks")
                storePassword   System.getenv("KEYSTORE_PASSWORD") ?: ""
            }
        }
    }

    buildTypes {
        release {
            // Dùng signingConfig release nếu có; debug nếu không
            signingConfig signingConfigs.release.storeFile?.exists()
                ? signingConfigs.release
                : signingConfigs.debug
            minifyEnabled false   // tflite_flutter không tương thích với R8 mặc định
            shrinkResources false
        }
    }
}

// ─── KOTLIN DSL (build.gradle.kts) ───────────────────────────────────────────
//
// android {
//     signingConfigs {
//         create("release") {
//             val keystoreFile = rootProject.file("key.properties")
//             if (keystoreFile.exists()) {
//                 val props = java.util.Properties().also {
//                     it.load(keystoreFile.inputStream())
//                 }
//                 keyAlias      = props["keyAlias"] as String
//                 keyPassword   = props["keyPassword"] as String
//                 storeFile     = file(props["storeFile"] as String)
//                 storePassword = props["storePassword"] as String
//             }
//         }
//     }
//     buildTypes {
//         release {
//             signingConfig = signingConfigs.getByName("release")
//             isMinifyEnabled   = false
//             isShrinkResources = false
//         }
//     }
// }