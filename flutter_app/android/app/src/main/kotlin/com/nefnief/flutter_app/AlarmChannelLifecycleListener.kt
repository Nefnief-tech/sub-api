package com.nefnief.flutter_app

import com.gdelataillade.alarm.alarm.AlarmPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine

/**
 * Registers the alarm plugin in the background Flutter engine created by
 * FlutterForegroundTask. Without this, Alarm.set() from the background
 * Dart isolate throws MissingPluginException (plugins aren't auto-registered
 * in background engines — only the foreground task channel is).
 */
class AlarmChannelLifecycleListener : FlutterForegroundTaskLifecycleListener {
    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        flutterEngine ?: return
        try {
            flutterEngine.plugins.add(AlarmPlugin())
        } catch (_: Exception) {
            // Already registered in the main engine via GeneratedPluginRegistrant — fine.
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}
    override fun onTaskRepeatEvent() {}
    override fun onTaskDestroy() {}
    override fun onEngineWillDestroy() {}
}
