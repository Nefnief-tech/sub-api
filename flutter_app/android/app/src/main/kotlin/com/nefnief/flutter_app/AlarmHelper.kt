package com.nefnief.flutter_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import java.util.Calendar

object AlarmHelper {
    fun set(context: Context, hour: Int, minute: Int, label: String) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) {
                add(Calendar.DAY_OF_MONTH, 1)
            }
        }

        val showIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)!!
            .apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
        val showPi = PendingIntent.getActivity(
            context, 0, showIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val fireIntent = Intent(context, AlarmFireReceiver::class.java).apply {
            putExtra("label",  label)
            putExtra("hour",   hour)
            putExtra("minute", minute)
        }
        val firePi = PendingIntent.getBroadcast(
            context, hour * 60 + minute, fireIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        alarmManager.setAlarmClock(AlarmManager.AlarmClockInfo(cal.timeInMillis, showPi), firePi)
    }
}
