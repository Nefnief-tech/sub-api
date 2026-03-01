package com.nefnief.flutter_app

import android.content.Intent
import android.provider.AlarmClock
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.nefnief.vertretungsplan/alarm"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAlarm" -> {
                        val hour   = call.argument<Int>("hour")    ?: 0
                        val minute = call.argument<Int>("minute")  ?: 0
                        val label  = call.argument<String>("label") ?: "Schule"

                        // AlarmManager path (background-safe via AlarmHelper).
                        try {
                            AlarmHelper.set(this, hour, minute, label)
                        } catch (e: Exception) {
                            result.error("ALARM_ERROR", e.message, null)
                            return@setMethodCallHandler
                        }

                        // Bonus: also add to native Clock app when Activity is visible.
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
