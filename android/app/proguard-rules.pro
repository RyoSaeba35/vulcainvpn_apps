# Keep VPN Service classes
-keep class com.vulcainvpn.app.MyVpnService { *; }
-keep class com.vulcainvpn.app.AutoReconnectService { *; }
-keep class com.vulcainvpn.app.VpnDeathReceiver { *; }
-keep class com.vulcainvpn.app.VpnApplication { *; }
-keep class com.vulcainvpn.app.MainActivity { *; }

# Keep Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }

# Keep sing-box
-keep class io.nekohasekai.libbox.** { *; }

# Keep coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# Security crypto
-keep class androidx.security.crypto.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Google Play Core
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# Flutter Play Store Split
-keep class io.flutter.embedding.android.FlutterPlayStoreSplitApplication { *; }
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }

# Keep gomobile runtime (Seq, Proxy, Universe) - invoked from Go via JNI,
# never referenced from Kotlin, so R8 cannot see these uses.
-keep class go.** { *; }
-dontwarn go.**

# Inner classes are separate from the outer -keep above.
# VulcainCommandServerHandler / StringArray / InterfaceArray are all called from Go.
-keep class com.vulcainvpn.app.MyVpnService$** { *; }
