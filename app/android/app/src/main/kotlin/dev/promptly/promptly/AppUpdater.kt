package dev.promptly.promptly

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

// Installs a downloaded APK of a newer Promptly over this one
// (lib/features/updates/updates.dart). Android shows its own "update this
// app?" screen unless this copy installed the one it replaces (Android 12
// and later), then closes the app and replaces it. The call's result comes
// back only if that does not happen: cancelled, or failed.
class AppUpdater(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var receiver: BroadcastReceiver? = null

    fun install(path: String, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "An update is already being installed.", null)
            return
        }
        // Play updates its own installs, and signs them with another key,
        // so a GitHub APK could not replace one anyway.
        if (installedBy() == "com.android.vending") {
            result.error("play", "Google Play installed this copy.", null)
            return
        }
        val file = File(path)
        val installer = activity.packageManager.packageInstaller
        try {
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(activity.packageName)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
            }
            val id = installer.createSession(params)
            installer.openSession(id).use { session ->
                session.openWrite("promptly.apk", 0, file.length()).use { out ->
                    file.inputStream().use { it.copyTo(out) }
                    session.fsync(out)
                }
                listen(result)
                val status = Intent(ACTION_STATUS).setPackage(activity.packageName)
                // Mutable: the installer adds the status to it.
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                session.commit(PendingIntent.getBroadcast(activity, id, status, flags).intentSender)
            }
        } catch (e: IOException) {
            finish { it.error("failed", e.message, null) } ?: result.error("failed", e.message, null)
        } catch (e: SecurityException) {
            finish { it.error("failed", e.message, null) } ?: result.error("failed", e.message, null)
        }
    }

    private fun installedBy(): String? = try {
        val pm = activity.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            pm.getInstallSourceInfo(activity.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            pm.getInstallerPackageName(activity.packageName)
        }
    } catch (e: Exception) {
        null
    }

    private fun listen(result: MethodChannel.Result) {
        pending = result
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                    // Android's confirmation screen, which also leads to
                    // allowing installs from Promptly the first time.
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        }
                        if (confirm != null) activity.startActivity(confirm)
                        else finish { it.error("failed", "Android did not show its install screen.", null) }
                    }
                    PackageInstaller.STATUS_SUCCESS -> finish { it.success(null) }
                    PackageInstaller.STATUS_FAILURE_ABORTED -> finish { it.error("cancelled", null, null) }
                    else -> finish {
                        it.error("failed", intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE), null)
                    }
                }
            }
        }
        receiver = r
        val filter = IntentFilter(ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity.registerReceiver(r, filter)
        }
    }

    // Answer the waiting call once and stop listening. Null when nothing
    // was waiting.
    private fun finish(answer: (MethodChannel.Result) -> Unit): Unit? {
        receiver?.let {
            try {
                activity.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
            }
        }
        receiver = null
        val result = pending ?: return null
        pending = null
        answer(result)
        return Unit
    }

    companion object {
        private const val ACTION_STATUS = "dev.promptly.promptly.UPDATE_STATUS"
    }
}
