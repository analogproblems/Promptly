package dev.promptly.promptly

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A FragmentActivity, which the fingerprint and PIN prompt (local_auth) needs.
class MainActivity : FlutterFragmentActivity() {
    // Asked once a run at most: from Android 13 the sessions notification
    // stays hidden without it, though the sessions keep running either way.
    private var askedToNotify = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The app says how many sessions are open whenever that changes
        // (lib/features/sessions/sessions_in_background.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.promptly/sessions")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepAlive" -> {
                        keepAlive((call.arguments as? Number)?.toInt() ?: 0)
                        result.success(null)
                    }
                    // Back on a tab's first page (lib/features/shell/shell_scaffold.dart).
                    "moveToBack" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // With the app lock on, the recent apps screen shows no picture of
        // the app (lib/features/lock/lock_gate.dart). Android 13 and later.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.promptly/privacy")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hideFromRecents" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            setRecentsScreenshotEnabled(call.arguments != true)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Start the service for the first open session, update its count after
    // that, and stop it when none are left.
    private fun keepAlive(open: Int) {
        val service = Intent(this, SessionService::class.java)
        if (open <= 0) {
            stopService(service)
            return
        }
        if (SessionService.running) {
            SessionService.update(this, open)
            return
        }
        askToNotify()
        try {
            startForegroundService(service.putExtra(SessionService.EXTRA_OPEN, open))
        } catch (e: IllegalStateException) {
            // Android refuses to start one from the background; the app
            // asks again when it comes back to the front.
        }
    }

    private fun askToNotify() {
        if (askedToNotify || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        askedToNotify = true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onDestroy() {
        // Leaving the app for good ends its sessions with it.
        if (isFinishing) stopService(Intent(this, SessionService::class.java))
        super.onDestroy()
    }
}
