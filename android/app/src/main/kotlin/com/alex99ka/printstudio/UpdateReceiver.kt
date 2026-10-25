package com.alex99ka.printstudio

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.SystemClock
import java.io.File

// The updater writes a
// downloaded build into an install session at once (stage); MainActivity arms
// an alarm whenever the app leaves the screen and disarms it when it comes
// back, so the session is committed only after the app has been out of sight
// for QUIET_FOR_MS — never under someone using it.
//
// Android 12+ lets an app that updates itself skip the "update?" screen
// (setRequireUserAction), so nothing is shown: the process is replaced and the
// next launch is the new version. If Android asks for a tap after all, the
// phone is marked and goes back to the tap-to-update banner.
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_QUIET -> if (!MainActivity.visible) commitStaged(context)
            ACTION_STATUS -> if (
                intent.getIntExtra(PackageInstaller.EXTRA_STATUS, 0) ==
                PackageInstaller.STATUS_PENDING_USER_ACTION
            ) {
                prefs(context).edit().putBoolean(REFUSED, true).apply()
                unstage(context)
            }
        }
    }

    companion object {
        private const val ACTION_QUIET = "com.alex99ka.printstudio.UPDATE_QUIET"
        private const val ACTION_STATUS = "com.alex99ka.printstudio.UPDATE_STATUS"
        private const val REFUSED = "quiet_update_refused"
        private const val QUIET_FOR_MS = 10 * 60 * 1000L

        private fun prefs(context: Context) =
            context.getSharedPreferences("app_update", Context.MODE_PRIVATE)

        private fun installer(context: Context) = context.packageManager.packageInstaller

        // True when the build will install by itself; false leaves it to a tap.
        fun stage(context: Context, apk: File): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                !context.packageManager.canRequestPackageInstalls() ||
                prefs(context).getBoolean(REFUSED, false)
            ) return false
            unstage(context)
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            ).apply {
                setAppPackageName(context.packageName)
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            val id = installer(context).createSession(params)
            installer(context).openSession(id).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("base.apk", 0, apk.length()).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
            }
            return true
        }

        // Drops a staged build: installed already, or replaced by a newer one.
        fun unstage(context: Context) {
            installer(context).mySessions.forEach {
                runCatching { installer(context).abandonSession(it.sessionId) }
            }
        }

        private fun commitStaged(context: Context) {
            val session = installer(context).mySessions.firstOrNull() ?: return
            val status = PendingIntent.getBroadcast(
                context, 0,
                Intent(context, UpdateReceiver::class.java).setAction(ACTION_STATUS),
                // Mutable: the installer adds the outcome to it.
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
            runCatching {
                installer(context).openSession(session.sessionId).use {
                    it.commit(status.intentSender)
                }
            }
        }

        // MainActivity: armed when the app leaves the screen, disarmed when
        // it returns.
        fun arm(context: Context, on: Boolean) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
            val alarms = context.getSystemService(AlarmManager::class.java)
            val quiet = PendingIntent.getBroadcast(
                context, 1,
                Intent(context, UpdateReceiver::class.java).setAction(ACTION_QUIET),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarms.cancel(quiet)
            if (on && installer(context).mySessions.isNotEmpty()) {
                alarms.set(
                    AlarmManager.ELAPSED_REALTIME,
                    SystemClock.elapsedRealtime() + QUIET_FOR_MS,
                    quiet
                )
            }
        }
    }
}
