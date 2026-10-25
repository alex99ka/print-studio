package com.alex99ka.printstudio

import android.content.Intent
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FlutterFragmentActivity, not FlutterActivity: local_auth shows the system
// biometric prompt as a fragment, and on a plain activity every fingerprint
// attempt fails with "The current Activity must be a FragmentActivity".
class MainActivity : FlutterFragmentActivity() {

    companion object {
        // Whether the app is on screen; a staged update waits while it is.
        @Volatile var visible = false
    }

    override fun onStart() {
        super.onStart()
        visible = true
        UpdateReceiver.arm(this, false)
    }

    override fun onStop() {
        super.onStop()
        visible = false
        if (!isChangingConfigurations) UpdateReceiver.arm(this, true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // The in-app updater (lib/core/update.dart).
        MethodChannel(messenger, "app/update").setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        packageManager.canRequestPackageInstalls()
                )
                "allowInstalls" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        )
                    )
                    result.success(null)
                }
                // Copying the APK into the session is kept off the UI thread.
                "stage" -> {
                    val path = call.argument<String>("path")
                    Thread {
                        val staged = path != null && runCatching {
                            UpdateReceiver.stage(this, File(path))
                        }.getOrDefault(false)
                        runOnUiThread { result.success(staged) }
                    }.start()
                }
                "unmetered" -> result.success(
                    !getSystemService(ConnectivityManager::class.java).isActiveNetworkMetered
                )
                "unstage" -> {
                    runCatching { UpdateReceiver.unstage(this) }
                    result.success(null)
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("no-path", "no file to install", null)
                    } else try {
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                // CLEAR_TASK: an earlier attempt cancelled or timed out
                                // in Play Protect leaves the installer at "App not
                                // installed", and NEW_TASK alone brings that screen back.
                                .addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK or
                                        Intent.FLAG_ACTIVITY_CLEAR_TASK
                                )
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("install-failed", e.toString(), null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Turning the fingerprint lock on when nothing is enrolled: the phone's
        // own enrollment screen (lib/core/lock.dart waits for the return).
        MethodChannel(messenger, "app/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "enrollBiometrics" -> {
                    val intent = when {
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                            Intent(Settings.ACTION_BIOMETRIC_ENROLL).putExtra(
                                Settings.EXTRA_BIOMETRIC_AUTHENTICATORS_ALLOWED,
                                android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG
                            )
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ->
                            @Suppress("DEPRECATION") Intent(Settings.ACTION_FINGERPRINT_ENROLL)
                        else -> Intent(Settings.ACTION_SECURITY_SETTINGS)
                    }
                    try {
                        startActivity(intent)
                    } catch (e: Exception) {
                        // Some phones lack the direct screen: security settings instead.
                        startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
