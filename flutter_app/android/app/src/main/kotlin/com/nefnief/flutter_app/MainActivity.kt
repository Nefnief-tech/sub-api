package com.nefnief.flutter_app

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.AlarmClock
import android.view.WindowManager
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.nefnief.vertretungsplan/alarm"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableShowOnLockScreen()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Re-apply lock screen flags when app is brought to front by alarm notification
        enableShowOnLockScreen()
    }

    private fun enableShowOnLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            km.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON  or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON  or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAlarm" -> {
                        val hour   = call.argument<Int>("hour")    ?: 0
                        val minute = call.argument<Int>("minute")  ?: 0
                        val label  = call.argument<String>("label") ?: "Schule"

                        try {
                            AlarmHelper.set(this, hour, minute, label)
                        } catch (e: Exception) {
                            result.error("ALARM_ERROR", e.message, null)
                            return@setMethodCallHandler
                        }

                        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
                            try {
                                startActivity(Intent(AlarmClock.ACTION_SET_ALARM).apply {
                                    putExtra(AlarmClock.EXTRA_HOUR, hour)
                                    putExtra(AlarmClock.EXTRA_MINUTES, minute)
                                    putExtra(AlarmClock.EXTRA_MESSAGE, label)
                                    putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                                    putExtra(AlarmClock.EXTRA_VIBRATE, true)
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                })
                            } catch (_: Exception) { }
                        }

                        result.success("ok")
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
