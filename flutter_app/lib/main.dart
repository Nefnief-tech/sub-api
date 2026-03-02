import 'dart:async';
import 'dart:convert';
import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:permission_handler/permission_handler.dart';

// ── Colors ────────────────────────────────────────────────────────────────────
const _bg       = Color(0xFF0D0F14);
const _bg2      = Color(0xFF151820);
const _bg3      = Color(0xFF1C2030);
const _border   = Color(0xFF252A3A);
const _accent   = Color(0xFF22D1A5);
const _accentDim= Color(0x1A22D1A5);
const _red      = Color(0xFFF43F5E);
const _redDim   = Color(0x1AF43F5E);
const _text     = Color(0xFFE2E8F0);
const _muted    = Color(0xFF64748B);

// ── Foreground service entry point ────────────────────────────────────────────
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(GotifyTaskHandler());
}

// ── Task handler (runs in background isolate) ─────────────────────────────────
class GotifyTaskHandler extends TaskHandler {
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  static final _alarmRx = RegExp(r'⏰ Wecker[:\s]+(\d{1,2}):(\d{2})');

  final _localNotif = FlutterLocalNotificationsPlugin();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await Alarm.init();

    await _localNotif.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    // Alarm fires in THIS (background) isolate — forward the event to main.
    Alarm.ringing.listen((alarmSet) {
      for (final alarm in alarmSet.alarms) {
        FlutterForegroundTask.sendDataToMain({
          'type': 'alarm_ringing',
          'id': alarm.id,
        });
      }
    });

    // After boot, re-register saved alarm if the alarm package lost it
    await _restoreAlarmIfNeeded();

    final url   = await FlutterForegroundTask.getData<String>(key: 'gotify_url')   ?? '';
    final token = await FlutterForegroundTask.getData<String>(key: 'gotify_token') ?? '';
    _connect(url, token);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Watchdog: reconnect if WS died
    if (_channel == null) _reconnectFromPrefs();
    // Watchdog: re-register alarm if it was dropped (e.g. by battery saver)
    _restoreAlarmIfNeeded();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
  }

  /// Saves alarm to foreground task storage so it survives a full process kill.
  static Future<void> persistAlarm(int h, int m, String label) async {
    await FlutterForegroundTask.saveData(key: 'alarm_h',     value: h.toString());
    await FlutterForegroundTask.saveData(key: 'alarm_m',     value: m.toString());
    await FlutterForegroundTask.saveData(key: 'alarm_label', value: label);
  }

  Future<void> _restoreAlarmIfNeeded() async {
    final hStr = await FlutterForegroundTask.getData<String>(key: 'alarm_h') ?? '';
    final mStr = await FlutterForegroundTask.getData<String>(key: 'alarm_m') ?? '';
    if (hStr.isEmpty || mStr.isEmpty) return;
    final h = int.tryParse(hStr);
    final m = int.tryParse(mStr);
    if (h == null || m == null) return;

    // Check if alarm is already registered
    final existing = await Alarm.getAlarms();
    if (existing.any((a) => a.id == 1)) return;

    // Re-register
    final now = DateTime.now();
    var alarmDt = DateTime(now.year, now.month, now.day, h, m);
    if (alarmDt.isBefore(now)) alarmDt = alarmDt.add(const Duration(days: 1));
    final label = await FlutterForegroundTask.getData<String>(key: 'alarm_label') ?? '⏰ Wecker';
    final t = '${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}';

    await Alarm.set(
      alarmSettings: AlarmSettings(
        id: 1,
        dateTime: alarmDt,
        assetAudioPath: null,
        loopAudio: true,
        vibrate: true,
        androidFullScreenIntent: true,
        androidStopAlarmOnTermination: false,
        volumeSettings: VolumeSettings.fade(
          volume: 0.8,
          fadeDuration: const Duration(seconds: 5),
        ),
        notificationSettings: NotificationSettings(
          title: '⏰ Wecker — $t Uhr',
          body: label,
          stopButton: 'Snooze',
        ),
      ),
    );
    FlutterForegroundTask.updateService(notificationText: '⏰ Wecker wiederhergestellt: $t');
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map) {
      final url   = (data['url']   as String? ?? '').trim();
      final token = (data['token'] as String? ?? '').replaceAll(RegExp(r'[#\s]'), '');
      _reconnectTimer?.cancel();
      _channel?.sink.close();
      _channel = null;
      _connect(url, token);
    }
  }

  Future<void> _reconnectFromPrefs() async {
    final url   = await FlutterForegroundTask.getData<String>(key: 'gotify_url')   ?? '';
    final token = await FlutterForegroundTask.getData<String>(key: 'gotify_token') ?? '';
    _connect(url, token);
  }

  void _connect(String url, String token) {
    if (url.isEmpty || token.isEmpty) {
      _send({'type': 'status', 'connected': false, 'msg': 'URL oder Token fehlt'});
      return;
    }
    _send({'type': 'status', 'connected': false, 'msg': 'Verbinde…'});

    final base    = url.replaceAll(RegExp(r'/+$'), '');
    final httpUri = Uri.parse(base);
    final wsUri   = Uri(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
      host:   httpUri.host,
      port:   httpUri.hasPort ? httpUri.port : null,
      path:   '${httpUri.path}/stream',
      queryParameters: {'token': token},
    );

    try {
      _channel = WebSocketChannel.connect(wsUri);
      _channel!.ready.then((_) {
        _send({'type': 'status', 'connected': true, 'msg': 'Verbunden — warte auf Nachrichten…'});
        FlutterForegroundTask.updateService(notificationText: '🟢 Verbunden — warte auf Nachrichten…');
      }).catchError((e) {
        _channel = null;
        final hint = e.toString().contains('401')
            ? 'Fehler 401: Client-Token benötigt!'
            : 'Fehler: ${e.toString().substring(0, 60)}';
        _send({'type': 'status', 'connected': false, 'msg': hint});
        FlutterForegroundTask.updateService(notificationText: '🔴 Verbindungsfehler');
        _scheduleReconnect(url, token);
      });

      _channel!.stream.listen(
        _onMessage,
        onError: (_) {
          _channel = null;
          _send({'type': 'status', 'connected': false, 'msg': 'Verbindung verloren — verbinde neu…'});
          _scheduleReconnect(url, token);
        },
        onDone: () {
          _channel = null;
          _send({'type': 'status', 'connected': false, 'msg': 'Getrennt — verbinde neu…'});
          _scheduleReconnect(url, token);
        },
        cancelOnError: true,
      );
    } catch (e) {
      _channel = null;
      _send({'type': 'status', 'connected': false, 'msg': 'Fehler: $e'});
      _scheduleReconnect(url, token);
    }
  }

  void _scheduleReconnect(String url, String token) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 15), () => _connect(url, token));
  }

  Future<void> _onMessage(dynamic raw) async {
    try {
      final msg   = jsonDecode(raw as String);
      final title = (msg['title']   as String?) ?? '';
      final body  = (msg['message'] as String?) ?? '';

      // Silent timetable update — no notification, just forward the data
      if (title == '__timetable__') {
        _send({'type': 'timetable', 'data': body});
        return;
      }

      // Show a local notification for every incoming Gotify message
      await _localNotif.show(
        DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'gotify_messages',
            'Gotify Nachrichten',
            channelDescription: 'Benachrichtigungen vom Gotify Server',
            importance: Importance.max,
            priority: Priority.max,
            fullScreenIntent: true,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
      );
      _send({'type': 'notification', 'title': title, 'message': body});

      // If it's an alarm message, additionally set the device alarm
      final match = _alarmRx.firstMatch(title);
      if (match == null) return;
      final h = int.parse(match.group(1)!);
      final m = int.parse(match.group(2)!);
      final t = '${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}';

      final now = DateTime.now();
      var alarmDt = DateTime(now.year, now.month, now.day, h, m);
      if (alarmDt.isBefore(now)) alarmDt = alarmDt.add(const Duration(days: 1));

      await Alarm.set(
        alarmSettings: AlarmSettings(
          id: 1,
          dateTime: alarmDt,
          assetAudioPath: null,
          loopAudio: true,
          vibrate: true,
          androidFullScreenIntent: true,
          androidStopAlarmOnTermination: false,
          volumeSettings: VolumeSettings.fade(
            volume: 0.8,
            fadeDuration: const Duration(seconds: 5),
          ),
          notificationSettings: NotificationSettings(
            title: '⏰ Wecker — $t Uhr',
            body: title,
            stopButton: 'Snooze',
          ),
        ),
      );

      // Persist alarm so it can be re-registered after a device restart
      await GotifyTaskHandler.persistAlarm(h, m, title);

      _send({'type': 'alarm', 'hour': h, 'minute': m, 'time': t, 'label': title});
      FlutterForegroundTask.updateService(notificationText: '⏰ Wecker gesetzt: $t');
    } catch (e) {
      _send({'type': 'status', 'connected': true, 'msg': 'Fehler: $e'});
    }
  }

  void _send(Map<String, dynamic> data) =>
      FlutterForegroundTask.sendDataToMain(data);
}

// ── App state (UI only, updated via task callbacks) ───────────────────────────
class AlarmEntry {
  final String time, label;
  final DateTime setAt;
  AlarmEntry({required this.time, required this.label, required this.setAt});

  Map<String, dynamic> toJson() =>
      {'time': time, 'label': label, 'setAt': setAt.toIso8601String()};

  factory AlarmEntry.fromJson(Map<String, dynamic> j) => AlarmEntry(
        time:  j['time']  as String,
        label: j['label'] as String,
        setAt: DateTime.parse(j['setAt'] as String),
      );
}

class NotifEntry {
  final String title, message;
  final DateTime receivedAt;
  NotifEntry({required this.title, required this.message, required this.receivedAt});

  Map<String, dynamic> toJson() => {
        'title': title, 'message': message,
        'receivedAt': receivedAt.toIso8601String(),
      };

  factory NotifEntry.fromJson(Map<String, dynamic> j) => NotifEntry(
        title:      j['title']   as String,
        message:    j['message'] as String,
        receivedAt: DateTime.parse(j['receivedAt'] as String),
      );
}

class AppState extends ChangeNotifier {
  bool   _connected = false;
  String _statusMsg = 'Starte Dienst…';
  final List<AlarmEntry>  alarms        = [];
  final List<NotifEntry>  notifications = [];
  Map<String, dynamic>?   timetable;

  bool   get connected => _connected;
  String get statusMsg => _statusMsg;

  Future<void> loadFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final nJson = prefs.getString('notif_history');
    if (nJson != null) {
      final list = jsonDecode(nJson) as List;
      notifications.addAll(list.map((e) => NotifEntry.fromJson(Map<String, dynamic>.from(e as Map))));
    }
    final aJson = prefs.getString('alarm_history');
    if (aJson != null) {
      final list = jsonDecode(aJson) as List;
      alarms.addAll(list.map((e) => AlarmEntry.fromJson(Map<String, dynamic>.from(e as Map))));
    }
    final ttJson = prefs.getString('timetable');
    if (ttJson != null) {
      timetable = Map<String, dynamic>.from(jsonDecode(ttJson) as Map);
    }
    notifyListeners();
  }

  Future<void> _saveNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('notif_history', jsonEncode(notifications.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveAlarms() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('alarm_history', jsonEncode(alarms.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveTimetable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('timetable', jsonEncode(timetable));
  }

  void onTaskData(Object data) {
    if (data is! Map) return;
    final type = data['type'] as String?;
    if (type == 'status') {
      _connected = (data['connected'] as bool?) ?? false;
      _statusMsg = (data['msg']       as String?) ?? '';
      notifyListeners();
    } else if (type == 'timetable') {
      try {
        timetable = Map<String, dynamic>.from(jsonDecode(data['data'] as String) as Map);
        _statusMsg = '📅 Stundenplan aktualisiert';
        notifyListeners();
        _saveTimetable();
      } catch (_) {}
    } else if (type == 'notification') {
      final title   = (data['title']   as String?) ?? '';
      final message = (data['message'] as String?) ?? '';
      notifications.insert(0, NotifEntry(title: title, message: message, receivedAt: DateTime.now()));
      if (notifications.length > 50) notifications.removeLast();
      _statusMsg = '📨 $title';
      notifyListeners();
      _saveNotifications();
    } else if (type == 'alarm') {
      final h     = (data['hour']   as int?)    ?? 0;
      final m     = (data['minute'] as int?)    ?? 0;
      final t     = (data['time']   as String?) ?? '$h:$m';
      final label = (data['label']  as String?) ?? '⏰ Wecker';
      alarms.insert(0, AlarmEntry(time: t, label: label, setAt: DateTime.now()));
      if (alarms.length > 20) alarms.removeLast();
      _statusMsg = '✅ Wecker gestellt: $t Uhr';
      notifyListeners();
      _saveAlarms();
    }
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────
// Global notifier subscribed BEFORE runApp so we never miss an alarm event.
final _ringingAlarm = ValueNotifier<AlarmSettings?>(null);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  await Alarm.init();

  // Listen for future ring events (stream fires if main engine holds alarmTriggerApi).
  Alarm.ringing.listen((alarmSet) {
    if (alarmSet.alarms.isNotEmpty) {
      _ringingAlarm.value = alarmSet.alarms.first;
    }
  });

  // Cold-start check: alarm may already be ringing when app first opens.
  await _checkAlarmRinging();

  // Resume check: when full-screen intent brings app from background, the main
  // engine was frozen so the stream event was missed — poll isRinging on resume.
  AppLifecycleListener(
    onResume: _checkAlarmRinging,
  );

  // Fallback: background isolate forwards alarm_ringing via sendDataToMain.
  FlutterForegroundTask.addTaskDataCallback((data) {
    if (data is! Map) return;
    if ((data['type'] as String?) == 'alarm_ringing') {
      _checkAlarmRinging();
    }
  });

  runApp(const VertretungsApp());
}

Future<void> _checkAlarmRinging() async {
  final alarms = await Alarm.getAlarms();
  for (final alarm in alarms) {
    if (await Alarm.isRinging(alarm.id)) {
      _ringingAlarm.value = alarm;
      return;
    }
  }
}

class VertretungsApp extends StatelessWidget {
  const VertretungsApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AlarmSettings?>(
      valueListenable: _ringingAlarm,
      builder: (context, alarm, _) {
        return MaterialApp(
          title: 'Vertretungsplan Alarm',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: const ColorScheme.dark(surface: _bg, primary: _accent),
            scaffoldBackgroundColor: _bg,
            textTheme: GoogleFonts.spaceGroteskTextTheme()
                .apply(bodyColor: _text, displayColor: _text),
          ),
          home: alarm != null
              ? RingScreen(
                  alarm: alarm,
                  onDismiss: () => _ringingAlarm.value = null,
                )
              : const HomeScreen(),
        );
      },
    );
  }
}

// ── Ring Screen ───────────────────────────────────────────────────────────────
class RingScreen extends StatefulWidget {
  final AlarmSettings alarm;
  final VoidCallback onDismiss;
  const RingScreen({super.key, required this.alarm, required this.onDismiss});
  @override State<RingScreen> createState() => _RingScreenState();
}

class _RingScreenState extends State<RingScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double>   _scale;
  bool _loading = false;

  String get _timeStr {
    final dt = widget.alarm.dateTime;
    return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  String get _label => widget.alarm.notificationSettings.title
      .replaceAll('⏰ Wecker — ', '').replaceAll(' Uhr', '');

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _scale = Tween(begin: 0.92, end: 1.08).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _stop() async {
    setState(() => _loading = true);
    await Alarm.stop(widget.alarm.id);
    widget.onDismiss();
  }

  Future<void> _snooze() async {
    setState(() => _loading = true);
    await Alarm.stop(widget.alarm.id);
    final snoozeTime = DateTime.now().add(const Duration(minutes: 10));
    await Alarm.set(
      alarmSettings: widget.alarm.copyWith(
        dateTime: snoozeTime,
        notificationSettings: widget.alarm.notificationSettings.copyWith(
          title: '⏰ Snooze — ${snoozeTime.hour.toString().padLeft(2,'0')}:${snoozeTime.minute.toString().padLeft(2,'0')} Uhr',
        ),
      ),
    );
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060810),
      body: SafeArea(
        child: Stack(
          children: [
            // Glow background
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _scale,
                builder: (_, __) => Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.2),
                      radius: 1.4 * _scale.value,
                      colors: const [
                        Color(0x3322D1A5),
                        Color(0x00060810),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            Column(
              children: [
                const Spacer(flex: 2),

                // Clock icon pulsing
                AnimatedBuilder(
                  animation: _scale,
                  builder: (_, __) => Transform.scale(
                    scale: _scale.value,
                    child: Container(
                      width: 120, height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: _accent, width: 2),
                        color: _accentDim,
                      ),
                      child: const Icon(Icons.alarm, size: 56, color: _accent),
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Time
                Text(
                  _timeStr,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 80,
                    fontWeight: FontWeight.w800,
                    color: _text,
                    letterSpacing: -4,
                  ),
                ),

                const SizedBox(height: 8),

                // Label from notification
                Text(
                  widget.alarm.notificationSettings.body,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 15,
                    color: _muted,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                ),

                const Spacer(flex: 3),

                // Snooze button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton.icon(
                      onPressed: _loading ? null : _snooze,
                      icon: const Icon(Icons.snooze, color: _accent),
                      label: Text('Snooze (10 min)',
                          style: GoogleFonts.spaceGrotesk(
                              color: _accent, fontWeight: FontWeight.w600, fontSize: 16)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: _accent, width: 1.5),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Stop button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _loading ? null : _stop,
                      icon: const Icon(Icons.alarm_off, color: Colors.white),
                      label: Text('Alarm stoppen',
                          style: GoogleFonts.spaceGrotesk(
                              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _red,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 48),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Home Screen ───────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  final _state      = AppState();
  final _urlCtrl    = TextEditingController();
  final _tokenCtrl  = TextEditingController();
  bool _showSettings = false;
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulse;
  late TabController       _tabCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulse = Tween(begin: 0.5, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _tabCtrl = TabController(length: 3, vsync: this);
    _state.addListener(() => setState(() {}));
    FlutterForegroundTask.addTaskDataCallback(_state.onTaskData);
    _state.loadFromStorage();
    _initService();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_state.onTaskData);
    _pulseCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _initService() async {
    await [
      Permission.notification,
      Permission.scheduleExactAlarm,
      Permission.ignoreBatteryOptimizations,
    ].request();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId:          'push_channel',
        channelName:        'Vertretungsplan Hintergrunddienst',
        channelDescription: 'Empfängt und setzt Alarm-Benachrichtigungen',
        onlyAlertOnce:      true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction:    ForegroundTaskEventAction.repeat(60000), // every 1 min watchdog
        autoRunOnBoot:  true,
        allowWakeLock:  true,
        allowWifiLock:  true,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    final url   = prefs.getString('gotify_url')   ?? '';
    final token = (prefs.getString('gotify_token') ?? '').replaceAll(RegExp(r'[#\s]'), '');
    _urlCtrl.text   = url;
    _tokenCtrl.text = token;

    // Save into foreground task store
    await FlutterForegroundTask.saveData(key: 'gotify_url',   value: url);
    await FlutterForegroundTask.saveData(key: 'gotify_token', value: token);

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else if (url.isNotEmpty && token.isNotEmpty) {
      await _startService();
    } else {
      setState(() => _showSettings = true); // first launch → go to settings
    }
  }

  Future<void> _startService() async {
    await FlutterForegroundTask.startService(
      serviceId:        256,
      notificationTitle: 'Vertretungsplan',
      notificationText:  '🔴 Verbinde…',
      callback:          startCallback,
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final url   = _urlCtrl.text.trim();
    final token = _tokenCtrl.text.trim().replaceAll(RegExp(r'[#\s]'), '');
    await prefs.setString('gotify_url',   url);
    await prefs.setString('gotify_token', token);
    await FlutterForegroundTask.saveData(key: 'gotify_url',   value: url);
    await FlutterForegroundTask.saveData(key: 'gotify_token', value: token);

    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask({'url': url, 'token': token});
    } else {
      await _startService();
    }
    setState(() => _showSettings = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _showSettings ? _buildSettings() : _buildHome(),
      ),
    ),
  );

  Widget _buildHome() => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildHeader(),
      const SizedBox(height: 24),
      _buildStatusCard(),
      const SizedBox(height: 16),
      _buildNextAlarm(),
      const SizedBox(height: 16),
      TabBar(
        controller: _tabCtrl,
        labelColor: _accent,
        unselectedLabelColor: _muted,
        indicatorColor: _accent,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: _border,
        labelStyle: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600, fontSize: 13),
        tabs: const [Tab(text: '📨 Nachrichten'), Tab(text: '⏰ Alarme'), Tab(text: '📅 Stundenplan')],
      ),
      const SizedBox(height: 8),
      Expanded(child: TabBarView(
        controller: _tabCtrl,
        children: [_buildNotifFeed(), _buildAlarmHistory(), _buildTimetable()],
      )),
    ]),
  );

  Widget _buildHeader() => Row(children: [
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Vertretungsplan',
        style: GoogleFonts.spaceGrotesk(fontSize: 22, fontWeight: FontWeight.w700, color: _text)),
      Text('Wecker-Automatik',
        style: GoogleFonts.jetBrainsMono(fontSize: 12, color: _accent)),
    ]),
    const Spacer(),
    GestureDetector(
      onTap: () => setState(() => _showSettings = true),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _bg3, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border)),
        child: const Icon(Icons.settings_outlined, color: _muted, size: 20),
      ),
    ),
  ]);

  Widget _buildStatusCard() {
    final ok = _state.connected;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ok ? _accentDim : _redDim,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ok ? _accent.withOpacity(0.3) : _red.withOpacity(0.3)),
      ),
      child: Row(children: [
        AnimatedBuilder(
          animation: _pulse,
          builder: (_, __) => Opacity(
            opacity: ok ? _pulse.value : 1.0,
            child: Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ok ? _accent : _red,
                boxShadow: [BoxShadow(
                  color: (ok ? _accent : _red).withOpacity(0.5),
                  blurRadius: 8 * (ok ? _pulse.value : 1.0),
                )],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(_state.statusMsg,
          style: GoogleFonts.jetBrainsMono(fontSize: 12, color: ok ? _accent : _red))),
      ]),
    );
  }

  Widget _buildNextAlarm() {
    final last = _state.alarms.isEmpty ? null : _state.alarms.first;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: _bg2, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border)),
      child: Row(children: [
        const Text('⏰', style: TextStyle(fontSize: 32)),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(last != null ? '${last.time} Uhr' : '– – : – –',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 36, fontWeight: FontWeight.w800,
              color: last != null ? _text : _muted, letterSpacing: -1)),
          Text(last != null ? 'Letzter Wecker gestellt' : 'Noch kein Wecker empfangen',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, color: _muted)),
        ]),
      ]),
    );
  }

  Widget _buildNotifFeed() {
    if (_state.notifications.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.notifications_none_outlined, color: _muted, size: 40),
        const SizedBox(height: 12),
        Text('Keine Nachrichten bisher',
          style: GoogleFonts.spaceGrotesk(color: _muted, fontSize: 14)),
        const SizedBox(height: 4),
        Text('Gotify-Nachrichten erscheinen hier',
          style: GoogleFonts.spaceGrotesk(color: _muted.withOpacity(0.6), fontSize: 12)),
      ]));
    }
    return ListView.separated(
      itemCount: _state.notifications.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final e = _state.notifications[i];
        final t = '${e.receivedAt.hour.toString().padLeft(2,'0')}:${e.receivedAt.minute.toString().padLeft(2,'0')}';
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _bg2, borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(e.title,
                style: GoogleFonts.spaceGrotesk(fontSize: 13, fontWeight: FontWeight.w600, color: _text))),
              Text(t, style: GoogleFonts.jetBrainsMono(fontSize: 11, color: _muted)),
            ]),
            if (e.message.isNotEmpty) ...[
              const SizedBox(height: 6),
              MarkdownBody(
                data: e.message,
                softLineBreak: true,
                styleSheet: MarkdownStyleSheet(
                  p:     const TextStyle(fontSize: 12, color: _muted, height: 1.5),
                  strong: const TextStyle(fontSize: 12, color: _text, fontWeight: FontWeight.bold, height: 1.5),
                  em:    const TextStyle(fontSize: 12, color: _muted, fontStyle: FontStyle.italic, height: 1.5),
                  code:  TextStyle(fontSize: 11, color: _accent, backgroundColor: _bg3,
                                   fontFamily: 'monospace'),
                  blockquoteDecoration: const BoxDecoration(
                    color: _bg3,
                    border: Border(left: BorderSide(color: _accent, width: 3)),
                  ),
                  blockquotePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  horizontalRuleDecoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: _border, width: 1)),
                  ),
                  blockSpacing: 6,
                ),
              ),
            ],
          ]),
        );
      },
    );
  }

  Widget _buildAlarmHistory() {
    if (_state.alarms.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.alarm_outlined, color: _muted, size: 40),
        const SizedBox(height: 12),
        Text('Keine Alarme bisher',
          style: GoogleFonts.spaceGrotesk(color: _muted, fontSize: 14)),
        const SizedBox(height: 4),
        Text('Wecker werden automatisch gestellt,\nsobald eine Alarm-Nachricht eintrifft',
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(color: _muted.withOpacity(0.6), fontSize: 12)),
      ]));
    }
    return ListView.separated(
      itemCount: _state.alarms.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final e = _state.alarms[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: _bg2, borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _border)),
          child: Row(children: [
            const Text('⏰', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.time,
                style: GoogleFonts.jetBrainsMono(fontSize: 16, fontWeight: FontWeight.w600, color: _accent)),
              Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: GoogleFonts.spaceGrotesk(fontSize: 12, color: _muted)),
            ])),
            Text('${e.setAt.hour.toString().padLeft(2,'0')}:${e.setAt.minute.toString().padLeft(2,'0')}',
              style: GoogleFonts.jetBrainsMono(fontSize: 11, color: _muted)),
          ]),
        );
      },
    );
  }

  Widget _buildTimetable() {
    final tt = _state.timetable;
    if (tt == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.table_chart_outlined, color: _muted, size: 40),
        const SizedBox(height: 12),
        Text('Kein Stundenplan empfangen',
          style: GoogleFonts.spaceGrotesk(color: _muted, fontSize: 14)),
        const SizedBox(height: 4),
        Text('Wird nach der nächsten Synchronisation\nautomatisch geladen',
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(color: _muted.withOpacity(0.6), fontSize: 12)),
      ]));
    }

    final days  = List<String>.from((tt['days'] as List?) ?? []);
    final slots = (tt['slots'] as List?) ?? [];
    if (days.isEmpty || slots.isEmpty) {
      return Center(child: Text('Stundenplan leer',
        style: GoogleFonts.spaceGrotesk(color: _muted, fontSize: 14)));
    }

    return StatefulBuilder(builder: (ctx, setDay) {
      int selDay = 0;
      return StatefulBuilder(builder: (ctx2, setDay2) {
        return Column(children: [
          // Day selector
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(children: List.generate(days.length, (i) {
              final active = i == selDay;
              return GestureDetector(
                onTap: () => setDay2(() => selDay = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: active ? _accent : _bg2,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: active ? _accent : _border),
                  ),
                  child: Text(days[i].substring(0, days[i].length > 2 ? 2 : days[i].length),
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? _bg : _text,
                    )),
                ),
              );
            })),
          ),
          const SizedBox(height: 8),
          // Slots for selected day — trim trailing empty periods
          Expanded(child: Builder(builder: (ctx) {
            // Build filtered list: drop trailing slots with no subject
            final visible = slots.toList();
            while (visible.isNotEmpty) {
              final last  = visible.last as Map;
              final cells = (last['cells'] as List?) ?? [];
              final cell  = selDay < cells.length ? cells[selDay] : null;
              final subj  = cell is Map ? (cell['subject'] as String? ?? '') : '';
              if (subj.trim().isEmpty || subj == '–') {
                visible.removeLast();
              } else {
                break;
              }
            }
            return ListView.separated(
            itemCount: visible.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (_, i) {
              final slot   = visible[i] as Map;
              final cells  = (slot['cells'] as List?) ?? [];
              final cell   = selDay < cells.length ? cells[selDay] : null;
              final subj   = cell is Map ? (cell['subject'] as String? ?? '–') : '–';
              final room   = cell is Map ? (cell['room']    as String? ?? '')  : '';
              final period = slot['period']?.toString() ?? '${i + 1}';
              final time   = (slot['start_time'] as String?) ?? '';
              final isEmpty = subj == '–' || subj.trim().isEmpty;

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isEmpty ? _bg2.withOpacity(0.5) : _bg2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isEmpty ? _border.withOpacity(0.3) : _border),
                ),
                child: Row(children: [
                  Container(
                    width: 32, height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isEmpty ? _bg3 : _accentDim,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(period,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 13, fontWeight: FontWeight.w700,
                        color: isEmpty ? _muted : _accent)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(isEmpty ? 'Freistunde' : subj,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 15, fontWeight: FontWeight.w600,
                        color: isEmpty ? _muted : _text)),
                    if (room.isNotEmpty)
                      Text('Raum $room',
                        style: GoogleFonts.spaceGrotesk(fontSize: 12, color: _muted)),
                  ])),
                  if (time.isNotEmpty)
                    Text(time,
                      style: GoogleFonts.jetBrainsMono(fontSize: 11, color: _muted)),
                ]),
              );
            },
          );
          })),
        ]);
      });
    });
  }

  Widget _buildSettings() => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        GestureDetector(
          onTap: () => setState(() => _showSettings = false),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: _bg3, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _border)),
            child: const Icon(Icons.arrow_back, color: _text, size: 18),
          ),
        ),
        const SizedBox(width: 14),
        Text('Einstellungen',
          style: GoogleFonts.spaceGrotesk(fontSize: 20, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 32),
      _field('Gotify Server URL', _urlCtrl,
        hint: 'https://gotify.meinserver.de', icon: Icons.dns_outlined),
      const SizedBox(height: 16),
      _field('Client Token', _tokenCtrl,
        hint: '••••••••••••••••', icon: Icons.vpn_key_outlined, obscure: true),
      const SizedBox(height: 12),
      Text('Client-Token aus der Gotify Web-UI → Clients (nicht Apps!)',
        style: GoogleFonts.spaceGrotesk(fontSize: 12, color: _muted)),
      const Spacer(),
      SizedBox(width: double.infinity,
        child: ElevatedButton(
          onPressed: _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent, foregroundColor: _bg,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text('Verbinden',
            style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, fontSize: 16)),
        ),
      ),
    ]),
  );

  Widget _field(String label, TextEditingController ctrl,
      {String hint = '', IconData? icon, bool obscure = false}) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: GoogleFonts.spaceGrotesk(fontSize: 13, color: _muted, fontWeight: FontWeight.w500)),
      const SizedBox(height: 6),
      TextField(
        controller: ctrl, obscureText: obscure,
        style: GoogleFonts.jetBrainsMono(fontSize: 14, color: _text),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.jetBrainsMono(color: _muted.withOpacity(0.5)),
          prefixIcon: icon != null ? Icon(icon, color: _muted, size: 18) : null,
          filled: true, fillColor: _bg3,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _accent)),
        ),
      ),
    ]);
}
