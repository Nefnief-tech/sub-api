import 'dart:async';
import 'dart:convert';
import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await Alarm.init();
    final url   = await FlutterForegroundTask.getData<String>(key: 'gotify_url')   ?? '';
    final token = await FlutterForegroundTask.getData<String>(key: 'gotify_token') ?? '';
    _connect(url, token);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Watchdog: if channel is null something died — reload creds and reconnect
    if (_channel == null) _reconnectFromPrefs();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
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
        FlutterForegroundTask.updateService(notificationText: '🟢 Verbunden mit Gotify');
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
      final title = (msg['title'] as String?) ?? '';
      final match = _alarmRx.firstMatch(title);
      if (match == null) return;
      final h = int.parse(match.group(1)!);
      final m = int.parse(match.group(2)!);
      final t = '${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}';

      // Schedule alarm directly from the background isolate using the alarm package.
      // This works because alarm registers as a FlutterPlugin and is available
      // in the background engine (no main isolate needed).
      final now = DateTime.now();
      var alarmDt = DateTime(now.year, now.month, now.day, h, m);
      if (alarmDt.isBefore(now)) alarmDt = alarmDt.add(const Duration(days: 1));

      await Alarm.set(
        alarmSettings: AlarmSettings(
          id: 1,
          dateTime: alarmDt,
          assetAudioPath: null, // use device default alarm sound
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

      _send({'type': 'alarm', 'hour': h, 'minute': m, 'time': t, 'label': title});
      FlutterForegroundTask.updateService(notificationText: '⏰ Wecker gesetzt: $t');
    } catch (e) {
      _send({'type': 'status', 'connected': true, 'msg': 'Alarm-Fehler: $e'});
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
}

class AppState extends ChangeNotifier {
  bool   _connected = false;
  String _statusMsg = 'Starte Dienst…';
  final List<AlarmEntry> history = [];

  bool   get connected => _connected;
  String get statusMsg => _statusMsg;

  void onTaskData(Object data) {
    if (data is! Map) return;
    final type = data['type'] as String?;
    if (type == 'status') {
      _connected = (data['connected'] as bool?) ?? false;
      _statusMsg = (data['msg']       as String?) ?? '';
      notifyListeners();
    } else if (type == 'alarm') {
      final h     = (data['hour']   as int?)    ?? 0;
      final m     = (data['minute'] as int?)    ?? 0;
      final t     = (data['time']   as String?) ?? '$h:$m';
      final label = (data['label']  as String?) ?? '⏰ Wecker';
      history.insert(0, AlarmEntry(time: t, label: label, setAt: DateTime.now()));
      if (history.length > 20) history.removeLast();
      _statusMsg = '✅ Wecker gestellt: $t Uhr';
      notifyListeners();
    }
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  await Alarm.init();
  runApp(const VertretungsApp());
}

class VertretungsApp extends StatelessWidget {
  const VertretungsApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vertretungsplan Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(surface: _bg, primary: _accent),
        scaffoldBackgroundColor: _bg,
        textTheme: GoogleFonts.spaceGroteskTextTheme()
            .apply(bodyColor: _text, displayColor: _text),
      ),
      home: const HomeScreen(),
    );
  }
}

// ── Home Screen ───────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final _state      = AppState();
  final _urlCtrl    = TextEditingController();
  final _tokenCtrl  = TextEditingController();
  bool _showSettings = false;
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulse = Tween(begin: 0.5, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _state.addListener(() => setState(() {}));
    FlutterForegroundTask.addTaskDataCallback(_state.onTaskData);
    _initService();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_state.onTaskData);
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _initService() async {
    await [
      Permission.notification,
      Permission.scheduleExactAlarm,
    ].request();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId:          'gotify_channel',
        channelName:        'Gotify Hintergrunddienst',
        channelDescription: 'Empfängt und setzt Alarm-Benachrichtigungen',
        onlyAlertOnce:      true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction:    ForegroundTaskEventAction.repeat(120000), // 2 minutes in ms
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
      Expanded(child: _buildHistory()),
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
    final last = _state.history.isEmpty ? null : _state.history.first;
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

  Widget _buildHistory() {
    if (_state.history.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.notifications_none_outlined, color: _muted, size: 40),
        const SizedBox(height: 12),
        Text('Keine Alarme bisher',
          style: GoogleFonts.spaceGrotesk(color: _muted, fontSize: 14)),
        const SizedBox(height: 4),
        Text('Wecker werden automatisch gestellt,\nsobald eine Nachricht eintrifft',
          textAlign: TextAlign.center,
          style: GoogleFonts.spaceGrotesk(color: _muted.withOpacity(0.6), fontSize: 12)),
      ]));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Verlauf', style: GoogleFonts.spaceGrotesk(
        fontSize: 13, color: _muted, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Expanded(child: ListView.separated(
        itemCount: _state.history.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final e = _state.history[i];
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
      )),
    ]);
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
        hint: 'https://push.meinserver.de', icon: Icons.dns_outlined),
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
