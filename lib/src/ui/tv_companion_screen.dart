import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/tv_companion_client.dart';
import '../services/tv_h264_player.dart';

const _bg = Color(0xFF06101A);
const _panel = Color(0xFF0A1C29);
const _line = Color(0xFF215370);
const _cyan = Color(0xFF29C7FF);
const _muted = Color(0xFF8EA7BA);

/// Full-screen touch area. Switching pages is only possible using controls,
/// never by a horizontal swipe. The original TV Remote screen is unaffected.
class TvCompanionScreen extends StatefulWidget {
  const TvCompanionScreen({super.key, required this.host});
  final String host;

  @override
  State<TvCompanionScreen> createState() => _TvCompanionScreenState();
}

enum _Panel { mouse, apps, keyboard, settings, screen }

class _TvCompanionScreenState extends State<TvCompanionScreen>
    with WidgetsBindingObserver {
  late final TvCompanionClient client = TvCompanionClient(widget.host);
  final _vault = const FlutterSecureStorage();
  final pin = TextEditingController();
  final input = TextEditingController();
  final apps = <_TvApp>[];
  final _touches = <int, Offset>{};
  StreamSubscription<bool>? _connectionSubscription;
  Timer? _heartbeat;
  Timer? _retry;
  Timer? _dragArm;
  Timer? _moveTick;
  late final TvH264Player _player = TvH264Player(_onVideoStatus);
  int? _videoTexture;
  bool _videoStarting = false;
  int _videoEpoch = 0;
  bool _screenControls = false;
  bool _videoFill = true;
  String _screenMessage = 'На приставке включите трансляцию экрана';
  int _screenWidth = 1280;
  int _screenHeight = 720;
  Offset? _screenPanFrom;
  Offset? _screenPanTo;
  DateTime? _screenPanStarted;
  double _screenScrollDistance = 0;
  bool _screenDidScroll = false;
  Future<void>? _movementPending;

  _Panel panel = _Panel.mouse;
  String? pendingFingerprint;
  String status = 'Поиск компонента на приставке…';
  bool confirmed = false;
  bool busy = false;
  bool paired = false;
  bool connected = false;
  bool connecting = false;
  bool loadingApps = false;
  bool _appActive = true;
  bool _multiTouch = false;
  bool _touchMoved = false;
  bool _dragActive = false;
  bool _dragClosing = false;
  bool _accelerate = true;
  bool _haptics = false;
  int _retries = 0;
  double sensitivity = 1.7;
  double _accumX = 0, _accumY = 0;
  double _accumScroll = 0;
  double _scrollQueue = 0;
  Offset? _touchStart;
  DateTime? _touchDownTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectionSubscription = client.connectionChanges.listen((up) {
      if (!mounted) return;
      setState(() => connected = up);
      if (!up && paired && _appActive && !connecting) _scheduleRetry();
    });
    _heartbeat = Timer.periodic(const Duration(seconds: 22), (_) {
      if (_appActive && paired && !connecting) unawaited(_checkLink());
    });
    _moveTick = Timer.periodic(const Duration(milliseconds: 16), (_) => _flushMove());
    unawaited(_loadSettings());
    unawaited(_restore());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (_appActive) {
      _updateImmersive();
      if (paired) unawaited(_checkLink());
      if (panel == _Panel.screen) unawaited(_startVideo());
    } else {
      unawaited(_stopVideo());
      _retry?.cancel();
      _dragArm?.cancel();
      _touches.clear();
      _accumX = _accumY = 0;
      if (_dragActive) unawaited(_endDrag());
      // Do not close TLS here: a backgrounded phone must not lose pairing.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _dragArm?.cancel();
    _heartbeat?.cancel();
    _moveTick?.cancel();
    unawaited(_stopVideo());
    _player.dispose();
    unawaited(SystemChrome.setPreferredOrientations([]));
    _connectionSubscription?.cancel();
    pin.dispose();
    input.dispose();
    client.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  String get _pref => 'pult_tv_${widget.host}_';

  Future<void> _loadSettings() async {
    try {
      final speed = double.tryParse(await _vault.read(key: '${_pref}speed') ?? '');
      final acceleration = await _vault.read(key: '${_pref}accel');
      final haptics = await _vault.read(key: '${_pref}haptics');
      if (!mounted) return;
      setState(() {
        if (speed != null) sensitivity = speed.clamp(.6, 4.0).toDouble();
        if (acceleration != null) _accelerate = acceleration == 'true';
        if (haptics != null) _haptics = haptics == 'true';
      });
    } catch (_) { /* Defaults are safe when secure storage is unavailable. */ }
  }

  void _updateImmersive() {
    if (!_appActive) return;
    unawaited(SystemChrome.setEnabledSystemUIMode(
      paired && (panel == _Panel.mouse || panel == _Panel.screen)
          ? SystemUiMode.immersiveSticky
          : SystemUiMode.edgeToEdge,
    ));
  }

  void _showPanel(_Panel next) {
    if (panel == _Panel.screen && next != _Panel.screen) {
      unawaited(_stopVideo());
      unawaited(SystemChrome.setPreferredOrientations([]));
    }
    _dragArm?.cancel();
    _touches.clear();
    if (_dragActive) unawaited(_endDrag());
    setState(() { panel = next; _screenControls = false; });
    _updateImmersive();
    if (next == _Panel.apps && apps.isEmpty) unawaited(_loadApps());
    if (next == _Panel.screen) {
      unawaited(SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight,
      ]));
      unawaited(_startVideo());
    }
  }

  void _onVideoStatus(String message, int width, int height) {
    if (!mounted || panel != _Panel.screen) return;
    setState(() {
      _screenMessage = message;
      _screenWidth = width;
      _screenHeight = height;
    });
  }

  Future<void> _startVideo() async {
    if (!mounted || !paired || !_appActive || panel != _Panel.screen ||
        _videoStarting || _videoTexture != null) return;
    _videoStarting = true;
    final epoch = ++_videoEpoch;
    try {
      final identity = await client.storedIdentity();
      if (identity == null) throw StateError('Нет сопряжения с приставкой');
      final texture = await _player.start(host: widget.host,
          fingerprint: identity.fingerprint, token: identity.token);
      if (!mounted || panel != _Panel.screen || !_appActive || epoch != _videoEpoch) {
        await _player.stop();
        return;
      }
      setState(() => _videoTexture = texture);
    } catch (e) {
      if (mounted && panel == _Panel.screen) {
        setState(() => _screenMessage = 'Ошибка видеопотока: $e');
      }
    } finally {
      _videoStarting = false;
      if (mounted && _appActive && panel == _Panel.screen &&
          _videoTexture == null && epoch != _videoEpoch) {
        unawaited(_startVideo());
      }
    }
  }

  Future<void> _stopVideo() async {
    ++_videoEpoch;
    _videoTexture = null;
    try { await _player.stop(); } catch (_) { }
  }

  Offset? _screenNormalize(Offset touch, Size size) {
    if (size.width <= 0 || size.height <= 0) return null;
    final scale = _videoFill
        ? math.max(size.width / _screenWidth, size.height / _screenHeight)
        : math.min(size.width / _screenWidth, size.height / _screenHeight);
    final drawnWidth = _screenWidth * scale;
    final drawnHeight = _screenHeight * scale;
    final left = (size.width - drawnWidth) / 2;
    final top = (size.height - drawnHeight) / 2;
    final x = (touch.dx - left) / drawnWidth;
    final y = (touch.dy - top) / drawnHeight;
    if (!_videoFill && (x < 0 || x > 1 || y < 0 || y > 1)) return null;
    return Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
  }

  void _screenTouch(String command, Offset position, Size size) {
    if (!connected || _videoTexture == null) return;
    final point = _screenNormalize(position, size);
    if (point == null) return;
    _command(command, {'x': point.dx, 'y': point.dy});
  }

  void _screenSwipe(Size size) {
    final from = _screenPanFrom;
    final to = _screenPanTo;
    if (!connected || _screenDidScroll || from == null || to == null ||
        (from - to).distance < 12) return;
    final a = _screenNormalize(from, size);
    final b = _screenNormalize(to, size);
    if (a == null || b == null) return;
    final elapsed = DateTime.now().difference(_screenPanStarted ?? DateTime.now())
        .inMilliseconds.clamp(130, 700);
    _command('screen_swipe', {
      'x1': a.dx, 'y1': a.dy, 'x2': b.dx, 'y2': b.dy,
      'duration': elapsed,
    });
  }

  Future<void> _restore() async {
    setState(() { busy = true; status = 'Подключение к ${widget.host}…'; });
    try {
      final identity = await client.storedIdentity();
      if (!mounted) return;
      if (identity == null) {
        await _probe();
      } else {
        setState(() => paired = true);
        _updateImmersive();
        await _checkLink();
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Нет соединения: $e');
      if (paired) _scheduleRetry();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _probe() async {
    final fingerprint = await client.probeFingerprint();
    if (!mounted) return;
    setState(() {
      pendingFingerprint = fingerprint;
      confirmed = false;
      status = 'Сравни SHA-256 с экраном приставки';
    });
  }

  Future<void> _pair() async {
    if (!confirmed || pendingFingerprint == null || busy) return;
    setState(() { busy = true; status = 'Сопряжение…'; });
    try {
      await client.pair(pendingFingerprint!, pin.text.trim());
      if (!mounted) return;
      pin.clear();
      setState(() {
        paired = true;
        connected = true;
        panel = _Panel.mouse;
        status = 'Подключено';
      });
      _updateImmersive();
    } catch (e) {
      if (mounted) setState(() => status = 'Не удалось сопрячь: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _forget() async {
    _retry?.cancel();
    await client.forget();
    if (!mounted) return;
    setState(() {
      paired = false;
      connected = false;
      pendingFingerprint = null;
      confirmed = false;
      apps.clear();
    });
    _updateImmersive();
    try { await _probe(); }
    catch (e) { if (mounted) setState(() => status = 'Нет связи: $e'); }
  }

  Future<void> _checkLink() async {
    if (connecting || !paired || !_appActive) return;
    connecting = true;
    try {
      await client.ensureConnected();
      _retries = 0;
      _retry?.cancel();
      if (mounted) setState(() { connected = true; status = 'Подключено'; });
    } catch (e) {
      if (mounted) setState(() { connected = false; status = 'Восстанавливаем связь: $e'; });
    } finally {
      connecting = false;
      if (!connected && paired && _appActive) _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_retry?.isActive == true || !_appActive || !paired) return;
    final delay = [2, 3, 5, 8, 13, 20][_retries.clamp(0, 5).toInt()];
    _retries = (_retries + 1).clamp(0, 5).toInt();
    _retry = Timer(Duration(seconds: delay), () => unawaited(_checkLink()));
  }

  Future<Map<String, dynamic>?> _send(Map<String, dynamic> cmd,
      {bool silent = false}) async {
    if (!client.isConnected) {
      if (!connecting && paired) unawaited(_checkLink());
      return null;
    }
    try {
      final result = await client.request(cmd);
      if (result['ok'] != true) throw StateError('${result['error'] ?? 'Команда отклонена'}');
      return result;
    } catch (e) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('$e'), duration: const Duration(seconds: 2)));
      }
      if (!client.isConnected && paired) unawaited(_checkLink());
      return null;
    }
  }

  void _command(String cmd, [Map<String, dynamic> extras = const {}]) {
    if (_haptics) unawaited(HapticFeedback.selectionClick());
    unawaited(_send({'cmd': cmd, ...extras}));
  }

  // Raw pointer tracking avoids conflicts between pan and page swipe recognizers.
  void _pointerDown(PointerDownEvent e) {
    if (!connected) return;
    _touches[e.pointer] = e.position;
    if (_touches.length == 1) {
      _touchStart = e.position;
      _touchDownTime = DateTime.now();
      _touchMoved = false;
      _multiTouch = false;
      _dragArm?.cancel();
      _dragArm = Timer(const Duration(milliseconds: 520), () {
        if (_touches.length == 1 && !_multiTouch && !_touchMoved && connected) {
          _dragActive = true;
          _command('drag_start');
        }
      });
    } else {
      _multiTouch = true;
      _dragArm?.cancel();
      if (_dragActive) unawaited(_endDrag());
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    final last = _touches[e.pointer];
    if (last == null) return;
    _touches[e.pointer] = e.position;
    final delta = e.position - last;
    if (_multiTouch || _touches.length >= 2) {
      _multiTouch = true;
      _dragArm?.cancel();
      _trackScroll(delta.dy / math.max(1, _touches.length));
      return;
    }
    if (!_touchMoved && _touchStart != null &&
        (e.position - _touchStart!).distance > 9) {
      _touchMoved = true;
      _dragArm?.cancel();
    }
    // A tap may jitter a few pixels: never move the cursor before the
    // movement threshold has been crossed.
    if (!_touchMoved && !_dragActive) return;
    final magnitude = delta.distance;
    final acceleration = _accelerate ? (1 + (magnitude / 16).clamp(0.0, 0.7)) : 1.0;
    _accumX += delta.dx * sensitivity * acceleration;
    _accumY += delta.dy * sensitivity * acceleration;
  }

  void _pointerUp(PointerEvent e) {
    if (_touches.remove(e.pointer) == null) return;
    _dragArm?.cancel();
    if (_dragActive) {
      unawaited(_endDrag());
    } else if (!_multiTouch && !_touchMoved && _touches.isEmpty &&
        _touchDownTime != null &&
        DateTime.now().difference(_touchDownTime!).inMilliseconds < 490) {
      // Two quick taps send two actual tap gestures, without delaying the first.
      _command('tap');
    }
    if (_touches.isEmpty) {
      _multiTouch = false;
      _touchStart = null;
      _touchDownTime = null;
      _flushMove();
    }
  }

  void _flushMove() {
    if (!connected || _dragClosing || _movementPending != null ||
        (_accumX.abs() < .25 && _accumY.abs() < .25)) return;
    // One movement in flight, accumulated deltas. No unbounded queue of stale
    // cursor positions. Android clamps each move to 250px on the TV.
    final dx = _accumX.clamp(-200.0, 200.0).toDouble();
    final dy = _accumY.clamp(-200.0, 200.0).toDouble();
    _accumX -= dx;
    _accumY -= dy;
    final isDrag = _dragActive;
    final pending = _send({'cmd': isDrag ? 'drag_move' : 'move', 'dx': dx, 'dy': dy}, silent: true)
        .then<void>((_) {});
    _movementPending = pending;
    unawaited(pending.whenComplete(() {
      if (identical(_movementPending, pending)) _movementPending = null;
    }));
  }

  Future<void> _endDrag() async {
    if (!_dragActive || _dragClosing) return;
    _dragClosing = true;
    _dragActive = false;
    try {
      final prior = _movementPending;
      if (prior != null) await prior;
      // Finish all accumulated drag movement before releasing the long press.
      while (client.isConnected &&
          (_accumX.abs() > .2 || _accumY.abs() > .2)) {
        final dx = _accumX.clamp(-200.0, 200.0).toDouble();
        final dy = _accumY.clamp(-200.0, 200.0).toDouble();
        _accumX -= dx;
        _accumY -= dy;
        await _send({'cmd': 'drag_move', 'dx': dx, 'dy': dy}, silent: true);
      }
      await _send({'cmd': 'drag_end'}, silent: true);
    } finally {
      _dragClosing = false;
    }
  }

  void _trackScroll(double dy) {
    _accumScroll += dy;
    if (_accumScroll.abs() < 18) return;
    final steps = (_accumScroll.abs() / 35).clamp(1.0, 4.0);
    _scrollQueue += _accumScroll < 0 ? steps : -steps;
    _accumScroll = 0;
    _drainScroll();
  }

  bool _scrollSending = false;
  Future<void> _drainScroll() async {
    if (_scrollSending || !connected || _scrollQueue.abs() < .2) return;
    _scrollSending = true;
    try {
      while (mounted && connected && _scrollQueue.abs() >= .2) {
        final value = _scrollQueue.clamp(-4.0, 4.0).toDouble();
        _scrollQueue -= value;
        await _send({'cmd': 'scroll', 'dy': value}, silent: true);
      }
    } finally {
      _scrollSending = false;
    }
  }

  Future<void> _loadApps() async {
    if (loadingApps) return;
    setState(() => loadingApps = true);
    try {
      if (!client.isConnected) await _checkLink();
      if (!client.isConnected) return;
      final answer = await _send({'cmd': 'apps'});
      if (answer == null || !mounted) return;
      final entries = (answer['apps'] as List<dynamic>?) ?? [];
      setState(() {
        apps
          ..clear()
          ..addAll(entries.whereType<Map<String, dynamic>>().map(_TvApp.fromJson));
        apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      });
    } finally {
      if (mounted) setState(() => loadingApps = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (paired && panel == _Panel.mouse) {
      return Scaffold(backgroundColor: _bg, body: _fullscreenMouse());
    }
    if (paired && panel == _Panel.screen) {
      return Scaffold(backgroundColor: Colors.black, body: _fullscreenScreen());
    }
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        title: Text(!paired ? 'Пульт · Подключение' :
          panel == _Panel.apps ? 'Приложения X96' :
          panel == _Panel.keyboard ? 'Клавиатура X96' : 'Настройки мыши'),
        actions: [
          if (paired) IconButton(
            tooltip: 'Экран приставки',
            icon: const Icon(Icons.tv_rounded, color: _cyan),
            onPressed: () => _showPanel(_Panel.screen),
          ),
          if (paired) IconButton(
            tooltip: 'Полноэкранная мышь',
            icon: const Icon(Icons.mouse_rounded, color: _cyan),
            onPressed: () => _showPanel(_Panel.mouse),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: _tile(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('X96 · ${widget.host}:39678',
                style: const TextStyle(color: _cyan, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(status, style: const TextStyle(color: _muted, fontSize: 12)),
          ])),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 2, color: _cyan),
        Expanded(child: !paired ? _pairPage() : switch (panel) {
          _Panel.apps => _appsPage(),
          _Panel.keyboard => _keyboardPage(),
          _Panel.settings => _settingsPage(),
          _Panel.mouse => const SizedBox.shrink(),
          _Panel.screen => const SizedBox.shrink(),
        }),
      ]),
    );
  }

  Widget _fullscreenMouse() => Stack(children: [
    Positioned.fill(child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerUp,
      child: const SizedBox.expand(),
    )),
    // Instructions are not a separate panel and don't intercept touch input.
    const Positioned.fill(child: IgnorePointer(child: Center(
      child: Opacity(opacity: .18, child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mouse_rounded, size: 48, color: _cyan),
          SizedBox(height: 8),
          Text('ТАЧПАД', style: TextStyle(color: Colors.white,
              letterSpacing: 3, fontWeight: FontWeight.bold)),
          Text('1 палец · курсор       2 пальца · прокрутка',
              style: TextStyle(color: _muted, fontSize: 11)),
        ],
      )),
    ))),
    Positioned(top: 16, left: 15, right: 15,
      child: Row(children: [
        _mouseButton(Icons.chevron_left_rounded, 'Обычный пульт', () {
          unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
          Navigator.maybePop(context);
        }),
        const SizedBox(width: 7),
        Expanded(child: Center(child: GestureDetector(
          onTap: () => unawaited(_checkLink()),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: _panel.withValues(alpha: .85),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: connected ? _line : Colors.orangeAccent),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(connected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                  size: 14, color: connected ? _cyan : Colors.orangeAccent),
              const SizedBox(width: 6),
              Flexible(child: Text(connected ? 'X96 · подключено' : 'Переподключение…',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11))),
            ]),
          ),
        ))),
        _mouseButton(Icons.tv_rounded, 'Экран X96', () => _showPanel(_Panel.screen)),
        const SizedBox(width: 6),
        _mouseButton(Icons.apps_rounded, 'Приложения', () => _showPanel(_Panel.apps)),
        const SizedBox(width: 6),
        _mouseButton(Icons.keyboard_rounded, 'Клавиатура', () => _showPanel(_Panel.keyboard)),
        const SizedBox(width: 6),
        _mouseButton(Icons.tune_rounded, 'Настройки', () => _showPanel(_Panel.settings)),
      ]),
    ),
    // An optional dedicated vertical scroll strip; the rest remains touchpad.
    Positioned(right: 5, top: 95, bottom: 92, width: 31,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => _trackScroll(d.delta.dy),
        child: Align(alignment: Alignment.centerRight,
          child: Container(height: 125, width: 26,
            decoration: BoxDecoration(color: _panel.withValues(alpha: .78),
              borderRadius: BorderRadius.circular(20), border: Border.all(color: _line)),
            child: const Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: _cyan),
              Icon(Icons.swap_vert_rounded, size: 15, color: _muted),
              Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: _cyan),
            ]),
          ),
        ),
      ),
    ),
    Positioned(left: 12, right: 12, bottom: 10,
      child: Row(children: [
        Expanded(child: _mouseWide(Icons.arrow_back_rounded, 'Назад', () => _command('key', {'code': 4}))),
        const SizedBox(width: 8),
        Expanded(child: _mouseWide(Icons.home_rounded, 'Домой', () => _command('key', {'code': 3}))),
        const SizedBox(width: 8),
        Expanded(child: _mouseWide(Icons.ads_click_rounded, 'Клик', () => _command('tap'))),
        const SizedBox(width: 8),
        _mouseButton(Icons.visibility_off_rounded, 'Скрыть курсор', () => _command('hide_cursor')),
      ]),
    ),
  ]);

  Widget _fullscreenScreen() => LayoutBuilder(builder: (context, constraints) {
    final screenSize = Size(constraints.maxWidth, constraints.maxHeight);
    return Stack(children: [
      Positioned.fill(child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _screenTouch('screen_tap', d.localPosition, screenSize),
        onLongPressStart: (d) => _screenTouch('screen_long', d.localPosition, screenSize),
        onPanStart: (d) {
          _screenPanFrom = d.localPosition;
          _screenPanTo = d.localPosition;
          _screenPanStarted = DateTime.now();
          _screenDidScroll = false;
          _screenScrollDistance = 0;
        },
        onPanUpdate: (d) {
          _screenPanTo = d.localPosition;
          final start = _screenPanFrom;
          if (start == null) return;
          final travel = d.localPosition - start;
          // Scroll visible lists *during* the gesture, not only on finger-up.
          if (travel.dy.abs() > travel.dx.abs() * 1.4 && travel.dy.abs() > 18) {
            _screenScrollDistance += d.delta.dy;
            if (_screenScrollDistance.abs() >= 62) {
              final point = _screenNormalize(d.localPosition, screenSize);
              if (point != null && connected) {
                _command('screen_scroll', {
                  'x': point.dx, 'y': point.dy,
                  'dy': _screenScrollDistance < 0 ? 1 : -1,
                });
                _screenDidScroll = true;
              }
              _screenScrollDistance = 0;
            }
          }
        },
        onPanEnd: (_) => _screenSwipe(screenSize),
        child: Container(color: Colors.black, child: _videoTexture == null
          ? Center(child: Text(_screenMessage, textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, fontSize: 14)))
          : SizedBox.expand(child: FittedBox(
              fit: _videoFill ? BoxFit.cover : BoxFit.contain,
              child: SizedBox(width: _screenWidth.toDouble(),
                  height: _screenHeight.toDouble(),
                  child: Texture(textureId: _videoTexture!,
                      filterQuality: FilterQuality.low)),
          )),
        ),
      )),
      Positioned(top: 9, right: 9, child: _mouseButton(
        _screenControls ? Icons.close_rounded : Icons.tune_rounded,
        _screenControls ? 'Скрыть панель' : 'Управление',
        () => setState(() => _screenControls = !_screenControls),
      )),
      if (_screenControls) ...[
        Positioned(top: 8, left: 10, right: 65,
          child: Row(children: [
            _mouseButton(Icons.mouse_rounded, 'Мышь', () => _showPanel(_Panel.mouse)),
            const SizedBox(width: 6),
            _mouseButton(Icons.apps_rounded, 'Приложения', () => _showPanel(_Panel.apps)),
            const SizedBox(width: 6),
            _mouseButton(Icons.keyboard_rounded, 'Клавиатура', () => _showPanel(_Panel.keyboard)),
            const SizedBox(width: 6),
            _mouseButton(_videoFill ? Icons.fit_screen : Icons.fullscreen,
                _videoFill ? 'Без обрезки' : 'Заполнить экран',
                () => setState(() => _videoFill = !_videoFill)),
            const SizedBox(width: 6),
            _mouseButton(Icons.refresh_rounded, 'Переподключить видео', () async {
              await _stopVideo();
              if (mounted) { setState(() {}); unawaited(_startVideo()); }
            }),
          ])),
        Positioned(bottom: 8, left: 10, right: 10,
          child: Row(children: [
            Expanded(child: _mouseWide(Icons.arrow_back_rounded, 'Назад',
                () => _command('key', {'code': 4}))),
            const SizedBox(width: 8),
            Expanded(child: _mouseWide(Icons.home_rounded, 'Домой',
                () => _command('key', {'code': 3}))),
            const SizedBox(width: 8),
            Expanded(child: _mouseWide(Icons.keyboard_arrow_up_rounded, 'Вверх',
                () => _command('screen_swipe',
                    {'x1': .5, 'y1': .25, 'x2': .5, 'y2': .8, 'duration': 250}))),
            const SizedBox(width: 8),
            Expanded(child: _mouseWide(Icons.keyboard_arrow_down_rounded, 'Вниз',
                () => _command('screen_swipe',
                    {'x1': .5, 'y1': .8, 'x2': .5, 'y2': .25, 'duration': 250}))),
          ])),
        Positioned(bottom: 66, left: 12, right: 12,
          child: IgnorePointer(child: Center(child: Container(
            decoration: BoxDecoration(color: _panel.withValues(alpha: .92),
                borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(_screenMessage,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11)),
          )))),
      ],
    ]);
  });

  Widget _mouseButton(IconData icon, String tooltip, VoidCallback action) =>
      IconButton.filledTonal(
        tooltip: tooltip,
        onPressed: action,
        style: IconButton.styleFrom(backgroundColor: _panel.withValues(alpha: .9),
          foregroundColor: _cyan,
          side: const BorderSide(color: _line),
          minimumSize: const Size(43, 43)),
        icon: Icon(icon, size: 21),
      );

  Widget _mouseWide(IconData icon, String name, VoidCallback action) =>
      SizedBox(height: 48, child: OutlinedButton.icon(
        onPressed: action,
        style: OutlinedButton.styleFrom(
          backgroundColor: _panel.withValues(alpha: .9),
          foregroundColor: Colors.white,
          side: const BorderSide(color: _line),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        icon: Icon(icon, size: 18),
        label: Text(name, style: const TextStyle(fontSize: 11)),
      ));

  Widget _pairPage() => ListView(padding: const EdgeInsets.all(15), children: [
    const Text('Подключение компонента на приставке',
      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 19)),
    const SizedBox(height: 9),
    const Text('Установи Pult-TV.apk на X96, включи службу управления и нажми на телевизоре «Показать код на 2 минуты».',
      style: TextStyle(color: _muted, height: 1.4)),
    const SizedBox(height: 15),
    if (pendingFingerprint != null) ...[
      const Text('Отпечаток SHA-256:', style: TextStyle(color: Colors.white)),
      const SizedBox(height: 9),
      SelectableText(pendingFingerprint!.replaceAllMapped(RegExp(r'.{2}'), (m) => '${m.group(0)}:')
          .replaceFirst(RegExp(r':$'), ''),
          style: const TextStyle(color: _cyan, fontSize: 13)),
      const SizedBox(height: 12),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Отпечаток полностью совпадает с экраном телевизора',
          style: TextStyle(color: Colors.white, fontSize: 13)),
        value: confirmed,
        onChanged: (v) => setState(() => confirmed = v ?? false),
        activeColor: _cyan,
        controlAffinity: ListTileControlAffinity.leading,
      ),
      TextField(controller: pin,
        style: const TextStyle(color: Colors.white, fontSize: 20),
        keyboardType: TextInputType.number, maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(labelText: 'Код с экрана X96',
          labelStyle: TextStyle(color: _muted))),
      const SizedBox(height: 6),
      FilledButton(onPressed: busy || !confirmed ? null : _pair,
        child: const Text('Сопрячь и сохранить')),
    ],
    const SizedBox(height: 10),
    OutlinedButton(onPressed: busy ? null : () async {
      setState(() => busy = true);
      try { await _probe(); }
      catch (e) { if (mounted) setState(() => status = '$e'); }
      finally { if (mounted) setState(() => busy = false); }
    }, child: const Text('Проверить соединение ещё раз')),
    OutlinedButton(onPressed: busy ? null : _forget,
        child: const Text('Сбросить старое сопряжение')),
  ]);

  Widget _appsPage() => Column(children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Expanded(child: Text('Установлено: ${apps.length}',
          style: const TextStyle(color: _muted))),
        TextButton.icon(onPressed: _loadApps,
          icon: const Icon(Icons.refresh), label: const Text('Обновить')),
      ])),
    if (loadingApps) const LinearProgressIndicator(minHeight: 2, color: _cyan),
    Expanded(child: apps.isEmpty
      ? Center(child: FilledButton.icon(onPressed: _loadApps,
          icon: const Icon(Icons.grid_view_rounded),
          label: const Text('Загрузить приложения с X96')))
      : GridView.builder(
        padding: const EdgeInsets.all(12), itemCount: apps.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, mainAxisSpacing: 9, crossAxisSpacing: 9, childAspectRatio: .82),
        itemBuilder: (_, i) {
          final a = apps[i];
          return InkWell(onTap: () => _command('launch', {'package': a.packageName}),
            child: _tile(Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (a.icon != null) Image.memory(a.icon!, width: 48, height: 48,
                errorBuilder: (_, _, _) => const Icon(Icons.apps_rounded, color: _cyan, size: 42))
              else const Icon(Icons.apps_rounded, color: _cyan, size: 42),
              const SizedBox(height: 10),
              Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold,
                  fontSize: 12)),
            ])),
          );
        },
      )),
  ]);

  Widget _keyboardPage() => ListView(padding: const EdgeInsets.all(15), children: [
    const Text('Открой поле ввода на приставке. Для всех полей выбери системную клавиатуру «Пульт · ввод с телефона».',
        style: TextStyle(color: _muted, height: 1.5)),
    const SizedBox(height: 15),
    TextField(controller: input, minLines: 2, maxLines: 5,
      style: const TextStyle(color: Colors.white),
      decoration: const InputDecoration(labelText: 'Текст для телевизора',
        labelStyle: TextStyle(color: _muted), border: OutlineInputBorder())),
    const SizedBox(height: 10),
    FilledButton.icon(onPressed: () async {
      if (input.text.isEmpty) return;
      final result = await _send({'cmd': 'text', 'text': input.text});
      if (result != null && mounted) input.clear();
    }, icon: const Icon(Icons.send_rounded), label: const Text('Отправить текст')),
    const SizedBox(height: 10),
    OutlinedButton.icon(onPressed: () => _command('delete'),
      icon: const Icon(Icons.backspace_outlined),
      label: const Text('Удалить символ на приставке')),
  ]);

  Widget _settingsPage() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('Настройки курсора',
      style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    Text('Чувствительность · ${sensitivity.toStringAsFixed(1)}',
      style: const TextStyle(color: _muted)),
    Slider(value: sensitivity, min: .6, max: 4.0,
      activeColor: _cyan,
      onChanged: (v) => setState(() => sensitivity = v),
      onChangeEnd: (v) => unawaited(_vault.write(
        key: '${_pref}speed', value: v.toString()))),
    SwitchListTile.adaptive(
      title: const Text('Ускорение курсора', style: TextStyle(color: Colors.white)),
      subtitle: const Text('Быстрое движение пальца — быстрее курсор',
        style: TextStyle(color: _muted, fontSize: 12)),
      value: _accelerate, onChanged: (v) {
        setState(() => _accelerate = v);
        unawaited(_vault.write(key: '${_pref}accel', value: '$v'));
      }),
    SwitchListTile.adaptive(
      title: const Text('Вибрация при нажатиях', style: TextStyle(color: Colors.white)),
      value: _haptics, onChanged: (v) {
        setState(() => _haptics = v);
        unawaited(_vault.write(key: '${_pref}haptics', value: '$v'));
      }),
    const Divider(),
    const Text('Управление: один палец — движение; короткое касание — клик; два быстрых касания — двойной клик; удержание — зажатие для перетаскивания; два пальца — прокрутка.',
      style: TextStyle(color: _muted, height: 1.5)),
    const SizedBox(height: 18),
    OutlinedButton.icon(onPressed: () => unawaited(_checkLink()),
      icon: const Icon(Icons.refresh_rounded), label: const Text('Проверить соединение')),
    OutlinedButton.icon(onPressed: _forget,
      icon: const Icon(Icons.link_off_rounded), label: const Text('Забыть приставку')),
  ]);

  Widget _tile(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: _panel,
      borderRadius: BorderRadius.circular(18), border: Border.all(color: _line)),
    child: child,
  );
}

class _TvApp {
  const _TvApp(this.name, this.packageName, this.icon);
  final String name;
  final String packageName;
  final Uint8List? icon;

  factory _TvApp.fromJson(Map<String, dynamic> data) {
    Uint8List? icon;
    try {
      final encoded = data['icon'];
      if (encoded is String && encoded.isNotEmpty) icon = base64Decode(encoded);
    } catch (_) {}
    return _TvApp('${data['name'] ?? 'Приложение'}',
      '${data['package'] ?? ''}', icon);
  }
}
