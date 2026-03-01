import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:permission_handler/permission_handler.dart';

// ── Colors ────────────────────────────────────────────────────────────────────
const _bg     = Color(0xFF0D0F14);
const _bg2    = Color(0xFF151820);
const _bg3    = Color(0xFF1C2030);
const _border = Color(0xFF252A3A);
const _accent = Color(0xFF22D1A5);
const _accentDim = Color(0x1A22D1A5);
const _red    = Color(0xFFF43F5E);
const _redDim = Color(0x1AF43F5E);
const _text   = Color(0xFFE2E8F0);
const _muted  = Color(0xFF64748B);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Permission.scheduleExactAlarm.request();
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
        colorScheme: const ColorScheme.dark(
          surface: _bg,
          primary: _accent,
        ),
        scaffoldBackgroundColor: _bg,
        textTheme: GoogleFonts.spaceGroteskTextTheme().apply(
          bodyColor: _text,
          displayColor: _text,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ── Alarm Platform Channel ─────────────────────────────────────────────────────
class AlarmService {
  static const _channel = MethodChannel('com.nefnief.vertretungsplan/alarm');

  static Future<void> setAlarm(int hour, int minute, String label) async {
    await _channel.invokeMethod('setAlarm', {
      'hour':   hour,
      'minute': minute,
      'label':  label,
    });
  }
}

// ── Gotify WebSocket Service ───────────────────────────────────────────────────
class AlarmEntry {
  final String time;
  final String label;
  final DateTime setAt;
  AlarmEntry({required this.time, required this.label, required this.setAt});
}

class GotifyService extends ChangeNotifier {
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _connected = false;
  String _statusMsg = 'Nicht verbunden';
  final List<AlarmEntry> history = [];
  static final _alarmRx = RegExp(r'⏰ Wecker: (\d{2}):(\d{2})');

  bool get connected => _connected;
  String get statusMsg => _statusMsg;

  void connect(String serverUrl, String token) {
    _channel?.sink.close();
    _reconnectTimer?.cancel();

    final wsUrl = serverUrl
        .replaceFirst(RegExp(r'^http'), 'ws')
        .replaceAll(RegExp(r'/$'), '');

    try {
      _channel = WebSocketChannel.connect(
        Uri.parse('$wsUrl/stream?token=$token'),
      );
      _channel!.stream.listen(
        _onMessage,
        onError: (_) => _scheduleReconnect(serverUrl, token),
        onDone: ()  => _scheduleReconnect(serverUrl, token),
      );
      _connected = true;
      _statusMsg = 'Verbunden — warte auf Nachrichten…';
      notifyListeners();
    } catch (e) {
      _connected = false;
      _statusMsg = 'Verbindungsfehler: $e';
      notifyListeners();
      _scheduleReconnect(serverUrl, token);
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _connected = false;
    _statusMsg = 'Nicht verbunden';
    notifyListeners();
  }

  void _scheduleReconnect(String url, String token) {
    _connected = false;
    _statusMsg = 'Verbindung getrennt — verbinde neu…';
    notifyListeners();
    _reconnectTimer = Timer(const Duration(seconds: 10), () => connect(url, token));
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String);
      final title = (msg['title'] as String?) ?? '';
      final match = _alarmRx.firstMatch(title);
      if (match == null) return;

      final hour   = int.parse(match.group(1)!);
      final minute = int.parse(match.group(2)!);
      final time   = '${match.group(1)}:${match.group(2)}';
      final label  = (msg['message'] as String?)
          ?.split('\n')
          .skip(1)
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'Schule') ?? 'Schule';

      AlarmService.setAlarm(hour, minute, 'Schule');
      history.insert(0, AlarmEntry(time: time, label: label, setAt: DateTime.now()));
      if (history.length > 20) history.removeLast();
      _statusMsg = 'Wecker gestellt: $time Uhr';
      notifyListeners();
    } catch (_) {}
  }
}

// ── Home Screen ───────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final _gotify = GotifyService();
  final _urlCtrl    = TextEditingController();
  final _tokenCtrl  = TextEditingController();
  bool _showSettings = false;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulse = Tween(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _gotify.addListener(() => setState(() {}));
    _loadAndConnect();
  }

  Future<void> _loadAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final url   = prefs.getString('gotify_url')   ?? '';
    final token = prefs.getString('gotify_token')  ?? '';
    _urlCtrl.text   = url;
    _tokenCtrl.text = token;
    if (url.isNotEmpty && token.isNotEmpty) {
      _gotify.connect(url, token);
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gotify_url',   _urlCtrl.text.trim());
    await prefs.setString('gotify_token', _tokenCtrl.text.trim());
    _gotify.connect(_urlCtrl.text.trim(), _tokenCtrl.text.trim());
    setState(() => _showSettings = false);
  }

  @override
  void dispose() {
    _gotify.disconnect();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _showSettings ? _buildSettings() : _buildHome(),
        ),
      ),
    );
  }

  Widget _buildHome() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          _buildStatusCard(),
          const SizedBox(height: 16),
          _buildNextAlarm(),
          const SizedBox(height: 16),
          Expanded(child: _buildHistory()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Vertretungsplan',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 22, fontWeight: FontWeight.w700, color: _text)),
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
      ],
    );
  }

  Widget _buildStatusCard() {
    final connected = _gotify.connected;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: connected ? _accentDim : _redDim,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: connected ? _accent.withOpacity(0.3) : _red.withOpacity(0.3)),
      ),
      child: Row(children: [
        AnimatedBuilder(
          animation: _pulse,
          builder: (_, __) => Opacity(
            opacity: connected ? _pulse.value : 1.0,
            child: Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected ? _accent : _red,
                boxShadow: [BoxShadow(
                  color: (connected ? _accent : _red).withOpacity(0.5),
                  blurRadius: 8 * (connected ? _pulse.value : 1.0),
                )],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(_gotify.statusMsg,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 12,
              color: connected ? _accent : _red,
            )),
        ),
      ]),
    );
  }

  Widget _buildNextAlarm() {
    final last = _gotify.history.isEmpty ? null : _gotify.history.first;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Row(children: [
        Text('⏰', style: const TextStyle(fontSize: 32)),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(last != null ? '${last.time} Uhr' : '– – : – –',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 36, fontWeight: FontWeight.w800,
              color: last != null ? _text : _muted,
              letterSpacing: -1)),
          Text(last != null ? 'Letzter Wecker gestellt' : 'Noch kein Wecker empfangen',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, color: _muted)),
        ]),
      ]),
    );
  }

  Widget _buildHistory() {
    if (_gotify.history.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.notifications_none_outlined, color: _muted, size: 40),
          const SizedBox(height: 12),
          Text('Keine Alarme bisher',
            style: GoogleFonts.spaceGrotesk(color: _muted, fontSize: 14)),
          const SizedBox(height: 4),
          Text('Wecker werden automatisch gestellt,\nsobald eine Nachricht eintrifft',
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(color: _muted.withOpacity(0.6), fontSize: 12)),
        ]),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Verlauf', style: GoogleFonts.spaceGrotesk(
          fontSize: 13, color: _muted, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: _gotify.history.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final e = _gotify.history[i];
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _bg2, borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _border)),
                child: Row(children: [
                  Text('⏰', style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.time,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 16, fontWeight: FontWeight.w600, color: _accent)),
                      Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.spaceGrotesk(fontSize: 12, color: _muted)),
                    ],
                  )),
                  Text(
                    '${e.setAt.hour.toString().padLeft(2,'0')}:${e.setAt.minute.toString().padLeft(2,'0')}',
                    style: GoogleFonts.jetBrainsMono(fontSize: 11, color: _muted)),
                ]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSettings() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            GestureDetector(
              onTap: () => setState(() => _showSettings = false),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _bg3, borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _border)),
                child: const Icon(Icons.arrow_back, color: _text, size: 18),
              ),
            ),
            const SizedBox(width: 14),
            Text('Einstellungen',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 20, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 32),
          _field('Gotify Server URL', _urlCtrl,
            hint: 'https://push.meinserver.de',
            icon: Icons.dns_outlined),
          const SizedBox(height: 16),
          _field('App Token', _tokenCtrl,
            hint: '••••••••••••••••',
            icon: Icons.vpn_key_outlined, obscure: true),
          const SizedBox(height: 12),
          Text(
            'Den Token findest du in der Gotify Web-UI unter Apps → dein App → Token',
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
                style: GoogleFonts.spaceGrotesk(
                  fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl,
      {String hint = '', IconData? icon, bool obscure = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
        style: GoogleFonts.spaceGrotesk(fontSize: 13, color: _muted, fontWeight: FontWeight.w500)),
      const SizedBox(height: 6),
      TextField(
        controller: ctrl,
        obscureText: obscure,
        style: GoogleFonts.jetBrainsMono(fontSize: 14, color: _text),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.jetBrainsMono(color: _muted.withOpacity(0.5)),
          prefixIcon: icon != null ? Icon(icon, color: _muted, size: 18) : null,
          filled: true,
          fillColor: _bg3,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _border)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _border)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _accent)),
        ),
      ),
    ]);
  }
}
