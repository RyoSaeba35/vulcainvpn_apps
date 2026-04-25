package com.vulcainvpn.app

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.*

/**
 * Centralized file logging utility for debugging crashes
 * Keeps only the last 48 hours of logs automatically
 * Logs are saved to: /storage/emulated/0/Android/data/com.vulcainvpn.app/files/vpn_crash.log
 */
object VpnLogger {
    private const val TAG = "VpnLogger"
    private const val LOG_FILE_NAME = "vpn_crash.log"
    private const val LOG_RETENTION_HOURS = 48
    private const val MAX_LOG_SIZE = 10 * 1024 * 1024 // 10MB (safety limit)

    private var logFile: File? = null
    private var isInitialized = false
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    // Track last cleanup to avoid doing it too frequently
    private var lastCleanupTime = 0L
    private const val CLEANUP_INTERVAL_MS = 6 * 60 * 60 * 1000L // 6 hours

    /**
     * Initialize logger - call this once from Application or MainActivity
     */
    fun init(context: Context) {
        try {
            if (isInitialized) return

            // Use app-specific external storage (doesn't need permission)
            val dir = context.getExternalFilesDir(null)
            if (dir != null) {
                logFile = File(dir, LOG_FILE_NAME)

                isInitialized = true
                log("VpnLogger", "✅ Logger initialized: ${logFile!!.absolutePath}")

                // Clean up old logs on startup
                cleanupOldLogs()
            } else {
                Log.e(TAG, "Failed to get external files dir")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize logger", e)
        }
    }

    /**
     * Log a message (writes to both logcat and file)
     */
    fun log(tag: String, message: String) {
        val timestamp = dateFormat.format(Date())
        val fullMessage = "$timestamp [$tag] $message"

        // Always log to logcat
        Log.d(tag, message)

        // Write to file
        writeToFile(fullMessage)

        // Periodic cleanup check
        checkAndCleanup()
    }

    /**
     * Log an error (writes to both logcat and file)
     */
    fun error(tag: String, message: String, throwable: Throwable? = null) {
        val timestamp = dateFormat.format(Date())
        val fullMessage = if (throwable != null) {
            "$timestamp [ERROR:$tag] $message\n${throwable.stackTraceToString()}"
        } else {
            "$timestamp [ERROR:$tag] $message"
        }

        // Always log to logcat
        if (throwable != null) {
            Log.e(tag, message, throwable)
        } else {
            Log.e(tag, message)
        }

        // Write to file
        writeToFile(fullMessage)
        checkAndCleanup()
    }

    /**
     * Log a critical event (highlighted in file)
     */
    fun critical(tag: String, message: String) {
        val timestamp = dateFormat.format(Date())
        val fullMessage = "$timestamp [🔴 CRITICAL:$tag] $message"

        Log.e(tag, "🔴 CRITICAL: $message")
        writeToFile(fullMessage)
        checkAndCleanup()
    }

    /**
     * Mark the start of a crash scenario for easier debugging
     */
    fun markCrashScenario(scenario: String) {
        val marker = "\n${"=".repeat(80)}\n" +
                     "🚨 CRASH SCENARIO: $scenario\n" +
                     "Time: ${dateFormat.format(Date())}\n" +
                     "${"=".repeat(80)}\n"
        writeToFile(marker)
        Log.e(TAG, "🚨 CRASH SCENARIO: $scenario")
        checkAndCleanup()
    }

    private fun writeToFile(message: String) {
        try {
            if (!isInitialized || logFile == null) return

            synchronized(this) {
                FileWriter(logFile, true).use { writer ->
                    writer.append(message)
                    writer.append("\n")
                    writer.flush()
                }
            }
        } catch (e: Exception) {
            // Don't crash on logging errors
            Log.e(TAG, "Failed to write to log file: ${e.message}")
        }
    }

    /**
     * Check if cleanup is needed and run it if necessary
     */
    private fun checkAndCleanup() {
        try {
            val now = System.currentTimeMillis()

            // Only cleanup every 6 hours or if file is too large
            val shouldCleanup = (now - lastCleanupTime > CLEANUP_INTERVAL_MS) ||
                               (logFile?.exists() == true && logFile!!.length() > MAX_LOG_SIZE)

            if (shouldCleanup) {
                cleanupOldLogs()
                lastCleanupTime = now
            }
        } catch (e: Exception) {
            Log.e(TAG, "Cleanup check failed", e)
        }
    }

    /**
     * Remove log entries older than 48 hours
     */
    private fun cleanupOldLogs() {
        try {
            if (!isInitialized || logFile == null || !logFile!!.exists()) return

            synchronized(this) {
                val cutoffTime = System.currentTimeMillis() - (LOG_RETENTION_HOURS * 60 * 60 * 1000L)
                val lines = logFile!!.readLines()
                val recentLines = mutableListOf<String>()

                var keptCount = 0
                var droppedCount = 0

                for (line in lines) {
                    // Try to parse timestamp from line
                    val timestamp = parseTimestampFromLine(line)

                    if (timestamp != null && timestamp >= cutoffTime) {
                        recentLines.add(line)
                        keptCount++
                    } else if (timestamp == null) {
                        // Keep lines without timestamp (markers, stack traces, etc.)
                        recentLines.add(line)
                        keptCount++
                    } else {
                        droppedCount++
                    }
                }

                // Only rewrite if we actually removed something
                if (droppedCount > 0) {
                    logFile!!.writeText(recentLines.joinToString("\n") + "\n")
                    Log.d(TAG, "🧹 Cleaned up logs: kept $keptCount lines, dropped $droppedCount old lines")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to cleanup old logs", e)
        }
    }

    /**
     * Parse timestamp from a log line
     * Returns null if no valid timestamp found
     */
    private fun parseTimestampFromLine(line: String): Long? {
        try {
            // Log format: "2026-04-11 10:01:46.457 [tag] message"
            // Extract first 23 characters (timestamp)
            if (line.length < 23) return null

            val timestampStr = line.substring(0, 23)
            val date = dateFormat.parse(timestampStr)
            return date?.time
        } catch (e: Exception) {
            return null
        }
    }

    /**
     * Get the log file path for sharing with developer
     */
    fun getLogFilePath(): String? {
        return logFile?.absolutePath
    }

    /**
     * Clear the log file
     */
    fun clearLogs() {
        try {
            logFile?.writeText("")
            log("VpnLogger", "Logs cleared")
            lastCleanupTime = System.currentTimeMillis()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear logs", e)
        }
    }

    /**
     * Get current log file size in KB
     */
    fun getLogSizeKB(): Long {
        return try {
            if (logFile?.exists() == true) {
                logFile!!.length() / 1024
            } else {
                0
            }
        } catch (e: Exception) {
            0
        }
    }
}
