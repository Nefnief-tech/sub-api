package com.nefnief.flutter_app

import android.content.Intent
import android.provider.AlarmClock
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
                        val hour   = call.argument<Int>("hour")   ?: 0
                        val minute = call.argument<Int>("minute") ?: 0
                        val label  = call.argument<String>("label") ?: "Schule"

                        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                            putExtra(AlarmClock.EXTRA_HOUR, hour)
                            putExtra(AlarmClock.EXTRA_MINUTES, minute)
                            putExtra(AlarmClock.EXTRA_MESSAGE, label)
                            putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                            putExtra(AlarmClock.EXTRA_VIBRATE, true)
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }

                        try {
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("ALARM_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
