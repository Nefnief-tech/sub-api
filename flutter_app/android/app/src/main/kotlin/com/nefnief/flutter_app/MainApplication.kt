package com.nefnief.flutter_app

import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import io.flutter.app.FlutterApplication

class MainApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        // Must be registered before the foreground service starts so that
        // onEngineCreate fires with the alarm plugin already queued.
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(AlarmChannelLifecycleListener())
    }
}
