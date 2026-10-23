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
import java.util.concurrent.Executors

// Installs a downloaded APK of a newer Promptly over this one
// (lib/features/updates/updates.dart). Android shows its own "update this
// app?" screen unless this copy installed the one it replaces (Android 12
// and later), then closes the app and replaces it. The call's result comes
// back only if that does not happen: cancelled, or failed.
class AppUpdater(private val activity: Activity) {
    // The waiting call and the installer session it is for. Touched on the
    // main thread only.
    private var pending: MethodChannel.Result? = null
    private var sessionId = NO_SESSION
    private var receiver: BroadcastReceiver? = null

    // Copying a 100 MB APK into the session takes a while on slow storage,
    // so it happens here rather than on the main thread.
    private val worker = Executors.newSingleThreadExecutor()

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
        pending = result
        val installer = activity.packageManager.packageInstaller
        worker.execute {
            var id = NO_SESSION
            try {
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(activity.packageName)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                    }
                }
                id = installer.createSession(params)
                val file = File(path)
                installer.openSession(id).use { session ->
                    session.openWrite("promptly.apk", 0, file.length()).use { out ->
                        file.inputStream().use { it.copyTo(out) }
                        session.fsync(out)
                    }
                }
                val staged = id
                activity.runOnUiThread { commit(staged) }
            } catch (e: Exception) {
                // Nothing was handed to Android: drop what was staged.
                if (id != NO_SESSION) abandon(id)
                activity.runOnUiThread { finish { it.error("failed", e.message, null) } }
            }
        }
    }

    // Listen for the installer's answer, then hand it the session.
    private fun commit(id: Int) {
        if (pending == null) {
            abandon(id)
            return
        }
        sessionId = id
        listen()
        val status = Intent(ACTION_STATUS).setPackage(activity.packageName)
        // Mutable: the installer adds the status to it.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        try {
            activity.packageManager.packageInstaller.openSession(id).use { session ->
                session.commit(PendingIntent.getBroadcast(activity, id, status, flags).intentSender)
            }
        } catch (e: Exception) {
            abandon(id)
            finish { it.error("failed", e.message, null) }
        }
    }

    private fun abandon(id: Int) {
        try {
            activity.packageManager.packageInstaller.abandonSession(id)
        } catch (e: Exception) {
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

    private fun listen() {
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                // Only the answer for this update's session counts.
                if (intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, NO_SESSION) != sessionId) return
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
                        try {
                            if (confirm == null) throw IllegalStateException("no install screen")
                            activity.startActivity(confirm)
                        } catch (e: Exception) {
                            finish { it.error("failed", "Android did not show its install screen.", null) }
                        }
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
        // Only senders holding Promptly's own signature permission get
        // through: this app, and so the installer, which answers through a
        // PendingIntent this app made. Before Android 13 a receiver
        // registered without one would take broadcasts from any app.
        val filter = IntentFilter(ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(r, filter, PERMISSION_STATUS, null, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity.registerReceiver(r, filter, PERMISSION_STATUS, null)
        }
    }

    // Answer the waiting call once and stop listening.
    private fun finish(answer: (MethodChannel.Result) -> Unit) {
        receiver?.let {
            try {
                activity.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
            }
        }
        receiver = null
        sessionId = NO_SESSION
        val result = pending ?: return
        pending = null
        answer(result)
    }

    companion object {
        private const val ACTION_STATUS = "dev.promptly.promptly.UPDATE_STATUS"
        // Declared in AndroidManifest.xml with protectionLevel signature.
        private const val PERMISSION_STATUS = "dev.promptly.promptly.permission.UPDATE_STATUS"
        private const val NO_SESSION = -1
    }
}
