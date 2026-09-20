import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ==========================================
// 1. WEBSOCKET & DSP SERVICE
// ==========================================
class DspWebSocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  bool isConnected = false;
  String espIp = "192.168.4.1";

  Color neonAccent = const Color(0xFF00F2FE);

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

  Color get activeAccent => isNightModeActive ? const Color(0xFF7A6843) : neonAccent;
  Color get activeBackground => isNightModeActive ? const Color(0xFF000000) : const Color(0xFF070A0F);
  Color get activeCardBg => isNightModeActive ? const Color(0xFF080808) : const Color(0xFF101622);

  static const List<Color> availableThemes = [
    Color(0xFF00F2FE),
    Color(0xFF00E676),
    Color(0xFFFFB300),
    Color(0xFFFF007F),
    Color(0xFFD500F9),
    Color(0xFFFF3D00),
  ];

  // Core Audio States
  int volume = 4;
  int subVolume = 20;
  int bass = 0;
  int mid = 0;
  int treble = 4;
  int balance = 0; // -15 (Left) to +15 (Right)
  String currentSource = "BT AUDIO";
  String sleepTimer = "OFF";
  int sleepRemainingSec = 0;
  Timer? _localCountDownTimer;

  // Filter & Hardware Tuning States
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

  Future<void> initIpAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    espIp = prefs.getString('saved_esp_ip') ?? "192.168.4.1";

    final savedColorVal = prefs.getInt('saved_neon_color');
    if (savedColorVal != null) {
      neonAccent = Color(savedColorVal);
    }

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
      if (isNightScheduleEnabled) {
        notifyListeners();
      }
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

  Future<void> setNeonTheme(Color newColor) async {
    neonAccent = newColor;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('saved_neon_color', newColor.value);
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

  void adjustVolume(int delta) {
    final target = (volume + delta).clamp(0, 29);
    if (target != volume) {
      volume = target;
      notifyListeners();
      sendDspValue("VOL", volume);
    }
  }

  void dispatchTextCommand(String text) {
    final clean = text.trim().toLowerCase();
    final match = RegExp(r'(set\s+)?vol(ume)?\s+(\d+)').firstMatch(clean);

    if (match != null) {
      final target = int.tryParse(match.group(3) ?? "")?.clamp(0, 29);
      if (target != null) {
        volume = target;
        notifyListeners();
        sendDspValue("VOL", target);
        return;
      }
    }

    if (clean.contains("mute")) {
      volume = 0;
      notifyListeners();
      sendDspValue("VOL", 0);
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
            side: const BorderSide(color: Color(0xFF1C2638)),
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
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF1C2638))),
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
            return Container(
              height: MediaQuery.of(context).size.height * 0.88,
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
              child: ListView(
                physics: const BouncingScrollPhysics(),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "STUDIO HARDWARE & DSP SETTINGS",
                        style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      )
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Night Stealth Card
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1C2638)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.nightlight_round, color: dsp.isNightModeActive ? const Color(0xFF7A6843) : const Color(0xFF78909C), size: 18),
                                const SizedBox(width: 8),
                                const Text("NIGHT STEALTH MODE", style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Switch(
                              value: dsp.isNightModeManual,
                              activeColor: const Color(0xFF7A6843),
                              onChanged: (val) {
                                dsp.setNightModeManual(val);
                                setModalState(() {});
                              },
                            ),
                          ],
                        ),
                        const Divider(color: Color(0xFF1C2638), height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("AUTO TIME SCHEDULE", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold)),
                            Switch(
                              value: dsp.isNightScheduleEnabled,
                              activeColor: const Color(0xFF7A6843),
                              onChanged: (val) {
                                dsp.setNightSchedule(val, dsp.nightStartHour, dsp.nightStartMinute, dsp.nightEndHour, dsp.nightEndMinute);
                                setModalState(() {});
                              },
                            ),
                          ],
                        ),
                        if (dsp.isNightScheduleEnabled) ...[
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _timeButton("START", dsp.nightStartHour, dsp.nightStartMinute, () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay(hour: dsp.nightStartHour, minute: dsp.nightStartMinute),
                                );
                                if (picked != null) {
                                  dsp.setNightSchedule(true, picked.hour, picked.minute, dsp.nightEndHour, dsp.nightEndMinute);
                                  setModalState(() {});
                                }
                              }),
                              const Icon(Icons.arrow_forward, color: Color(0xFF546E7A), size: 16),
                              _timeButton("END", dsp.nightEndHour, dsp.nightEndMinute, () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay(hour: dsp.nightEndHour, minute: dsp.nightEndMinute),
                                );
                                if (picked != null) {
                                  dsp.setNightSchedule(true, dsp.nightStartHour, dsp.nightStartMinute, picked.hour, picked.minute);
                                  setModalState(() {});
                                }
                              }),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Themes
                  const Text("NEON GLOW THEME COLOR", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 10),
                  Opacity(
                    opacity: dsp.isNightModeActive ? 0.35 : 1.0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: DspWebSocketService.availableThemes.map((c) {
                        final isSel = dsp.neonAccent.value == c.value;
                        return GestureDetector(
                          onTap: dsp.isNightModeActive ? null : () {
                            dsp.setNeonTheme(c);
                            setModalState(() {});
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSel ? Colors.white : Colors.transparent,
                                width: isSel ? 3 : 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: c.withOpacity(isSel ? 0.6 : 0.2),
                                  blurRadius: isSel ? 10 : 3,
                                )
                              ],
                            ),
                            child: isSel ? const Icon(Icons.check, color: Colors.black, size: 20) : null,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const Divider(color: Color(0xFF1C2638), height: 26),

                  // Speaker Balance Control
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

                  // Input Gain Boost
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("INPUT GAIN BOOST", style: TextStyle(color: Color(0xFF78909C), fontSize: 11, fontWeight: FontWeight.bold)),
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

                  // Loudness Controls
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

                  // Subwoofer Cutoff
                  const Text("SUBWOOFER CUTOFF (LPF)", style: TextStyle(color: Color(0xFF78909C), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  _buildOptionRow(["Flat", "80 Hz", "120 Hz", "160 Hz"], dsp.subCutoff, accent, (opt) {
                    setModalState(() => dsp.subCutoff = opt);
                    dsp.sendDspValue("SUBCUT", opt);
                  }),
                  const SizedBox(height: 14),

                  // Bass Controls (Center, Q, DC Mode)
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

                  // Middle Controls (Center, Q)
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

                  // Treble Controls
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

  Widget _timeButton(String label, int h, int m, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF121824),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF1C2638)),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(color: Color(0xFF78909C), fontSize: 9, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(_formatTimeOfDay(h, m), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
          ],
        ),
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
                            border: Border.all(color: const Color(0xFF1C2638)),
                          ),
                          child: Icon(Icons.tune, color: accent, size: 16),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          final next = dsp.currentSource == "BT AUDIO" ? "AUX IN" : "BT AUDIO";
                          dsp.sendDspValue("INP", next);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF141C2B),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF1C2638)),
                          ),
                          child: Text(
                            dsp.currentSource,
                            style: TextStyle(color: accent, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  )
                ],
              ),
            ),

            // Main Controls Scrollable Rack
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
                                onChangeEnd: (v) => dsp.sendDspValue("VOL", v),
                              ),
                              const SizedBox(height: 10),

                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _stepButton(
                                    icon: Icons.remove,
                                    accent: accent,
                                    onTap: () => dsp.adjustVolume(-1),
                                  ),
                                  const SizedBox(width: 14),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF090D14),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFF1C2638)),
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
                                        setState(() => localSub = null);
                                        dsp.sendDspValue("SUB", v.toInt());
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
                                                color: isSel ? accent : const Color(0xFF1C2638),
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
                                  border: Border.all(color: const Color(0xFF162030)),
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
                                          setState(() => localBass = null);
                                          dsp.sendDspValue("BAS", v);
                                        },
                                      ),
                                      _StudioVerticalFader(
                                        title: "MID",
                                        freq: dsp.midCenter,
                                        val: curMid,
                                        accentColor: accent,
                                        onDrag: (v) => setState(() => localMid = v),
                                        onEnd: (v) {
                                          setState(() => localMid = null);
                                          dsp.sendDspValue("MID", v);
                                        },
                                      ),
                                      _StudioVerticalFader(
                                        title: "TREBLE",
                                        freq: dsp.trebleCut,
                                        val: curTreble,
                                        accentColor: accent,
                                        onDrag: (v) => setState(() => localTreble = v),
                                        onEnd: (v) {
                                          setState(() => localTreble = null);
                                          dsp.sendDspValue("TRE", v);
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

            // Bottom Cyber Command Bar (Clean, Pet-free)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFF090D15),
                border: Border(top: BorderSide(color: Color(0xFF1C2638), width: 1.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.terminal, color: accent, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _commandController,
                      style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        hintText: "Enter Command: 'set volume 10', 'mute'...",
                        hintStyle: const TextStyle(color: Color(0xFF455A64), fontSize: 11),
                        filled: true,
                        fillColor: const Color(0xFF0F1522),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Color(0xFF1E283B)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: accent),
                        ),
                      ),
                      onSubmitted: (val) {
                        if (val.trim().isNotEmpty) {
                          dsp.dispatchTextCommand(val);
                          _commandController.clear();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.send_rounded, color: accent, size: 20),
                    onPressed: () {
                      if (_commandController.text.trim().isNotEmpty) {
                        dsp.dispatchTextCommand(_commandController.text);
                        _commandController.clear();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glassCard({required Widget child, required Color cardColor, EdgeInsetsGeometry padding = const EdgeInsets.all(14)}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: cardColor.withOpacity(0.75),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1C2638)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _stepButton({required IconData icon, required Color accent, required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 44,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFF121824),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF1E283B)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 6,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Center(
            child: Icon(icon, color: accent, size: 20),
          ),
        ),
      ),
    );
  }
}

// ==========================================================
// 4. INDIVIDUAL POP-ZOOM VERTICAL FADER
// ==========================================================
class _StudioVerticalFader extends StatefulWidget {
  final String title;
  final String freq;
  final int val;
  final Color accentColor;
  final ValueChanged<int> onDrag;
  final ValueChanged<int> onEnd;

  const _StudioVerticalFader({
    required this.title,
    required this.freq,
    required this.val,
    required this.accentColor,
    required this.onDrag,
    required this.onEnd,
  });

  @override
  State<_StudioVerticalFader> createState() => _StudioVerticalFaderState();
}

class _StudioVerticalFaderState extends State<_StudioVerticalFader> {
  bool isPressed = false;
  double? _dragStartY;
  int? _startVal;

  void _handlePanStart(DragStartDetails details) {
    setState(() => isPressed = true);
    _dragStartY = details.globalPosition.dy;
    _startVal = widget.val;
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (_dragStartY == null || _startVal == null) return;
    final deltaY = _dragStartY! - details.globalPosition.dy;
    final int stepDelta = (deltaY / 3.5).round();
    final int target = (_startVal! + stepDelta).clamp(-15, 15);
    widget.onDrag(target);
  }

  void _handlePanEnd(DragEndDetails details) {
    setState(() => isPressed = false);
    _dragStartY = null;
    _startVal = null;
    widget.onEnd(widget.val);
  }

  @override
  Widget build(BuildContext context) {
    final double pct = (widget.val + 15) / 30.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: _handlePanStart,
      onVerticalDragUpdate: _handlePanUpdate,
      onVerticalDragEnd: _handlePanEnd,
      onVerticalDragCancel: () {
        setState(() => isPressed = false);
        widget.onEnd(widget.val);
      },
      child: AnimatedScale(
        scale: isPressed ? 1.25 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          width: 70,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              Text(
                "${widget.val >= 0 ? '+' : ''}${widget.val} dB",
                style: TextStyle(
                  color: widget.accentColor,
                  fontSize: isPressed ? 12 : 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),

              SizedBox(
                height: 95,
                width: 28,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    Container(
                      width: isPressed ? 6 : 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E283B),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    Container(
                      width: isPressed ? 6 : 4,
                      height: 95 * pct,
                      decoration: BoxDecoration(
                        color: widget.accentColor,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    Positioned(
                      bottom: (95 * pct) - 8,
                      child: Container(
                        width: isPressed ? 20 : 16,
                        height: isPressed ? 20 : 16,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              Text(widget.freq, style: const TextStyle(color: Color(0xFF546E7A), fontSize: 9)),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 5. IN-PLACE POP-ZOOM HORIZONTAL SLIDER
// ==========================================
class _InPlacePopHorizontalSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int divisions;
  final Color accentColor;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _InPlacePopHorizontalSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.accentColor,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  State<_InPlacePopHorizontalSlider> createState() => _InPlacePopHorizontalSliderState();
}

class _InPlacePopHorizontalSliderState extends State<_InPlacePopHorizontalSlider> {
  bool isPressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isPressed ? 1.25 : 1.0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      child: Listener(
        onPointerDown: (_) => setState(() => isPressed = true),
        onPointerUp: (_) => setState(() => isPressed = false),
        onPointerCancel: (_) => setState(() => isPressed = false),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: isPressed ? 7 : 4,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: isPressed ? 14 : 9),
            activeTrackColor: widget.accentColor,
            inactiveTrackColor: const Color(0xFF1E283B),
            thumbColor: Colors.white,
          ),
          child: Slider(
            value: widget.value,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: widget.onChanged,
            onChangeEnd: (v) {
              setState(() => isPressed = false);
              widget.onChangeEnd(v);
            },
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 6. REAL-TIME EQUALIZER CURVE PAINTER
// ==========================================
class _EqCurvePainter extends CustomPainter {
  final int bass, mid, treble;
  final Color accent;
  _EqCurvePainter({required this.bass, required this.mid, required this.treble, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final yCenter = size.height / 2;

    final gridPaint = Paint()
      ..color = const Color(0xFF1B2638)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, yCenter), Offset(size.width, yCenter), gridPaint);

    final yBass = yCenter - (bass / 15.0) * (size.height * 0.38);
    final yMid = yCenter - (mid / 15.0) * (size.height * 0.38);
    final yTreb = yCenter - (treble / 15.0) * (size.height * 0.38);

    final path = Path();
    path.moveTo(0, yBass);
    path.cubicTo(size.width * 0.25, yBass, size.width * 0.35, yMid, size.width * 0.5, yMid);
    path.cubicTo(size.width * 0.65, yMid, size.width * 0.75, yTreb, size.width, yTreb);

    final fillPath = Path.from(path);
    fillPath.lineTo(size.width, size.height);
    fillPath.lineTo(0, size.height);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [accent.withOpacity(0.25), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);

    final strokePaint = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter oldDelegate) {
    return oldDelegate.bass != bass || oldDelegate.mid != mid || oldDelegate.treble != treble || oldDelegate.accent != accent;
  }
}

// =========================================================
// 7. COMPACT ROTARY DIAL
// =========================================================
class RotaryDial extends StatefulWidget {
  final double size;
  final int value;
  final int max;
  final Color accentColor;
  final bool isNightMode;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  const RotaryDial({
    super.key,
    this.size = 140,
    required this.value,
    this.max = 29,
    required this.accentColor,
    this.isNightMode = false,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  State<RotaryDial> createState() => _RotaryDialState();
}

class _RotaryDialState extends State<RotaryDial> {
  late int _localVal;
  bool isPressed = false;
  Offset? _lastPanPos;
  double _accumulatedDelta = 0.0;

  @override
  void initState() {
    super.initState();
    _localVal = widget.value;
  }

  @override
  void didUpdateWidget(RotaryDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    _localVal = widget.value;
  }

  void _onPanStart(DragStartDetails details) {
    setState(() => isPressed = true);
    _lastPanPos = details.localPosition;
    _accumulatedDelta = 0.0;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_lastPanPos == null) return;
    final center = Offset(widget.size / 2, widget.size / 2);
    final prevVec = _lastPanPos! - center;
    final currVec = details.localPosition - center;

    final double cross = prevVec.dx * currVec.dy - prevVec.dy * currVec.dx;
    final double angleDelta = cross / (prevVec.distance * currVec.distance + 0.001);

    _accumulatedDelta += angleDelta;
    _lastPanPos = details.localPosition;

    const double stepSensitivity = 0.12;
    if (_accumulatedDelta.abs() >= stepSensitivity) {
      final steps = (_accumulatedDelta / stepSensitivity).truncate();
      _accumulatedDelta -= steps * stepSensitivity;

      final target = (_localVal + steps).clamp(0, widget.max);
      if (target != _localVal) {
        setState(() => _localVal = target);
        widget.onChanged(target);
      }
    }
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() => isPressed = false);
    _lastPanPos = null;
    _accumulatedDelta = 0.0;
    widget.onChangeEnd(_localVal);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isPressed ? 1.20 : 1.0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        onPanCancel: () {
          setState(() => isPressed = false);
          _lastPanPos = null;
          widget.onChangeEnd(_localVal);
        },
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: _DialPainter(
              val: _localVal,
              max: widget.max,
              dialSize: widget.size,
              isGlowing: isPressed && !widget.isNightMode,
              accentColor: widget.accentColor,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "$_localVal",
                    style: TextStyle(
                      color: widget.accentColor,
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Text(
                    "LEVEL / 29",
                    style: TextStyle(
                      color: Color(0xFF78909C),
                      fontSize: 8.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final int val;
  final int max;
  final double dialSize;
  final bool isGlowing;
  final Color accentColor;

  _DialPainter({
    required this.val,
    required this.max,
    required this.dialSize,
    this.isGlowing = false,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = dialSize * 0.38;
    final discRadius = dialSize * 0.28;
    const startAngle = 135 * (pi / 180);
    const sweepTotal = 270 * (pi / 180);

    final trackPaint = Paint()
      ..color = const Color(0xFF162233)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweepTotal, false, trackPaint);

    final pct = val / max;
    final activePaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = isGlowing ? 9.5 : 7.5
      ..strokeCap = StrokeCap.round;

    if (isGlowing) {
      activePaint.maskFilter = const MaskFilter.blur(BlurStyle.solid, 5);
    }

    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweepTotal * pct, false, activePaint);

    final discPaint = Paint()..color = const Color(0xFF0D1422);
    final discBorder = Paint()
      ..color = isGlowing ? accentColor : const Color(0xFF1C2A40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isGlowing ? 2.5 : 2.0;
    canvas.drawCircle(center, discRadius, discPaint);
    canvas.drawCircle(center, discRadius, discBorder);
  }

  @override
  bool shouldRepaint(covariant _DialPainter oldDelegate) {
    return oldDelegate.val != val || oldDelegate.dialSize != dialSize || oldDelegate.isGlowing != isGlowing || oldDelegate.accentColor != accentColor;
  }
}
