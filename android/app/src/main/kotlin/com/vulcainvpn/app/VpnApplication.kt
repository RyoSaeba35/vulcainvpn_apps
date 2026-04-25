package com.vulcainvpn.app

import android.app.Application
import android.util.Log
import go.Seq
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File
import java.util.Locale

class VpnApplication : Application() {

    companion object {
        private const val TAG = "VpnApplication"
    }

    override fun onCreate() {
        super.onCreate()

        VpnLogger.init(this)
        VpnLogger.log("VpnApplication", "App started")

        // Initialize gomobile (moved from MainActivity)
        Seq.setContext(this)
        Log.d(TAG, "Gomobile initialized")

        // Set locale for libbox
        Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
        Log.d(TAG, "Locale set to: ${Locale.getDefault().toLanguageTag()}")

        // Initialize libbox directories
        initializeLibbox()
    }

    private fun initializeLibbox() {
        try {
            // Create directories
            val baseDir = filesDir
            baseDir.mkdirs()

            val workingDir = getExternalFilesDir(null) ?: filesDir
            workingDir.mkdirs()

            val tempDir = cacheDir
            tempDir.mkdirs()

            Log.d(TAG, "Base dir: ${baseDir.absolutePath}")
            Log.d(TAG, "Working dir: ${workingDir.absolutePath}")
            Log.d(TAG, "Temp dir: ${tempDir.absolutePath}")

            // THIS IS THE KEY: Tell libbox where to store cache and other files
            Libbox.setup(SetupOptions().also {
                it.basePath = baseDir.absolutePath
                it.workingPath = workingDir.absolutePath
                it.tempPath = tempDir.absolutePath
            })

            // Optional: Redirect errors to file for debugging
            Libbox.redirectStderr(File(workingDir, "stderr.log").absolutePath)

            Log.d(TAG, "✅ Libbox initialized successfully")

        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to initialize libbox", e)
        }
    }
}
