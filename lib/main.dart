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
  int fader = 0;                 // -15 (Rear) to +15 (Front)
  bool isSubPhaseInverted = false; // Phase: 0° / 180°
  String hpfCutoff = "Flat";     // HPF: Flat, 80 Hz, 120 Hz, 160 Hz
  bool isBeepEnabled = true;     // Hardware Audio Click
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
    return "${hour12.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} $period";
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
            border: Border.all(color: const Color(0xFF1E2A3A)),
          ),
          title: Text(
            "SELECT $title",
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2),
          ),
          content: SizedBox(
            width: 280,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: swatch.map((c) {
                final isSel = c.value == currentColor.value;
                return GestureDetector(
                  onTap: () {
                    onSelected(c);
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSel ? Colors.white : Colors.black26,
                        width: isSel ? 3.0 : 1.2,
                      ),
                      boxShadow: [
                        if (isSel)
                          BoxShadow(color: c.withOpacity(0.6), blurRadius: 10, spreadRadius: 2)
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  void _showSourceSelectorSheet(BuildContext context, DspWebSocketService dsp) {
    final accent = dsp.activeAccent;
    final rail = dsp.activeRail;

    showModalBottomSheet(
      context: context,
      backgroundColor: dsp.isNightModeActive ? const Color(0xFF060606) : const Color(0xFF0A0F17),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final sources = [
          {"id": "BT", "title": "BLUETOOTH AUDIO", "sub": "Direct Wireless Stream A2DP", "icon": Icons.bluetooth_audio_rounded},
          {"id": "AUX", "title": "AUXILIARY IN", "sub": "Analog Line Input SE2 Direct", "icon": Icons.cable_rounded},
          {"id": "SD_Card", "title": "SD CARD PLAYER", "sub": "Hardware Studio Direct Playback", "icon": Icons.sd_storage_rounded},
        ];

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "SELECT AUDIO INPUT SOURCE",
                    style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                    onPressed: () => Navigator.pop(ctx),
                  )
                ],
              ),
              const SizedBox(height: 12),
              ...sources.map((s) {
                final isSel = dsp.currentSource == s["id"];
                return GestureDetector(
                  onTap: () {
                    dsp.setSource(s["id"] as String);
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: isSel ? accent.withOpacity(0.14) : const Color(0xFF101724),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSel ? accent : rail.withOpacity(0.5),
                        width: isSel ? 1.6 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(s["icon"] as IconData, color: isSel ? accent : const Color(0xFF78909C), size: 22),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s["title"] as String,
                                style: TextStyle(
                                  color: isSel ? accent : Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s["sub"] as String,
                                style: const TextStyle(color: Color(0xFF607D8B), fontSize: 9.5),
                              ),
                            ],
                          ),
                        ),
                        if (isSel) Icon(Icons.check_circle_rounded, color: accent, size: 18),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ],
          ),
        );
      },
    );
  }

  void _showIpDialog(BuildContext context, DspWebSocketService dsp) {
    final controller = TextEditingController(text: dsp.espIp);

    showDialog(
      context: context,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: AlertDialog(
          backgroundColor: const Color(0xFF101622),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: dsp.activeRail),
          ),
          title: const Text(
            "ESP32 IP SETTINGS",
            style: TextStyle(color: Color(0xFF90A4AE), fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.5),
          ),
          content: TextField(
            controller: controller,
            style: TextStyle(color: dsp.activeAccent, fontWeight: FontWeight.bold),
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: "e.g. 192.168.4.1",
              hintStyle: const TextStyle(color: Color(0xFF546E7A)),
              filled: true,
              fillColor: const Color(0xFF0A0E17),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: dsp.activeRail)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: dsp.activeAccent)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("CANCEL", style: TextStyle(color: Color(0xFF78909C))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: dsp.activeAccent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                dsp.updateIp(controller.text);
                Navigator.pop(ctx);
              },
              child: const Text("CONNECT", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettingsSheet(BuildContext context, DspWebSocketService dsp) {
    // Local copy for custom color builder
    Color tempCore = dsp.colorCore;
    Color tempTip = dsp.colorTip;
    Color tempAccent = dsp.colorAccent;
    Color tempRail = dsp.colorRail;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: dsp.isNightModeActive ? const Color(0xFF050505) : const Color(0xFF0B1017),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final accent = dsp.activeAccent;
            final rail = dsp.activeRail;

            final List<Map<String, dynamic>> studioPalettes = [
              {
                "name": "Nordic Sage",
                "core": const Color(0xFF0B2B26),
                "tip": const Color(0xFF8EB69B),
                "accent": const Color(0xFFDAF1DE),
                "rail": const Color(0xFF235347),
              },
              {
                "name": "Cyber Ice Blue",
                "core": const Color(0xFF002244),
                "tip": const Color(0xFF00E5FF),
                "accent": const Color(0xFFE0F7FA),
                "rail": const Color(0xFF005588),
              },
              {
                "name": "Amber Tube",
                "core": const Color(0xFF381A00),
                "tip": const Color(0xFFFFB300),
                "accent": const Color(0xFFFFF3E0),
                "rail": const Color(0xFF6D3900),
              },
              {
                "name": "Stealth Obsidian",
                "core": const Color(0xFF141820),
                "tip": const Color(0xFF94A3B8),
                "accent": const Color(0xFFF8FAFC),
                "rail": const Color(0xFF334155),
              },
              {
                "name": "Deep Crimson",
                "core": const Color(0xFF33080E),
                "tip": const Color(0xFFFF4D6D),
                "accent": const Color(0xFFFFE5EC),
                "rail": const Color(0xFF66101F),
              },
              {
                "name": "Emerald Studio",
                "core": const Color(0xFF062B19),
                "tip": const Color(0xFF10B981),
                "accent": const Color(0xFFD1FAE5),
                "rail": const Color(0xFF0F5A36),
              },
              {
                "name": "Amethyst Violet",
                "core": const Color(0xFF240A34),
                "tip": const Color(0xFFD500F9),
                "accent": const Color(0xFFF3E5F5),
                "rail": const Color(0xFF5E1B7D),
              },
              {
                "name": "Neon Sunset",
                "core": const Color(0xFF331000),
                "tip": const Color(0xFFFF6D00),
                "accent": const Color(0xFFFFE0B2),
                "rail": const Color(0xFF7A2E00),
              },
            ];

            return Container(
              height: MediaQuery.of(context).size.height * 0.92,
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
              child: ListView(
                physics: const BouncingScrollPhysics(),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "STUDIO DSP & HARDWARE CONTROLS",
                        style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      )
                    ],
                  ),
                  const SizedBox(height: 12),

                  // ==========================================
                  // 1. CUSTOM THEME BUILDER & PRESETS
                  // ==========================================
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D14),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: rail),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.palette_rounded, color: accent, size: 18),
                                const SizedBox(width: 8),
                                const Text("THEME SELECTOR & LIVE SYNC", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: accent.withOpacity(0.16),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text("ESP32 SYNC", style: TextStyle(color: accent, fontSize: 8.5, fontWeight: FontWeight.w900)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text("Quick Presets (Display & App):", style: TextStyle(color: Color(0xFF78909C), fontSize: 9.5)),
                        const SizedBox(height: 8),

                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 2.8,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: studioPalettes.length,
                          itemBuilder: (context, i) {
                            final p = studioPalettes[i];
                            final isSel = dsp.colorCore.value == (p["core"] as Color).value &&
                                dsp.colorAccent.value == (p["accent"] as Color).value;

                            return GestureDetector(
                              onTap: () {
                                tempCore = p["core"] as Color;
                                tempTip = p["tip"] as Color;
                                tempAccent = p["accent"] as Color;
                                tempRail = p["rail"] as Color;
                                dsp.applySynchronizedTheme(tempCore, tempTip, tempAccent, tempRail);
                                setModalState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isSel ? (p["accent"] as Color).withOpacity(0.15) : const Color(0xFF101724),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isSel ? (p["accent"] as Color) : const Color(0xFF1E2A3A),
                                    width: isSel ? 1.8 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [p["tip"] as Color, p["core"] as Color],
                                        ),
                                        border: Border.all(color: p["accent"] as Color, width: 1.5),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        p["name"] as String,
                                        style: TextStyle(
                                          color: isSel ? (p["accent"] as Color) : const Color(0xFFB0BEC5),
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                        const Divider(color: Color(0xFF1C2638), height: 1),
                        const SizedBox(height: 12),

                        // Custom Theme Studio Picker
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "CUSTOM THEME STUDIO",
                              style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold, letterSpacing: 1),
                            ),
                            Text("TAP SLOTS TO CHOOSE", style: TextStyle(color: accent, fontSize: 8.5, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 10),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildColorSlot("ACCENT", tempAccent, () {
                              _showColorGridPicker(context, "ACCENT COLOR", tempAccent, (c) {
                                setModalState(() => tempAccent = c);
                              });
                            }),
                            _buildColorSlot("TIP END", tempTip, () {
                              _showColorGridPicker(context, "TIP COLOR", tempTip, (c) {
                                setModalState(() => tempTip = c);
                              });
                            }),
                            _buildColorSlot("CORE GLOW", tempCore, () {
                              _showColorGridPicker(context, "CORE COLOR", tempCore, (c) {
                                setModalState(() => tempCore = c);
                              });
                            }),
                            _buildColorSlot("BORDER RAIL", tempRail, () {
                              _showColorGridPicker(context, "RAIL COLOR", tempRail, (c) {
                                setModalState(() => tempRail = c);
                              });
                            }),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // Apply Custom Theme Button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            dsp.applySynchronizedTheme(tempCore, tempTip, tempAccent, tempRail);
                            setModalState(() {});
                          },
                          child: const Text("APPLY & SYNC TO HARDWARE", style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // ==========================================
                  // 2. HARDWARE AUDIO & ANALYZER TOGGLES
                  // ==========================================
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: rail),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.touch_app_rounded, color: accent, size: 18),
                                const SizedBox(width: 8),
                                const Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("TOUCH AUDIO FEEDBACK", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                    Text("TDA7419 Hardware Click on Tap", style: TextStyle(color: Color(0xFF607D8B), fontSize: 9)),
                                  ],
                                ),
                              ],
                            ),
                            Switch(
                              value: dsp.isBeepEnabled,
                              activeColor: accent,
                              onChanged: (val) {
                                setModalState(() => dsp.isBeepEnabled = val);
                                dsp.sendDspValue("BEEP", val ? 1 : 0);
                              },
                            ),
                          ],
                        ),
                        const Divider(color: Color(0xFF1C2638), height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.equalizer_rounded, color: accent, size: 18),
                                const SizedBox(width: 8),
                                const Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("TRUE RTA SPECTRUM", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                    Text("Pre-Tone Source Tap (Flat RTA)", style: TextStyle(color: Color(0xFF607D8B), fontSize: 9)),
                                  ],
                                ),
                              ],
                            ),
                            Switch(
                              value: dsp.isRtaPreTone,
                              activeColor: accent,
                              onChanged: (val) {
                                setModalState(() => dsp.isRtaPreTone = val);
                                dsp.sendDspValue("RTA", val ? 1 : 0);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // ==========================================
                  // 3. STAGING & BALANCE
                  // ==========================================
                  // Speaker Balance
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("SPEAKER BALANCE (L / R)", style: TextStyle(color: Color(0xFF78909C), fontSize: 11, fontWeight: FontWeight.bold)),
                      Text(
                        dsp.balance == 0 ? "CENTER" : (dsp.balance < 0 ? "L ${dsp.balance.abs()}" : "R ${dsp.balance}"),
                        style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Slider(
                    value: dsp.balance.toDouble(),
                    min: -15,
                    max: 15,
                    divisions: 30,
                    activeColor: accent,
                    inactiveColor: const Color(0xFF1E283B),
                    onChanged: (v) => setModalState(() => dsp.balance = v.toInt()),
                    onChangeEnd: (v) => dsp.sendDspValue("BAL", v.toInt()),
                  ),

                  // Front / Rear Fader
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("FRONT / REAR FADER (F / R)", style: TextStyle(color: Color(0xFF78909C), fontSize: 11, fontWeight: FontWeight.bold)),
                      Text(
                        dsp.fader == 0 ? "CENTER" : (dsp.fader > 0 ? "FRONT +${dsp.fader}" : "REAR +${dsp.fader.abs()}"),
                        style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Slider(
                    value: dsp.fader.toDouble(),
                    min: -15,
                    max: 15,
                    divisions: 30,
                    activeColor: accent,
                    inactiveColor: const Color(0xFF1E283B),
                    onChanged: (v) => setModalState(() => dsp.fader = v.toInt()),
                    onChangeEnd: (v) => dsp.sendDspValue("FAD", v.toInt()),
                  ),
                  const SizedBox(height: 6),

                  // ==========================================
                  // 4. GAIN & LOUDNESS
                  // ==========================================
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("INPUT PRE-AMP GAIN", style: TextStyle(color: Color(0xFF78909C), fontSize: 11, fontWeight: FontWeight.bold)),
                      Text("+${dsp.gain} dB", style: TextStyle(color: accent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: dsp.gain.toDouble(),
                    min: 0,
                    max: 15,
                    divisions: 15,
                    activeColor: accent,
                    inactiveColor: const Color(0xFF1E283B),
                    onChanged: (v) => setModalState(() => dsp.gain = v.toInt()),
                    onChangeEnd: (v) => dsp.sendDspValue("GAIN", v.toInt()),
                  ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("LOUDNESS ATTENUATION", style: TextStyle(color: Color(0xFF78909C), fontSize: 11, fontWeight: FontWeight.bold)),
                      Text("LVL ${dsp.loudness}", style: TextStyle(color: accent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: dsp.loudness.toDouble(),
                    min: 0,
                    max: 15,
                    divisions: 15,
                    activeColor: accent,
                    inactiveColor: const Color(0xFF1E283B),
                    onChanged: (v) => setModalState(() => dsp.loudness = v.toInt()),
                    onChangeEnd: (v) => dsp.sendDspValue("LOUD", v.toInt()),
                  ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("LOUDNESS CENTER FREQ", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          const Text("HI-BOOST", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold)),
                          Switch(
                            value: dsp.isLoudnessHighBoost,
                            activeColor: accent,
                            onChanged: (val) {
                              setModalState(() => dsp.isLoudnessHighBoost = val);
                              dsp.sendDspValue("LDHB", val ? 1 : 0);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  _buildOptionRow(["400 Hz", "800 Hz", "2.4 kHz"], dsp.loudnessFreq, accent, (opt) {
                    setModalState(() => dsp.loudnessFreq = opt);
                    dsp.sendDspValue("LDF", opt);
                  }),
                  const Divider(color: Color(0xFF1C2638), height: 24),

                  // ==========================================
                  // 5. CROSSOVERS & SUB PHASE
                  // ==========================================
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("SUBWOOFER PHASE INVERSION", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                      Row(
                        children: [
                          Text(dsp.isSubPhaseInverted ? "180° INVERTED" : "0° NORMAL", style: TextStyle(color: accent, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(width: 4),
                          Switch(
                            value: dsp.isSubPhaseInverted,
                            activeColor: accent,
                            onChanged: (val) {
                              setModalState(() => dsp.isSubPhaseInverted = val);
                              dsp.sendDspValue("PHASE", val ? 1 : 0);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  const Text("SUBWOOFER CUTOFF (LPF)", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  _buildOptionRow(["Flat", "80 Hz", "120 Hz", "160 Hz"], dsp.subCutoff, accent, (opt) {
                    setModalState(() => dsp.subCutoff = opt);
                    dsp.sendDspValue("SUBCUT", opt);
                  }),
                  const SizedBox(height: 14),

                  const Text("SATELLITE HIGH-PASS (HPF)", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  _buildOptionRow(["Flat", "80 Hz", "120 Hz", "160 Hz"], dsp.hpfCutoff, accent, (opt) {
                    setModalState(() => dsp.hpfCutoff = opt);
                    dsp.sendDspValue("HPF", opt);
                  }),
                  const SizedBox(height: 14),

                  // Bass Center & Q
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("BASS CENTER FREQUENCY", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                      Row(
                        children: [
                          const Text("DC MODE (SHELVING)", style: TextStyle(color: Color(0xFF78909C), fontSize: 9, fontWeight: FontWeight.bold)),
                          Switch(
                            value: dsp.isBassDcMode,
                            activeColor: accent,
                            onChanged: (val) {
                              setModalState(() => dsp.isBassDcMode = val);
                              dsp.sendDspValue("BDC", val ? 1 : 0);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _buildOptionRow(["60 Hz", "80 Hz", "100 Hz", "200 Hz"], dsp.bassCenter, accent, (opt) {
                    setModalState(() => dsp.bassCenter = opt);
                    dsp.sendDspValue("BCTR", opt);
                  }),
                  const SizedBox(height: 10),

                  const Text("BASS QUALITY FACTOR (Q)", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  _buildOptionRow(["1.0", "1.25", "1.5", "2.0"], dsp.bassQ, accent, (opt) {
                    setModalState(() => dsp.bassQ = opt);
                    dsp.sendDspValue("BQ", opt);
                  }),
                  const SizedBox(height: 14),

                  // Middle Center & Q
                  const Text("MIDDLE CENTER FREQUENCY", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  _buildOptionRow(["500 Hz", "1.0 kHz", "1.5 kHz", "2.5 kHz"], dsp.midCenter, accent, (opt) {
                    setModalState(() => dsp.midCenter = opt);
                    dsp.sendDspValue("MIDF", opt);
                  }),
                  const SizedBox(height: 10),

                  const Text("MIDDLE QUALITY FACTOR (Q)", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  _buildOptionRow(["0.5", "0.75", "1.0", "1.25"], dsp.midQ, accent, (opt) {
                    setModalState(() => dsp.midQ = opt);
                    dsp.sendDspValue("MIDQ", opt);
                  }),
                  const SizedBox(height: 14),

                  // Treble Cut
                  const Text("TREBLE CENTER FREQUENCY", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  _buildOptionRow(["10.0 kHz", "12.5 kHz", "15.0 kHz", "17.5 kHz"], dsp.trebleCut, accent, (opt) {
                    setModalState(() => dsp.trebleCut = opt);
                    dsp.sendDspValue("TRECUT", opt);
                  }),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildColorSlot(String label, Color c, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(color: c.withOpacity(0.5), blurRadius: 8, offset: const Offset(0, 2)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Color(0xFF78909C), fontSize: 8.5, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildOptionRow(List<String> options, String selected, Color accent, ValueChanged<String> onSelect) {
    return Row(
      children: options.map((opt) {
        final isSel = selected == opt;
        return Expanded(
          child: GestureDetector(
            onTap: () => onSelect(opt),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isSel ? accent.withOpacity(0.18) : const Color(0xFF121824),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSel ? accent : const Color(0xFF1C2638),
                  width: isSel ? 1.4 : 1.0,
                ),
              ),
              child: Center(
                child: Text(
                  opt,
                  style: TextStyle(
                    color: isSel ? accent : const Color(0xFF90A4AE),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dsp = context.watch<DspWebSocketService>();
    final accent = dsp.activeAccent;
    final rail = dsp.activeRail;
    final curSub = localSub ?? dsp.subVolume;
    final curBass = localBass ?? dsp.bass;
    final curMid = localMid ?? dsp.mid;
    final curTreble = localTreble ?? dsp.treble;

    return Scaffold(
      backgroundColor: dsp.activeBackground,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: () => _showIpDialog(context, dsp),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: dsp.isConnected ? const Color(0xFF00E676) : Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "NV STUDIO [${dsp.espIp}]",
                          style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5),
                        ),
                        if (dsp.isNightModeActive) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.nightlight_round, color: Color(0xFF7A6843), size: 12),
                        ],
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => _showSettingsSheet(context, dsp),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF141C2B),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: rail),
                          ),
                          child: Icon(Icons.tune, color: accent, size: 16),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => _showSourceSelectorSheet(context, dsp),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF141C2B),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: rail),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                dsp.currentSource == "BT" 
                                    ? Icons.bluetooth_rounded 
                                    : (dsp.currentSource == "AUX" ? Icons.cable_rounded : Icons.sd_storage_rounded),
                                color: accent,
                                size: 13,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                dsp.currentSource,
                                style: TextStyle(color: accent, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 2),
                              Icon(Icons.arrow_drop_down, color: accent, size: 14),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                ],
              ),
            ),

            // Main Controls Rack
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 1. Master Volume Card
                      SizedBox(
                        width: double.infinity,
                        child: _glassCard(
                          cardColor: dsp.activeCardBg,
                          borderColor: rail,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text(
                                "MASTER OUTPUT GAIN",
                                style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                              ),
                              const SizedBox(height: 4),
                              RotaryDial(
                                size: 140,
                                value: dsp.volume,
                                accentColor: accent,
                                isNightMode: dsp.isNightModeActive,
                                onChanged: (_) {},
                                onChangeEnd: (v) => dsp.setVolume(v),
                              ),
                              const SizedBox(height: 10),

                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _stepButton(
                                    icon: Icons.remove,
                                    accent: accent,
                                    borderColor: rail,
                                    onTap: () => dsp.adjustVolume(-1),
                                  ),
                                  const SizedBox(width: 14),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF090D14),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: rail),
                                    ),
                                    child: Text(
                                      "STEP ${dsp.volume} / 29",
                                      style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  _stepButton(
                                    icon: Icons.add,
                                    accent: accent,
                                    borderColor: rail,
                                    onTap: () => dsp.adjustVolume(1),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 2. Subwoofer & Sleep Timer Rack
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _glassCard(
                                cardColor: dsp.activeCardBg,
                                borderColor: rail,
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text("SUBWOOFER", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold)),
                                        const SizedBox(height: 2),
                                        Text("$curSub", style: TextStyle(color: accent, fontSize: 19, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                    _InPlacePopHorizontalSlider(
                                      value: curSub.toDouble(),
                                      min: 0,
                                      max: 29,
                                      divisions: 29,
                                      accentColor: accent,
                                      onChanged: (v) => setState(() => localSub = v.toInt()),
                                      onChangeEnd: (v) {
                                        dsp.setSubVolume(v.toInt());
                                        setState(() => localSub = null);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),

                            Expanded(
                              child: _glassCard(
                                cardColor: dsp.activeCardBg,
                                borderColor: rail,
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text("SLEEP TIMER", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold)),
                                        Text(
                                          _formatTime(dsp.sleepRemainingSec),
                                          style: TextStyle(
                                            color: dsp.sleepRemainingSec > 0 ? accent : const Color(0xFF546E7A),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 5,
                                      runSpacing: 5,
                                      children: ["OFF", "15m", "30m", "60m"].map((t) {
                                        final isSel = (t == "OFF" && dsp.sleepRemainingSec <= 0) || (dsp.sleepTimer == t && dsp.sleepRemainingSec > 0);
                                        return GestureDetector(
                                          onTap: () => dsp.sendDspValue("SLP", t),
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 200),
                                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: isSel ? accent.withOpacity(0.18) : const Color(0xFF121824),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(
                                                color: isSel ? accent : rail.withOpacity(0.6),
                                                width: isSel ? 1.4 : 1.0,
                                              ),
                                            ),
                                            child: Text(
                                              t,
                                              style: TextStyle(
                                                color: isSel ? accent : const Color(0xFF78909C),
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 3. Parametric EQ Card
                      SizedBox(
                        width: double.infinity,
                        child: _glassCard(
                          cardColor: dsp.activeCardBg,
                          borderColor: rail,
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(() => isEqExpanded = !isEqExpanded),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(
                                          isEqExpanded ? Icons.lock_open : Icons.lock_outline,
                                          color: isEqExpanded ? accent : const Color(0xFF607D8B),
                                          size: 14,
                                        ),
                                        const SizedBox(width: 8),
                                        const Text(
                                          "PARAMETRIC EQUALIZER",
                                          style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                                        ),
                                      ],
                                    ),
                                    Icon(
                                      isEqExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                      color: accent,
                                      size: 18,
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 8),
                              Container(
                                height: 60,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0A0E17),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: rail.withOpacity(0.5)),
                                ),
                                child: CustomPaint(
                                  painter: _EqCurvePainter(bass: curBass, mid: curMid, treble: curTreble, accent: accent),
                                ),
                              ),

                              AnimatedCrossFade(
                                duration: const Duration(milliseconds: 250),
                                crossFadeState: isEqExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                                firstChild: const SizedBox(width: double.infinity),
                                secondChild: Padding(
                                  padding: const EdgeInsets.only(top: 12.0),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                                    children: [
                                      _StudioVerticalFader(
                                        title: "BASS",
                                        freq: dsp.bassCenter,
                                        val: curBass,
                                        accentColor: accent,
                                        onDrag: (v) => setState(() => localBass = v),
                                        onEnd: (v) {
                                          dsp.setBass(v);
                                          setState(() => localBass = null);
                                        },
                                      ),
                                      _StudioVerticalFader(
                                        title: "MID",
                                        freq: dsp.midCenter,
                                        val: curMid,
                                        accentColor: accent,
                                        onDrag: (v) => setState(() => localMid = v),
                                        onEnd: (v) {
                                          dsp.setMid(v);
                                          setState(() => localMid = null);
                                        },
                                      ),
                                      _StudioVerticalFader(
                                        title: "TREBLE",
                                        freq: dsp.trebleCut,
                                        val: curTreble,
                                        accentColor: accent,
                                        onDrag: (v) => setState(() => localTreble = v),
                                        onEnd: (v) {
                                          dsp.setTreble(v);
                                          setState(() => localTreble = null);
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Bottom Cyber Command Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF090D15),
                border: Border(top: BorderSide(color: rail, width: 1.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.terminal, color: accent, size: 18),
                  const SizedBox(
