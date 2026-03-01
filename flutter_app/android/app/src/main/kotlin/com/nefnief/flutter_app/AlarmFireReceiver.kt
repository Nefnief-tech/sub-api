package com.nefnief.flutter_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

class AlarmFireReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val label  = intent.getStringExtra("label")    ?: "Schule"
        val hour   = intent.getIntExtra("hour",    7)
        val minute = intent.getIntExtra("minute",  0)

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                "alarm_fire", "Wecker", NotificationManager.IMPORTANCE_HIGH
            ).apply { enableVibration(true) }
            nm.createNotificationChannel(ch)
        }

        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)!!
            .apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
        val pi = PendingIntent.getActivity(
            context, 0, launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notif = NotificationCompat.Builder(context, "alarm_fire")
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("⏰ $label")
            .setContentText(String.format("Aufstehen! %02d:%02d Uhr", hour, minute))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .build()

        nm.notify(1001, notif)
    }
}
