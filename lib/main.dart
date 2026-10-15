import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ==========================================
// 1. WEBSOCKET & DYNAMIC DSP SERVICE
// ==========================================
class DspWebSocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  bool isConnected = false;
  String espIp = "192.168.4.1";

  // Dynamic Theme Colors (Synchronized with ST7789 Display)
  Color colorCore = const Color(0xFF0B2B26);   
  Color colorTip = const Color(0xFF8EB69B);    
  Color colorAccent = const Color(0xFFDAF1DE); 
  Color colorRail = const Color(0xFF235347);   

  bool isNightModeManual = false;
  bool isNightScheduleEnabled = false;
  int nightStartHour = 22;
  int nightStartMinute = 0;
  int nightEndHour = 6;
  int nightEndMinute = 0;
  Timer? _scheduleCheckerTimer;

  bool get isNightModeActive {
    if (isNightScheduleEnabled) {
      final now = DateTime.now();
      final currentMinutes = now.hour * 60 + now.minute;
      final startMinutes = nightStartHour * 60 + nightStartMinute;
      final endMinutes = nightEndHour * 60 + nightEndMinute;

      if (startMinutes <= endMinutes) {
        return currentMinutes >= startMinutes && currentMinutes < endMinutes;
      } else {
        return currentMinutes >= startMinutes || currentMinutes < endMinutes;
      }
    }
    return isNightModeManual;
  }

  Color get activeAccent => isNightModeActive ? const Color(0xFF7A6843) : colorAccent;
  Color get activeBackground => isNightModeActive ? const Color(0xFF000000) : const Color(0xFF04070B);
  Color get activeCardBg => isNightModeActive 
      ? const Color(0xFF080808) 
      : Color.alphaBlend(colorCore.withOpacity(0.35), const Color(0xFF0C111A));
  Color get activeRail => isNightModeActive ? const Color(0xFF2B2418) : colorRail;

  // Audio Core States
  int volume = 4;
  int subVolume = 12;
  int bass = 0;
  int mid = 0;
  int treble = 4;
  int balance = 0;
  int fader = 0;                 // Fader: -15 (Rear) to +15 (Front)
  bool isSubPhaseInverted = false; // Phase: 0° / 180°
  String hpfCutoff = "Flat";     // HPF: Flat, 80 Hz, 120 Hz, 160 Hz
  bool isBeepEnabled = true;     // Hardware Audio Click Feedback
  bool isRtaPreTone = true;      // Pre-Tone True RTA Mode

  String currentSource = "BT"; 
  String sleepTimer = "OFF";
  int sleepRemainingSec = 0;
  Timer? _localCountDownTimer;

  // Filter & Hardware States
  int gain = 0;
  int loudness = 0;
  String loudnessFreq = "400 Hz";
  bool isLoudnessHighBoost = false;

  String subCutoff = "80 Hz";
  String bassCenter = "60 Hz";
  String bassQ = "1.25";
  bool isBassDcMode = false;

  String midCenter = "1.0 kHz";
  String midQ = "1.0";
  String trebleCut = "12.5 kHz";

  void setVolume(int val) {
    final target = val.clamp(0, 29);
    volume = target;
    notifyListeners();
    sendDspValue("VOL", volume);
  }

  void setSubVolume(int val) {
    final target = val.clamp(0, 29);
    subVolume = target;
    notifyListeners();
    sendDspValue("SUB", subVolume);
  }

  void setBass(int val) {
    final target = val.clamp(-15, 15);
    bass = target;
    notifyListeners();
    sendDspValue("BAS", bass);
  }

  void setMid(int val) {
    final target = val.clamp(-15, 15);
    mid = target;
    notifyListeners();
    sendDspValue("MID", mid);
  }

  void setTreble(int val) {
    final target = val.clamp(-15, 15);
    treble = target;
    notifyListeners();
    sendDspValue("TRE", treble);
  }

  static Color _hexToColor(String hex) {
    hex = hex.replaceAll("#", "").trim();
    if (hex.length == 6) hex = "FF$hex";
    return Color(int.tryParse(hex, radix: 16) ?? 0xFF00F2FE);
  }

  static String _colorToHex(Color c) {
    return c.value.toRadixString(16).substring(2).toUpperCase();
  }

  Future<void> initIpAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    espIp = prefs.getString('saved_esp_ip') ?? "192.168.4.1";

    final cCoreVal = prefs.getInt('saved_clr_core');
    final cTipVal = prefs.getInt('saved_clr_tip');
    final cAccVal = prefs.getInt('saved_clr_acc');
    final cRailVal = prefs.getInt('saved_clr_rail');

    if (cCoreVal != null) colorCore = Color(cCoreVal);
    if (cTipVal != null) colorTip = Color(cTipVal);
    if (cAccVal != null) colorAccent = Color(cAccVal);
    if (cRailVal != null) colorRail = Color(cRailVal);

    isNightModeManual = prefs.getBool('night_manual') ?? false;
    isNightScheduleEnabled = prefs.getBool('night_sched_enabled') ?? false;
    nightStartHour = prefs.getInt('night_start_h') ?? 22;
    nightStartMinute = prefs.getInt('night_start_m') ?? 0;
    nightEndHour = prefs.getInt('night_end_h') ?? 6;
    nightEndMinute = prefs.getInt('night_end_m') ?? 0;

    _startScheduleChecker();
    connect(espIp);
  }

  void _startScheduleChecker() {
    _scheduleCheckerTimer?.cancel();
    _scheduleCheckerTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (isNightScheduleEnabled) notifyListeners();
    });
  }

  Future<void> updateIp(String newIp) async {
    if (newIp.trim().isEmpty) return;
    espIp = newIp.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_esp_ip', espIp);
    _channel?.sink.close();
    connect(espIp);
  }

  Future<void> applySynchronizedTheme(Color core, Color tip, Color accent, Color rail) async {
    colorCore = core;
    colorTip = tip;
    colorAccent = accent;
    colorRail = rail;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('saved_clr_core', core.value);
    await prefs.setInt('saved_clr_tip', tip.value);
    await prefs.setInt('saved_clr_acc', accent.value);
    await prefs.setInt('saved_clr_rail', rail.value);

    final cmd = "CLR:${_colorToHex(core)},${_colorToHex(tip)},${_colorToHex(accent)},${_colorToHex(rail)}";
    sendCommand(cmd);
  }

  Future<void> setNightModeManual(bool val) async {
    isNightModeManual = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('night_manual', val);
  }

  Future<void> setNightSchedule(bool enabled, int startH, int startM, int endH, int endM) async {
    isNightScheduleEnabled = enabled;
    nightStartHour = startH;
    nightStartMinute = startM;
    nightEndHour = endH;
    nightEndMinute = endM;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('night_sched_enabled', enabled);
    await prefs.setInt('night_start_h', startH);
    await prefs.setInt('night_start_m', startM);
    await prefs.setInt('night_end_h', endH);
    await prefs.setInt('night_end_m', endM);
  }

  void connect(String ip) {
    espIp = ip.trim();
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://$espIp/ws'));
      isConnected = true;
      notifyListeners();

      _channel!.stream.listen(
        (data) => _parseSync(data.toString()),
        onDone: () {
          isConnected = false;
          notifyListeners();
          _reconnect();
        },
        onError: (_) {
          isConnected = false;
          notifyListeners();
          _reconnect();
        },
      );
      sendCommand("REQ_SYNC");
    } catch (_) {
      isConnected = false;
      notifyListeners();
    }
  }

  void _reconnect() {
    Timer(const Duration(seconds: 3), () {
      if (!isConnected) connect(espIp);
    });
  }

  void sendCommand(String cmd) {
    if (isConnected && _channel != null) {
      _channel!.sink.add(cmd);
    }
  }

  void sendDspValue(String key, dynamic value) {
    sendCommand("$key:$value");
  }

  void setSource(String sourceName) {
    currentSource = sourceName;
    notifyListeners();
    sendDspValue("INP", sourceName);
  }

  void adjustVolume(int delta) {
    final target = (volume + delta).clamp(0, 29);
    if (target != volume) {
      setVolume(target);
    }
  }

  void dispatchTextCommand(String text) {
    final clean = text.trim().toLowerCase();
    final match = RegExp(r'(set\s+)?vol(ume)?\s+(\d+)').firstMatch(clean);

    if (match != null) {
      final target = int.tryParse(match.group(3) ?? "")?.clamp(0, 29);
      if (target != null) {
        setVolume(target);
        return;
      }
    }

    if (clean.contains("mute")) {
      setVolume(0);
      return;
    }

    sendCommand(text.trim());
  }

  void _startLocalCountdown() {
    _localCountDownTimer?.cancel();
    if (sleepRemainingSec > 0) {
      _localCountDownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (sleepRemainingSec > 0) {
          sleepRemainingSec--;
          notifyListeners();
        } else {
          sleepTimer = "OFF";
          timer.cancel();
          notifyListeners();
        }
      });
    }
  }

  void _parseSync(String payload) {
    if (!payload.startsWith("SYNC:")) return;
    final clean = payload.replaceFirst("SYNC:", "");
    final tokens = clean.split(";");

    for (var token in tokens) {
      final parts = token.split("=");
      if (parts.length != 2) continue;
      final k = parts[0];
      final v = parts[1];

      switch (k) {
        case "VOL": volume = int.tryParse(v) ?? volume; break;
        case "SUB": subVolume = int.tryParse(v) ?? subVolume; break;
        case "BAS": bass = int.tryParse(v) ?? bass; break;
        case "MID": mid = int.tryParse(v) ?? mid; break;
        case "TRE": treble = int.tryParse(v) ?? treble; break;
        case "BAL": balance = int.tryParse(v) ?? balance; break;
        case "FAD": fader = int.tryParse(v) ?? fader; break;
        case "PHASE": isSubPhaseInverted = (v == "1" || v.toLowerCase() == "true"); break;
        case "HPF": hpfCutoff = v; break;
        case "BEEP": isBeepEnabled = (v == "1" || v.toLowerCase() == "true"); break;
        case "RTA": isRtaPreTone = (v == "1" || v.toLowerCase() == "true"); break;
        case "GAIN": gain = int.tryParse(v) ?? gain; break;
        case "LOUD": loudness = int.tryParse(v) ?? loudness; break;
        case "LDF": loudnessFreq = v; break;
        case "LDHB": isLoudnessHighBoost = (v == "1" || v.toLowerCase() == "true"); break;
        case "SUBCUT": subCutoff = v; break;
        case "BCTR": bassCenter = v; break;
        case "BQ": bassQ = v; break;
        case "BDC": isBassDcMode = (v == "1" || v.toLowerCase() == "true"); break;
        case "MIDF": midCenter = v; break;
        case "MIDQ": midQ = v; break;
        case "TRECUT": trebleCut = v; break;
        case "INP": currentSource = v; break;
        case "SLP": sleepTimer = v; break;
        case "SLP_SEC": 
          sleepRemainingSec = int.tryParse(v) ?? 0;
          _startLocalCountdown();
          break;
        case "CLR_CORE": colorCore = _hexToColor(v); break;
        case "CLR_TIP": colorTip = _hexToColor(v); break;
        case "CLR_ACC": colorAccent = _hexToColor(v); break;
        case "CLR_RAIL": colorRail = _hexToColor(v); break;
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _scheduleCheckerTimer?.cancel();
    _localCountDownTimer?.cancel();
    super.dispose();
  }
}

// ==========================================
// 2. MAIN ENTRY POINT
// ==========================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DspWebSocketService()..initIpAndConnect()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dsp = context.watch<DspWebSocketService>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NV Studio DSP',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: dsp.activeBackground,
      ),
      home: const StudioScreen(),
    );
  }
}

// ==========================================
// 3. STUDIO UI SCREEN
// ==========================================
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  int? localSub;
  int? localBass;
  int? localMid;
  int? localTreble;
  bool isEqExpanded = false;
  final TextEditingController _commandController = TextEditingController();

  String _formatTime(int totalSeconds) {
    if (totalSeconds <= 0) return "OFF";
    int m = totalSeconds ~/ 60;
    int s = totalSeconds % 60;
    return "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  String _formatTimeOfDay(int h, int m) {
    final period = h >= 12 ? "PM" : "AM";
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return "${hour12.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}$period";
  }

  void _showColorGridPicker(BuildContext context, String title, Color currentColor, ValueChanged<Color> onSelected) {
    final List<Color> swatch = [
      const Color(0xFF00E5FF), const Color(0xFF00B0FF), const Color(0xFF2979FF),
      const Color(0xFF1DE9B6), const Color(0xFF00E676), const Color(0xFF76FF03),
      const Color(0xFFFFD600), const Color(0xFFFF9100), const Color(0xFFFF3D00),
      const Color(0xFFFF1744), const Color(0xFFF50057), const Color(0xFFD500F9),
      const Color(0xFF651FFF), const Color(0xFF8EB69B), const Color(0xFFDAF1DE),
      const Color(0xFFB0BEC5), const Color(0xFFFFFFFF), const Color(0xFF37474F),
      const Color(0xFF263238), const Color(0xFF102027), const Color(0xFF0B2B26),
    ];

    showDialog(
      context: context,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: AlertDialog(
          backgroundColor: const Color(0xFF0D1420),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color
