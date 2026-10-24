// Block Bloom - a juicy block puzzle game.
// Drag the three blocks onto the 8x8 grid. Fill a row or column to clear it.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ───────────────────────────── CONFIG ─────────────────────────────
const bool kAdsEnabled = true;
// These are Google's official TEST ad units (safe while developing).
// Before publishing, replace them with YOUR ad units from admob.google.com
const String kBannerId = 'ca-app-pub-3940256099942544/6300978111';
const String kInterstitialId = 'ca-app-pub-3940256099942544/1033173712';
const int kInterstitialEvery = 3; // full-screen ad after every Nth game over

const int kN = 8; // board is kN x kN
const double kPad = 9; // padding inside the board panel
const double kAdH = 60; // space reserved for the banner

const List<Color> kColors = [
  Color(0xFFFF5A7A), // strawberry
  Color(0xFFFF9F43), // tangerine
  Color(0xFFFFD93D), // lemon
  Color(0xFF45D483), // mint
  Color(0xFF3CB8FF), // sky
  Color(0xFF8B7BFF), // grape
  Color(0xFFE56BF5), // orchid
];

// ───────────────────────────── HELPERS ─────────────────────────────
double _cl(double v, double a, double b) => v < a ? a : (v > b ? b : v);

double _easeOutBack(double t) {
  const c1 = 1.70158;
  const c3 = c1 + 1;
  final x = t - 1;
  return 1 + c3 * x * x * x + c1 * x * x;
}

Color _op(Color c, double o) => c.withAlpha(_cl(255 * o, 0, 255).round());

// Draws one glossy candy block.
void drawBlock(Canvas canvas, Rect cell, Color c, {double o = 1, double scale = 1}) {
  final r = scale == 1
      ? cell
      : Rect.fromCenter(center: cell.center, width: cell.width * scale, height: cell.height * scale);
  final w = r.width;
  if (w <= 0.5) return;
  final outer = RRect.fromRectAndRadius(r, Radius.circular(w * 0.26));
  canvas.drawRRect(
    outer,
    Paint()
      ..shader = ui.Gradient.linear(r.topCenter, r.bottomCenter, [
        _op(Color.lerp(c, Colors.white, 0.42)!, o),
        _op(Color.lerp(c, Colors.black, 0.30)!, o),
      ]),
  );
  final ir = r.deflate(w * 0.1);
  canvas.drawRRect(
    RRect.fromRectAndRadius(ir, Radius.circular(w * 0.2)),
    Paint()
      ..shader = ui.Gradient.linear(ir.topCenter, ir.bottomCenter, [
        _op(Color.lerp(c, Colors.white, 0.12)!, o),
        _op(c, o),
      ]),
  );
  final gloss = RRect.fromRectAndRadius(
    Rect.fromLTWH(r.left + w * 0.2, r.top + w * 0.15, w * 0.6, w * 0.17),
    Radius.circular(w * 0.09),
  );
  canvas.drawRRect(gloss, Paint()..color = _op(Colors.white, 0.30 * o));
}

void drawText(Canvas canvas, String text, Offset center, double size, Color color, double alpha, double scale) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w900,
        color: _op(color, alpha),
        letterSpacing: 0.5,
        shadows: [Shadow(color: _op(Colors.black, alpha * 0.55), blurRadius: 8, offset: const Offset(0, 3))],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.scale(scale);
  tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  canvas.restore();
}

// ───────────────────────────── SOUND ─────────────────────────────
// All sounds are synthesised in code, so there are no audio files to manage.
Uint8List _synth(List<double> freqs,
    {double step = 0.07, double len = 0.2, double gain = 0.5, double decay = 16}) {
  const sr = 22050;
  final total = (freqs.length - 1) * step + len;
  final n = (total * sr).round();
  final buf = List<double>.filled(n, 0.0);
  final m = (len * sr).round();
  for (int k = 0; k < freqs.length; k++) {
    final start = (k * step * sr).round();
    for (int i = 0; i < m && start + i < n; i++) {
      final t = i / sr;
      final env = math.exp(-t * decay) * math.min(1.0, i / 60.0) * math.min(1.0, (m - i) / 250.0);
      final ph = 2 * math.pi * freqs[k] * t;
      buf[start + i] += (math.sin(ph) + 0.3 * math.sin(2 * ph) + 0.1 * math.sin(3 * ph)) * env;
    }
  }
  final data = ByteData(44 + n * 2);
  void tag(int o, String v) {
    for (int i = 0; i < v.length; i++) {
      data.setUint8(o + i, v.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sr, Endian.little);
  data.setUint32(28, sr * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (int i = 0; i < n; i++) {
    final v = _cl(buf[i] * gain, -1, 1);
    data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

class Sfx {
  Sfx._();
  static final Sfx I = Sfx._();
  bool enabled = true;
  bool _started = false;
  final Map<String, Uint8List> _bytes = {};
  final Map<String, AudioPlayer> _players = {};

  Future<void> init() async {
    if (_started) return;
    _started = true;
    _bytes['pick'] = _synth([587.33], len: 0.09, gain: 0.35, decay: 30);
    _bytes['drop'] = _synth([196, 130.8], step: 0.03, len: 0.16, gain: 0.7, decay: 22);
    _bytes['clear'] = _synth([523.25, 659.25, 783.99, 1046.5], step: 0.065, len: 0.28, gain: 0.45, decay: 10);
    _bytes['combo'] = _synth([659.25, 783.99, 987.77, 1318.5, 1568.0], step: 0.06, len: 0.3, gain: 0.45, decay: 9);
    _bytes['nope'] = _synth([185, 155.6], step: 0.07, len: 0.14, gain: 0.5, decay: 20);
    _bytes['over'] = _synth([392, 349.2, 311.1, 261.6], step: 0.16, len: 0.45, gain: 0.5, decay: 6);
    for (final e in _bytes.entries) {
      try {
        final p = AudioPlayer();
        try {
          // let the player's music keep playing while we make sound effects
          await (p as dynamic).setAudioContext(
            AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
          );
        } catch (_) {}
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSource(BytesSource(e.value));
        _players[e.key] = p;
      } catch (_) {}
    }
  }

  Future<void> play(String name) async {
    if (!enabled) return;
    final p = _players[name];
    if (p == null) return;
    try {
      await p.seek(Duration.zero);
      await p.resume();
    } catch (_) {
      try {
        await p.play(BytesSource(_bytes[name]!));
      } catch (_) {}
    }
  }
}

// ───────────────────────────── ADS ─────────────────────────────
class Ads {
  Ads._();
  static final Ads I = Ads._();
  InterstitialAd? _inter;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  void loadInterstitial() {
    if (!kAdsEnabled || _inter != null) return;
    InterstitialAd.load(
      adUnitId: kInterstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _inter = ad,
        onAdFailedToLoad: (err) => _inter = null,
      ),
    );
  }

  void showInterstitial() {
    final ad = _inter;
    if (!kAdsEnabled || ad == null) {
      loadInterstitial();
      return;
    }
    // never show two full-screen ads within a minute: keeps players happy
    if (DateTime.now().difference(_last).inSeconds < 60) return;
    _inter = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        loadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (a, e) {
        a.dispose();
        loadInterstitial();
      },
    );
    _last = DateTime.now();
    ad.show();
  }
}

// ───────────────────────────── MODELS ─────────────────────────────
class PieceShape {
  final List<List<int>> cells; // [row, col]
  final int rows, cols;
  PieceShape(this.cells, this.rows, this.cols);
}

class ShapeFamily {
  final List<PieceShape> rots;
  final double weight;
  ShapeFamily(this.rots, this.weight);
}

class Piece {
  final PieceShape shape;
  final int color;
  Piece(this.shape, this.color);
}

PieceShape _normalize(List<List<int>> cells) {
  var minR = 1 << 30, minC = 1 << 30, maxR = -(1 << 30), maxC = -(1 << 30);
  for (final c in cells) {
    minR = math.min(minR, c[0]);
    minC = math.min(minC, c[1]);
    maxR = math.max(maxR, c[0]);
    maxC = math.max(maxC, c[1]);
  }
  final n = [
    for (final c in cells) [c[0] - minR, c[1] - minC]
  ];
  n.sort((a, b) => a[0] != b[0] ? a[0] - b[0] : a[1] - b[1]);
  return PieceShape(n, maxR - minR + 1, maxC - minC + 1);
}

ShapeFamily _family(List<String> rows, double weight) {
  var cells = <List<int>>[];
  for (int r = 0; r < rows.length; r++) {
    for (int c = 0; c < rows[r].length; c++) {
      if (rows[r][c] == '#') cells.add([r, c]);
    }
  }
  final seen = <String>{};
  final rots = <PieceShape>[];
  for (int k = 0; k < 4; k++) {
    final sh = _normalize(cells);
    final key = sh.cells.map((e) => '${e[0]},${e[1]}').join(';');
    if (seen.add(key)) rots.add(sh);
    cells = [
      for (final e in cells) [e[1], -e[0]]
    ]; // rotate 90 degrees
  }
  return ShapeFamily(rots, weight);
}

final List<ShapeFamily> kFamilies = [
  _family(['#'], 0.35),
  _family(['##'], 2.0),
  _family(['###'], 2.0),
  _family(['####'], 1.3),
  _family(['#####'], 0.7),
  _family(['##', '##'], 2.2),
  _family(['###', '###'], 1.0),
  _family(['###', '###', '###'], 0.7),
  _family(['#.', '##'], 1.8),
  _family(['#..', '#..', '###'], 1.0),
  _family(['#.', '#.', '##'], 1.2),
  _family(['.#', '.#', '##'], 1.2),
  _family(['###', '.#.'], 1.2),
  _family(['.##', '##.'], 1.0),
  _family(['##.', '.##'], 1.0),
];

class Particle {
  double x, y, vx, vy;
  double life = 0;
  final double maxLife, size;
  double delay;
  final Color color;
  Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.maxLife,
    required this.size,
    required this.color,
    required this.delay,
  });
}

class ClearCell {
  final int r, c, color;
  final double born, delay;
  ClearCell(this.r, this.c, this.color, this.born, this.delay);
}

class FloatText {
  final String text;
  final double fx, fy, size, born, dur;
  final Color color;
  FloatText({
    required this.text,
    required this.fx,
    required this.fy,
    required this.size,
    required this.color,
    required this.born,
    this.dur = 1.0,
  });
}

// ───────────────────────────── APP ─────────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const BlockBloomApp());
  // Start the ads + sound plugins only AFTER the first frame is on screen, so a slow or
  // failing plugin can never block (or take down) the start-up of the game itself.
  WidgetsBinding.instance.addPostFrameCallback((_) => _startServices());
}

Future<void> _startServices() async {
  if (kAdsEnabled) {
    try {
      await MobileAds.instance.initialize();
    } catch (e) {
      debugPrint('Ads init failed: $e');
    }
  }
  try {
    await Sfx.I.init();
  } catch (e) {
    debugPrint('Sound init failed: $e');
  }
}

class BlockBloomApp extends StatelessWidget {
  const BlockBloomApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Block Bloom',
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

// ───────────────────────────── REUSABLE UI ─────────────────────────────
class GradientButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final List<Color> colors;
  final double width;
  const GradientButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.colors,
    this.icon,
    this.width = 220,
  });
  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => down = true),
      onTapUp: (_) {
        setState(() => down = false);
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      onTapCancel: () => setState(() => down = false),
      child: AnimatedScale(
        scale: down ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: Container(
          width: widget.width,
          height: 62,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.colors,
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(31),
            border: Border.all(color: const Color(0x66FFFFFF), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: widget.colors.last.withAlpha(120),
                blurRadius: 20,
                offset: const Offset(0, 9),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, color: Colors.white, size: 30),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                  shadows: [Shadow(color: Color(0x55000000), blurRadius: 4, offset: Offset(0, 2))],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x1AFFFFFF),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Icon(icon, color: const Color(0xDDFFFFFF), size: 22),
      ),
    );
  }
}

// ───────────────────────────── HOME ─────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 20))..repeat();
  int best = 0;

  @override
  void initState() {
    super.initState();
    _loadBest();
  }

  Future<void> _loadBest() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => best = p.getInt('best') ?? 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    await Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (_, __, ___) => const GamePage(),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
    _loadBest();
  }

  Widget _gradText(String t, List<Color> colors) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) =>
          LinearGradient(colors: colors, begin: Alignment.topCenter, end: Alignment.bottomCenter)
              .createShader(rect),
      child: Text(
        t,
        style: const TextStyle(
          fontSize: 66,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
          height: 0.98,
          color: Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF3A2184), Color(0xFF1B1F5E), Color(0xFF0D1136)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: CustomPaint(painter: FloatingBlocksPainter(_c))),
            SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 128, height: 128, child: CustomPaint(painter: LogoPainter(_c))),
                    const SizedBox(height: 26),
                    _gradText('Block', const [Color(0xFFFFFFFF), Color(0xFFBFD4FF)]),
                    _gradText('Bloom', const [Color(0xFFFF7A9C), Color(0xFFFFB24A)]),
                    const SizedBox(height: 12),
                    const Text(
                      'Place. Clear. Bloom.',
                      style: TextStyle(
                        color: Color(0xAAFFFFFF),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 56),
                    AnimatedBuilder(
                      animation: _c,
                      builder: (context, child) => Transform.scale(
                        scale: 1 + 0.03 * math.sin(_c.value * math.pi * 2 * 10),
                        child: child,
                      ),
                      child: GradientButton(
                        label: 'Play',
                        icon: Icons.play_arrow_rounded,
                        width: 220,
                        colors: const [Color(0xFFFF7A9C), Color(0xFFFF9A44)],
                        onTap: _play,
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (best > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.emoji_events_rounded, color: Color(0xFFFFD93D), size: 22),
                          const SizedBox(width: 8),
                          Text(
                            'Best  $best',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LogoPainter extends CustomPainter {
  final Animation<double> a;
  LogoPainter(this.a) : super(repaint: a);
  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 2;
    const cols = [0, 2, 4, 3];
    for (int i = 0; i < 4; i++) {
      final r = i ~/ 2, c = i % 2;
      final bob = math.sin(a.value * math.pi * 2 * 8 + i * 1.3) * 3;
      drawBlock(
        canvas,
        Rect.fromLTWH(c * cell + 3, r * cell + 3 + bob, cell - 6, cell - 6),
        kColors[cols[i]],
      );
    }
  }

  @override
  bool shouldRepaint(covariant LogoPainter old) => true;
}

class FloatingBlocksPainter extends CustomPainter {
  final Animation<double> anim;
  FloatingBlocksPainter(this.anim) : super(repaint: anim);

  static final List<List<double>> _b = () {
    final r = math.Random(11);
    return List.generate(
      16,
      (i) => <double>[
        r.nextDouble(),
        r.nextDouble(),
        16 + r.nextDouble() * 30,
        (i % kColors.length).toDouble(),
        (1 + i % 3).toDouble(),
        r.nextDouble() * 6.28,
      ],
    );
  }();

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in _b) {
      final f = (b[1] - anim.value * b[4]) % 1.0;
      final x = b[0] * size.width;
      final y = size.height * (1.1 - f * 1.2);
      final ang = anim.value * math.pi * 2 * b[4] + b[5];
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(ang);
      final s = b[2];
      drawBlock(canvas, Rect.fromLTWH(-s / 2, -s / 2, s, s), kColors[b[3].toInt()], o: 0.14);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant FloatingBlocksPainter old) => true;
}

// ───────────────────────────── GAME ─────────────────────────────
class GamePage extends StatefulWidget {
  const GamePage({super.key});
  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with SingleTickerProviderStateMixin {
  final math.Random rnd = math.Random();
  final ValueNotifier<int> tick = ValueNotifier<int>(0);
  final GlobalKey rootKey = GlobalKey();
  final GlobalKey boardKey = GlobalKey();
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double clock = 0;

  // game state
  List<List<int>> grid = List.generate(kN, (_) => List<int>.filled(kN, -1));
  final List<Piece?> tray = [null, null, null];
  final List<bool> placeable = [true, true, true];
  final List<double> trayBorn = [0, 0, 0];
  int score = 0, best = 0, bestAtStart = 0, combo = 0, sinceClear = 0, gamesPlayed = 0;
  double dispScore = 0;
  bool over = false, showOver = false, newBest = false;

  // dragging
  int? dragIdx;
  int? _dragPointer;
  Offset dragPos = Offset.zero;
  Offset _dragStart0 = Offset.zero;
  bool _moved = false;
  double dragBorn = 0;
  bool ghostOk = false;
  int ghostR = 0, ghostC = 0;
  final Set<int> preview = {};

  // effects
  final List<Particle> parts = [];
  final List<ClearCell> clearing = [];
  final Map<int, double> pops = {};
  final List<FloatText> texts = [];
  double shake = 0;

  final Sfx sfx = Sfx.I;
  bool soundOn = true;
  BannerAd? _banner;
  bool _bannerReady = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _resetState();
    _loadPrefs();
    _loadBanner();
    Ads.I.loadInterstitial();
  }

  @override
  void dispose() {
    _ticker.dispose();
    tick.dispose();
    _banner?.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      best = p.getInt('best') ?? 0;
      bestAtStart = best;
      soundOn = p.getBool('sound') ?? true;
      sfx.enabled = soundOn;
    });
  }

  Future<void> _saveBest() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('best', best);
  }

  void _loadBanner() {
    if (!kAdsEnabled) return;
    _banner = BannerAd(
      adUnitId: kBannerId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (mounted) setState(() => _bannerReady = true);
        },
        onAdFailedToLoad: (ad, err) {
          ad.dispose();
          _banner = null;
        },
      ),
    )..load();
  }

  Future<void> _toggleSound() async {
    setState(() {
      soundOn = !soundOn;
      sfx.enabled = soundOn;
    });
    final p = await SharedPreferences.getInstance();
    await p.setBool('sound', soundOn);
    if (soundOn) {
      HapticFeedback.selectionClick();
      sfx.play('pick');
    }
  }

  void _haptic(Future<void> Function() f) {
    if (soundOn) f();
  }

  // ───── animation loop (runs only while something is animating) ─────
  void _wake() {
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  bool get _busy {
    if (parts.isNotEmpty || clearing.isNotEmpty || pops.isNotEmpty || texts.isNotEmpty) return true;
    if (shake > 0) return true;
    if ((score - dispScore).abs() > 0.01) return true;
    for (int i = 0; i < 3; i++) {
      if (tray[i] != null && clock - trayBorn[i] < 0.5) return true;
    }
    if (dragIdx != null && clock - dragBorn < 0.25) return true;
    return false;
  }

  void _onTick(Duration e) {
    final dt = math.min((e - _last).inMicroseconds / 1000000.0, 0.05);
    _last = e;
    clock += dt;
    for (final p in parts) {
      if (p.delay > 0) {
        p.delay -= dt;
        continue;
      }
      p.life += dt;
      p.vy += 900 * dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
    }
    parts.removeWhere((p) => p.life >= p.maxLife);
    clearing.removeWhere((c) => clock - c.born > c.delay + 0.45);
    pops.removeWhere((k, v) => clock - v > 0.3);
    texts.removeWhere((t) => clock - t.born > t.dur);
    if (shake > 0) {
      shake *= math.exp(-dt * 7);
      if (shake < 0.02) shake = 0;
    }
    dispScore += (score - dispScore) * math.min(1.0, dt * 9);
    if ((score - dispScore).abs() < 0.6) dispScore = score.toDouble();
    tick.value++;
    if (!_busy) _ticker.stop();
  }

  // ───── game logic ─────
  void _resetState() {
    grid = List.generate(kN, (_) => List<int>.filled(kN, -1));
    score = 0;
    dispScore = 0;
    combo = 0;
    sinceClear = 0;
    over = false;
    showOver = false;
    newBest = false;
    bestAtStart = best;
    parts.clear();
    clearing.clear();
    pops.clear();
    texts.clear();
    preview.clear();
    shake = 0;
    dragIdx = null;
    _dragPointer = null;
    ghostOk = false;
    _dealTray();
  }

  void _restart() {
    setState(_resetState);
    _wake();
    if (kAdsEnabled && gamesPlayed > 0 && gamesPlayed % kInterstitialEvery == 0) {
      Ads.I.showInterstitial();
    }
  }

  Piece _randPiece() {
    double total = 0;
    for (final f in kFamilies) {
      total += f.weight;
    }
    var x = rnd.nextDouble() * total;
    for (final f in kFamilies) {
      x -= f.weight;
      if (x <= 0) {
        return Piece(f.rots[rnd.nextInt(f.rots.length)], rnd.nextInt(kColors.length));
      }
    }
    return Piece(kFamilies.first.rots.first, 0);
  }

  void _dealTray() {
    List<Piece> pick = [];
    for (int attempt = 0; attempt < 50; attempt++) {
      pick = [for (int k = 0; k < 3; k++) _randPiece()];
      if (pick.any((p) => _canPlaceAnywhere(p.shape))) break; // always give the player a fair hand
    }
    for (int i = 0; i < 3; i++) {
      tray[i] = pick[i];
      trayBorn[i] = clock + i * 0.09;
    }
    _updatePlaceable();
    _wake();
  }

  bool _fits(PieceShape sh, int r, int c) {
    for (final o in sh.cells) {
      final rr = r + o[0], cc = c + o[1];
      if (rr < 0 || rr >= kN || cc < 0 || cc >= kN || grid[rr][cc] != -1) return false;
    }
    return true;
  }

  bool _canPlaceAnywhere(PieceShape sh) {
    for (int r = 0; r <= kN - sh.rows; r++) {
      for (int c = 0; c <= kN - sh.cols; c++) {
        if (_fits(sh, r, c)) return true;
      }
    }
    return false;
  }

  void _updatePlaceable() {
    for (int i = 0; i < 3; i++) {
      final p = tray[i];
      placeable[i] = p != null && _canPlaceAnywhere(p.shape);
    }
  }

  double boardCell() {
    final ro = boardKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) return (ro.size.width - 2 * kPad) / kN;
    return 40;
  }

  void _computeGhost() {
    ghostOk = false;
    preview.clear();
    final i = dragIdx;
    if (i == null) return;
    final p = tray[i];
    if (p == null) return;
    // a simple tap must never drop a piece: finger has to travel first
    if (!_moved) {
      if ((dragPos - _dragStart0).distance < 16) return;
      _moved = true;
    }
    final ro = boardKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    final origin = ro.localToGlobal(Offset.zero);
    final cell = (ro.size.width - 2 * kPad) / kN;
    final lift = p.shape.rows * cell / 2 + 44; // piece floats above the finger
    final left = dragPos.dx - p.shape.cols * cell / 2;
    final top = dragPos.dy - lift - p.shape.rows * cell / 2;
    final c = ((left - origin.dx - kPad) / cell).round();
    final r = ((top - origin.dy - kPad) / cell).round();
    if (_fits(p.shape, r, c)) {
      ghostOk = true;
      ghostR = r;
      ghostC = c;
      _calcPreview(p, r, c);
    }
  }

  void _calcPreview(Piece p, int r, int c) {
    final g = [for (final row in grid) List<int>.of(row)];
    for (final o in p.shape.cells) {
      g[r + o[0]][c + o[1]] = p.color;
    }
    for (int a = 0; a < kN; a++) {
      if (g[a].every((v) => v >= 0)) {
        for (int k = 0; k < kN; k++) {
          preview.add(a * kN + k);
        }
      }
      bool full = true;
      for (int b = 0; b < kN; b++) {
        if (g[b][a] < 0) {
          full = false;
          break;
        }
      }
      if (full) {
        for (int k = 0; k < kN; k++) {
          preview.add(k * kN + a);
        }
      }
    }
  }

  // ───── touch handling ─────
  void _dragStart(int i, Offset pos, int pointer) {
    if (over || dragIdx != null || tray[i] == null) return;
    dragIdx = i;
    _dragPointer = pointer;
    dragPos = pos;
    _dragStart0 = pos;
    _moved = false;
    dragBorn = clock;
    _computeGhost();
    _haptic(HapticFeedback.selectionClick);
    sfx.play('pick');
    _wake();
    tick.value++;
  }

  void _dragUpdate(Offset pos, int pointer) {
    if (pointer != _dragPointer || dragIdx == null) return;
    dragPos = pos;
    _computeGhost();
    tick.value++;
  }

  void _dragEnd(int pointer) {
    if (pointer != _dragPointer) return;
    final i = dragIdx;
    _dragPointer = null;
    dragIdx = null;
    if (i == null) return;
    final ok = ghostOk, r = ghostR, c = ghostC;
    ghostOk = false;
    preview.clear();
    if (ok && tray[i] != null) {
      setState(() => _place(i, r, c));
    } else {
      trayBorn[i] = clock - 0.18; // little bounce back into the tray
      if (_moved) sfx.play('nope');
      _wake();
      tick.value++;
    }
  }

  void _dragCancel(int pointer) {
    if (pointer != _dragPointer) return;
    dragIdx = null;
    _dragPointer = null;
    ghostOk = false;
    preview.clear();
    tick.value++;
  }

  void _addText(String text, double fx, double fy, double size, Color color, {double dur = 1.0}) {
    texts.add(FloatText(text: text, fx: fx, fy: fy, size: size, color: color, born: clock, dur: dur));
  }

  void _burst(int r, int c, int color, double delay, int nLines) {
    final cell = boardCell();
    final x = kPad + (c + .5) * cell, y = kPad + (r + .5) * cell;
    final n = 4 + math.min(nLines, 4);
    for (int i = 0; i < n; i++) {
      final a = rnd.nextDouble() * math.pi * 2;
      final sp = 90 + rnd.nextDouble() * 260;
      parts.add(Particle(
        x: x,
        y: y,
        vx: math.cos(a) * sp,
        vy: math.sin(a) * sp - 140,
        maxLife: 0.55 + rnd.nextDouble() * 0.5,
        size: 2.5 + rnd.nextDouble() * 4,
        color: i % 3 == 0 ? Colors.white : kColors[color],
        delay: delay,
      ));
    }
    if (parts.length > 500) parts.removeRange(0, parts.length - 500);
  }

  void _place(int i, int r, int c) {
    final p = tray[i]!;
    final cell = boardCell();
    final bs = cell * kN + 2 * kPad;
    for (final o in p.shape.cells) {
      final rr = r + o[0], cc = c + o[1];
      grid[rr][cc] = p.color;
      pops[rr * kN + cc] = clock;
    }
    tray[i] = null;
    var gained = p.shape.cells.length;
    final fx = (kPad + (c + p.shape.cols / 2) * cell) / bs;
    final fy = (kPad + (r + p.shape.rows / 2) * cell) / bs;

    final rowsFull = <int>[], colsFull = <int>[];
    for (int a = 0; a < kN; a++) {
      if (grid[a].every((v) => v >= 0)) rowsFull.add(a);
      bool full = true;
      for (int b = 0; b < kN; b++) {
        if (grid[b][a] < 0) {
          full = false;
          break;
        }
      }
      if (full) colsFull.add(a);
    }
    final nLines = rowsFull.length + colsFull.length;

    if (nLines > 0) {
      final cells = <int>{};
      for (final rr in rowsFull) {
        for (int k = 0; k < kN; k++) {
          cells.add(rr * kN + k);
        }
      }
      for (final cc in colsFull) {
        for (int k = 0; k < kN; k++) {
          cells.add(k * kN + cc);
        }
      }
      final pr = r + p.shape.rows / 2, pc = c + p.shape.cols / 2;
      for (final id in cells) {
        final rr = id ~/ kN, cc = id % kN;
        final color = grid[rr][cc];
        final d = math.sqrt(math.pow(rr + .5 - pr, 2) + math.pow(cc + .5 - pc, 2));
        final delay = d * 0.035;
        clearing.add(ClearCell(rr, cc, color, clock, delay));
        _burst(rr, cc, color, delay, nLines);
        grid[rr][cc] = -1;
      }
      combo += 1;
      sinceClear = 0;
      gained += 10 * nLines * nLines * combo;

      if (nLines >= 4) {
        _addText('Incredible!', 0.5, 0.36, 40, const Color(0xFFFFE066));
      } else if (nLines == 3) {
        _addText('Awesome!', 0.5, 0.36, 38, const Color(0xFFFFE066));
      } else if (nLines == 2) {
        _addText('Great!', 0.5, 0.36, 36, const Color(0xFFFFFFFF));
      }
      if (combo >= 2) {
        _addText('Combo x$combo', 0.5, 0.52, 30, const Color(0xFFFF8FB1), dur: 1.2);
      }
      shake = math.max(shake, math.min(1.0, 0.2 + 0.2 * nLines));
      _haptic(nLines >= 3 ? HapticFeedback.heavyImpact : HapticFeedback.mediumImpact);
      sfx.play(combo >= 2 || nLines >= 2 ? 'combo' : 'clear');

      if (grid.every((row) => row.every((v) => v < 0))) {
        gained += 200;
        _addText('Perfect!', 0.5, 0.24, 46, const Color(0xFFFFE066), dur: 1.5);
      }
    } else {
      sinceClear++;
      if (sinceClear >= 3) combo = 0;
      _haptic(HapticFeedback.lightImpact);
      sfx.play('drop');
    }

    score += gained;
    if (score > best) {
      best = score;
      _saveBest();
    }
    _addText('+$gained', fx, fy, nLines > 0 ? 30 : 22, nLines > 0 ? const Color(0xFFFFE066) : Colors.white,
        dur: 0.9);

    if (tray.every((t) => t == null)) _dealTray();
    _updatePlaceable();
    final any = [for (int k = 0; k < 3; k++) tray[k] != null && placeable[k]].any((b) => b);
    if (!any) _gameOver();
    _wake();
  }

  void _gameOver() {
    over = true;
    newBest = score > bestAtStart && score > 0;
    gamesPlayed++;
    _saveBest();
    sfx.play('over');
    _haptic(HapticFeedback.heavyImpact);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && over) setState(() => showOver = true);
    });
  }

  // ───── UI ─────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141844),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2E1F6B), Color(0xFF171C4F), Color(0xFF0D1136)],
          ),
        ),
        child: Stack(
          key: rootKey,
          fit: StackFit.expand,
          children: [
            SafeArea(child: LayoutBuilder(builder: _layout)),
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: DragPainter(this)))),
            if (showOver)
              Positioned.fill(
                child: Container(
                  color: const Color(0xB3070A22),
                  child: Center(child: _overCard()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _layout(BuildContext context, BoxConstraints cons) {
    final w = cons.maxWidth, h = cons.maxHeight;
    const topH = 88.0;
    final boardSize = math.max(200.0, math.min(w - 24, (h - topH - kAdH - 60) / 1.4));
    final cell = (boardSize - 2 * kPad) / kN;
    final slotW = (w - 24) / 3;
    final trayCell = math.min(cell * 0.62, slotW / 5.4);
    final trayH = trayCell * 5 + 20;
    return Column(
      children: [
        _topBar(),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<int>(
                  valueListenable: tick,
                  builder: (context, _, child) => Transform.translate(
                    offset: Offset(math.sin(clock * 70) * 5 * shake, math.cos(clock * 53) * 4 * shake),
                    child: child,
                  ),
                  child: SizedBox(
                    key: boardKey,
                    width: boardSize,
                    height: boardSize,
                    child: CustomPaint(painter: BoardPainter(this)),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: w - 24,
                  height: trayH,
                  child: Row(children: [for (int i = 0; i < 3; i++) _slot(i, trayCell)]),
                ),
                SizedBox(
                  height: 22,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: score == 0 ? 0.7 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: const Text(
                        'Drag a block onto the grid',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: kAdH, child: Center(child: _bannerWidget())),
      ],
    );
  }

  Widget _bannerWidget() {
    final b = _banner;
    if (!_bannerReady || b == null) return const SizedBox.shrink();
    return SizedBox(
      width: b.size.width.toDouble(),
      height: b.size.height.toDouble(),
      child: AdWidget(ad: b),
    );
  }

  Widget _slot(int i, double trayCell) {
    return Expanded(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _dragStart(i, e.position, e.pointer),
        onPointerMove: (e) => _dragUpdate(e.position, e.pointer),
        onPointerUp: (e) => _dragEnd(e.pointer),
        onPointerCancel: (e) => _dragCancel(e.pointer),
        child: SizedBox.expand(child: CustomPaint(painter: TrayPainter(this, i, trayCell))),
      ),
    );
  }

  Widget _topBar() {
    return SizedBox(
      height: 88,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            _RoundBtn(
              icon: Icons.arrow_back_ios_new_rounded,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ValueListenableBuilder<int>(
                    valueListenable: tick,
                    builder: (context, _, __) => Text(
                      '${dispScore.round()}',
                      style: const TextStyle(
                        fontSize: 46,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        height: 1.05,
                        shadows: [Shadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 3))],
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.emoji_events_rounded, color: Color(0xFFFFD93D), size: 16),
                      const SizedBox(width: 5),
                      Text(
                        'Best  ${math.max(best, score)}',
                        style: const TextStyle(
                          color: Color(0xCCFFFFFF),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _RoundBtn(
              icon: soundOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              onTap: _toggleSound,
            ),
          ],
        ),
      ),
    );
  }

  Widget _overCard() {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutBack,
      builder: (context, v, child) => Opacity(
        opacity: _cl(v, 0, 1),
        child: Transform.scale(scale: 0.8 + 0.2 * v, child: child),
      ),
      child: Container(
        width: 300,
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF343A8C), Color(0xFF1F2463)],
          ),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: const Color(0x33FFFFFF), width: 1.5),
          boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 30, offset: Offset(0, 14))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              newBest ? 'New best!' : 'No more moves',
              style: TextStyle(
                color: newBest ? const Color(0xFFFFD93D) : const Color(0xCCFFFFFF),
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '$score',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 70,
                fontWeight: FontWeight.w900,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.emoji_events_rounded, color: Color(0xFFFFD93D), size: 18),
                const SizedBox(width: 6),
                Text(
                  'Best  $best',
                  style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 24),
            GradientButton(
              label: 'Play again',
              icon: Icons.replay_rounded,
              width: 240,
              colors: const [Color(0xFFFF7A9C), Color(0xFFFF9A44)],
              onTap: _restart,
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text(
                'Home',
                style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── PAINTERS ─────────────────────────────
class BoardPainter extends CustomPainter {
  final _GamePageState s;
  BoardPainter(this.s) : super(repaint: s.tick);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = (size.width - 2 * kPad) / kN;
    final panel = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(24));
    canvas.drawRRect(
      panel.shift(const Offset(0, 8)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.drawRRect(
      panel,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, size.height),
          const [Color(0xFF2A3070), Color(0xFF1C2158)],
        ),
    );
    canvas.drawRRect(
      panel.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x26FFFFFF),
    );

    Rect rect(int r, int c) =>
        Rect.fromLTWH(kPad + c * cell + 1.5, kPad + r * cell + 1.5, cell - 3, cell - 3);

    // empty slots
    final empty = Paint()..color = const Color(0x16FFFFFF);
    for (int r = 0; r < kN; r++) {
      for (int c = 0; c < kN; c++) {
        canvas.drawRRect(RRect.fromRectAndRadius(rect(r, c), Radius.circular(cell * 0.2)), empty);
      }
    }

    // placed blocks
    final glow = Paint()..color = const Color(0x66FFFFFF);
    for (int r = 0; r < kN; r++) {
      for (int c = 0; c < kN; c++) {
        final v = s.grid[r][c];
        if (v < 0) continue;
        double sc = 1;
        final born = s.pops[r * kN + c];
        if (born != null) {
          final t = _cl((s.clock - born) / 0.28, 0, 1);
          sc = 1 + 0.22 * math.sin(t * math.pi);
        }
        drawBlock(canvas, rect(r, c), kColors[v], scale: sc);
        if (s.preview.contains(r * kN + c)) {
          canvas.drawRRect(RRect.fromRectAndRadius(rect(r, c), Radius.circular(cell * 0.24)), glow);
        }
      }
    }

    // blocks being cleared
    for (final cl in s.clearing) {
      final local = s.clock - cl.born;
      if (local < cl.delay) {
        drawBlock(canvas, rect(cl.r, cl.c), kColors[cl.color]);
        continue;
      }
      final t = _cl((local - cl.delay) / 0.4, 0, 1);
      final sc = t < 0.25 ? 1 + 1.2 * t : 1.3 * (1 - (t - 0.25) / 0.75);
      drawBlock(canvas, rect(cl.r, cl.c), kColors[cl.color], scale: sc);
      final fr = rect(cl.r, cl.c);
      final flash = Rect.fromCenter(center: fr.center, width: fr.width * sc, height: fr.height * sc);
      if (flash.width > 1) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(flash, Radius.circular(flash.width * 0.26)),
          Paint()..color = _op(Colors.white, (1 - t) * 0.75),
        );
      }
    }

    // ghost preview of where the piece will land
    final di = s.dragIdx;
    if (di != null && s.ghostOk) {
      final p = s.tray[di];
      if (p != null) {
        for (final o in p.shape.cells) {
          final rr = s.ghostR + o[0], cc = s.ghostC + o[1];
          final strong = s.preview.contains(rr * kN + cc);
          drawBlock(canvas, rect(rr, cc), kColors[p.color], o: strong ? 0.95 : 0.5);
        }
      }
    }

    // sparkles
    for (final p in s.parts) {
      if (p.delay > 0) continue;
      final f = p.life / p.maxLife;
      canvas.drawCircle(Offset(p.x, p.y), p.size * (1 - 0.6 * f), Paint()..color = _op(p.color, 1 - f));
    }

    // floating text
    for (final t in s.texts) {
      final k = (s.clock - t.born) / t.dur;
      if (k < 0 || k > 1) continue;
      final a = k < 0.15 ? k / 0.15 : (k > 0.7 ? (1 - k) / 0.3 : 1.0);
      final sc = 0.6 + 0.4 * _easeOutBack(_cl(k * 5, 0, 1));
      drawText(
        canvas,
        t.text,
        Offset(t.fx * size.width, t.fy * size.height - 34 * k),
        t.size,
        t.color,
        a,
        sc,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoardPainter old) => true;
}

class TrayPainter extends CustomPainter {
  final _GamePageState s;
  final int i;
  final double cell;
  TrayPainter(this.s, this.i, this.cell) : super(repaint: s.tick);

  @override
  void paint(Canvas canvas, Size size) {
    final p = s.tray[i];
    if (p == null || s.dragIdx == i) return;
    final t = (s.clock - s.trayBorn[i]) / 0.42;
    if (t < 0) return;
    final sc = t >= 1 ? 1.0 : _easeOutBack(t);
    final o = s.placeable[i] ? 1.0 : 0.38;
    final pw = p.shape.cols * cell, ph = p.shape.rows * cell;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(sc);
    for (final c in p.shape.cells) {
      final rect = Rect.fromLTWH(-pw / 2 + c[1] * cell, -ph / 2 + c[0] * cell, cell, cell).deflate(1);
      drawBlock(canvas, rect, kColors[p.color], o: o);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TrayPainter old) => true;
}

class DragPainter extends CustomPainter {
  final _GamePageState s;
  DragPainter(this.s) : super(repaint: s.tick);

  @override
  void paint(Canvas canvas, Size size) {
    final i = s.dragIdx;
    if (i == null) return;
    final p = s.tray[i];
    if (p == null) return;
    final ro = s.rootKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    final cell = s.boardCell();
    final local = ro.globalToLocal(s.dragPos);
    final lift = p.shape.rows * cell / 2 + 44;
    final k = _cl((s.clock - s.dragBorn) / 0.16, 0, 1);
    final e = _easeOutBack(k);
    final cx = local.dx, cy = local.dy - lift * _cl(e, 0, 1.05);
    final sc = 0.62 + 0.38 * e;
    final pw = p.shape.cols * cell, ph = p.shape.rows * cell;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(sc);
    for (final c in p.shape.cells) {
      final rect = Rect.fromLTWH(-pw / 2 + c[1] * cell, -ph / 2 + c[0] * cell, cell, cell).deflate(1.5);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.shift(const Offset(0, 12)), Radius.circular(cell * 0.25)),
        Paint()
          ..color = const Color(0x44000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    for (final c in p.shape.cells) {
      final rect = Rect.fromLTWH(-pw / 2 + c[1] * cell, -ph / 2 + c[0] * cell, cell, cell).deflate(1.5);
      drawBlock(canvas, rect, kColors[p.color]);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DragPainter old) => true;
}
