import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _bg = Color(0xFF05090E);
const _panel = Color(0xFF0B1620);
const _panel2 = Color(0xFF0E2130);
const _line = Color(0xFF194B6B);
const _cyan = Color(0xFF29C7FF);
const _cyan2 = Color(0xFF087DFF);
const _text = Color(0xFFF6FAFF);
const _muted = Color(0xFF8EA7BA);
const _good = Color(0xFF21E58B);

class _Key {
  static const home = 3;
  static const back = 4;
  static const up = 19;
  static const down = 20;
  static const left = 21;
  static const right = 22;
  static const ok = 23;
  static const volumeUp = 24;
  static const volumeDown = 25;
  static const power = 26;
  static const menu = 82;
  static const playPause = 85;
  static const next = 87;
  static const previous = 88;
  static const mute = 164;
  static const settings = 176;
  static const sleep = 223;
}

class ConnectedShell extends StatefulWidget {
  const ConnectedShell({
    super.key,
    required this.name,
    required this.onKey,
    required this.onStartRepeat,
    required this.onStopRepeat,
    required this.onForget,
    required this.onLaunchApp,
    required this.onSendText,
  });

  final String name;
  final ValueChanged<int> onKey;
  final ValueChanged<int> onStartRepeat;
  final VoidCallback onStopRepeat;
  final VoidCallback onForget;
  final bool Function(String appLink) onLaunchApp;
  final bool Function(String text) onSendText;

  @override
  State<ConnectedShell> createState() => _ConnectedShellState();
}

class _ConnectedShellState extends State<ConnectedShell> {
  int _tab = 0;
  int _remoteMode = 0;
  bool _haptics = true;
  double _mouseSensitivity = 0.55;

  void _tap(int key) {
    if (_haptics) HapticFeedback.selectionClick();
    widget.onKey(key);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF0B1A26),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _line),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF06111B), _bg],
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: _Header(
              name: widget.name,
              onPower: () => _tap(_Key.power),
              onForget: widget.onForget,
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _RemotePage(
                  mode: _remoteMode,
                  onMode: (v) => setState(() => _remoteMode = v),
                  onKey: _tap,
                  onStartRepeat: widget.onStartRepeat,
                  onStopRepeat: widget.onStopRepeat,
                  mouseSensitivity: _mouseSensitivity,
                ),
                _AppsPage(
                  onLaunch: (target) {
                    final ok = widget.onLaunchApp(target.link);
                    _toast(
                      ok
                          ? 'Открываю ${target.title} на X96'
                          : 'Прямой запуск недоступен на этой прошивке',
                    );
                  },
                ),
                _KeyboardPage(
                  onSend: (text) {
                    final ok = widget.onSendText(text);
                    _toast(
                      ok
                          ? 'Текст отправлен на X96'
                          : 'Открой поле ввода на телевизоре и попробуй ещё раз',
                    );
                  },
                ),
                _MacrosPage(
                  onKey: _tap,
                  onLaunch: widget.onLaunchApp,
                  toast: _toast,
                ),
                _SettingsPage(
                  haptics: _haptics,
                  sensitivity: _mouseSensitivity,
                  onHaptics: (v) => setState(() => _haptics = v),
                  onSensitivity: (v) => setState(() => _mouseSensitivity = v),
                  onReconnect: widget.onForget,
                ),
              ],
            ),
          ),
          _BottomBar(
            index: _tab,
            onChanged: (v) {
              if (_haptics) HapticFeedback.selectionClick();
              setState(() => _tab = v);
            },
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.onPower,
    required this.onForget,
  });

  final String name;
  final VoidCallback onPower;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            const _Logo(),
            const Spacer(),
            IconButton(
              onPressed: () {},
              icon: const Icon(Icons.settings_outlined, color: _cyan),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 72,
          padding: const EdgeInsets.fromLTRB(14, 8, 7, 8),
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _line),
            boxShadow: const [
              BoxShadow(color: Color(0x2200B7FF), blurRadius: 22),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF10161D), Color(0xFF07131D)],
                  ),
                  border: Border.all(color: const Color(0xFF245978)),
                ),
                child: const Center(
                  child: Text('X96', style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(width: 12),
              const SizedBox(width: 10, height: 10, child: DecoratedBox(
                decoration: BoxDecoration(color: _good, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x7721E58B), blurRadius: 12)]),
              )),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _text, fontSize: 15, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    const Row(children: [
                      Icon(Icons.wifi_rounded, color: _muted, size: 14),
                      SizedBox(width: 5),
                      Text('Подключено по Wi‑Fi', style: TextStyle(color: _muted, fontSize: 11)),
                    ]),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                color: _panel2,
                icon: const Icon(Icons.more_vert_rounded, color: _muted),
                onSelected: (v) { if (v == 'forget') onForget(); },
                itemBuilder: (_) => const [PopupMenuItem(value: 'forget', child: Text('Переподключить'))],
              ),
              IconButton(
                onPressed: onPower,
                icon: const Icon(Icons.power_settings_new_rounded, color: Color(0xFFFF6474), size: 27),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Text('X96', style: TextStyle(color: _cyan, fontSize: 23, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, letterSpacing: -1)),
      SizedBox(width: 5),
      Text('Remote', style: TextStyle(color: _text, fontSize: 19, fontWeight: FontWeight.w600, fontStyle: FontStyle.italic)),
    ],
  );
}

class _RemotePage extends StatelessWidget {
  const _RemotePage({
    required this.mode,
    required this.onMode,
    required this.onKey,
    required this.onStartRepeat,
    required this.onStopRepeat,
    required this.mouseSensitivity,
  });

  final int mode;
  final ValueChanged<int> onMode;
  final ValueChanged<int> onKey;
  final ValueChanged<int> onStartRepeat;
  final VoidCallback onStopRepeat;
  final double mouseSensitivity;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        children: [
          _Segmented(
            labels: const ['Кнопки', 'Тачпад', 'Мышь'],
            index: mode,
            onChanged: onMode,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: switch (mode) {
                0 => _DPad(onKey: onKey),
                1 => _Touchpad(onKey: onKey),
                _ => _MousePad(onKey: onKey, sensitivity: mouseSensitivity),
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _SoftButton(icon: Icons.arrow_back_rounded, label: 'Назад', onTap: () => onKey(_Key.back))),
              const SizedBox(width: 8),
              Expanded(child: _SoftButton(icon: Icons.home_rounded, label: 'Домой', onTap: () => onKey(_Key.home))),
              const SizedBox(width: 8),
              Expanded(child: _SoftButton(icon: Icons.menu_rounded, label: 'Меню', onTap: () => onKey(_Key.menu))),
            ],
          ),
          const SizedBox(height: 8),
          _MediaRow(onKey: onKey),
          const SizedBox(height: 8),
          _VolumeRow(onKey: onKey, onStartRepeat: onStartRepeat, onStopRepeat: onStopRepeat),
        ],
      ),
    );
  }
}

class _DPad extends StatelessWidget {
  const _DPad({required this.onKey});
  final ValueChanged<int> onKey;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, c) {
      final size = math.min(c.maxWidth, math.min(c.maxHeight, 330.0));
      return Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(colors: [Color(0xFF0B2A42), Color(0xFF071019)]),
              border: Border.all(color: const Color(0xFF2376A9)),
              boxShadow: const [BoxShadow(color: Color(0x3300BFFF), blurRadius: 32)],
            ),
            child: Stack(children: [
              _Dir(align: Alignment.topCenter, icon: Icons.keyboard_arrow_up_rounded, onTap: () => onKey(_Key.up)),
              _Dir(align: Alignment.bottomCenter, icon: Icons.keyboard_arrow_down_rounded, onTap: () => onKey(_Key.down)),
              _Dir(align: Alignment.centerLeft, icon: Icons.keyboard_arrow_left_rounded, onTap: () => onKey(_Key.left)),
              _Dir(align: Alignment.centerRight, icon: Icons.keyboard_arrow_right_rounded, onTap: () => onKey(_Key.right)),
              Center(
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => onKey(_Key.ok),
                  child: Container(
                    width: size * .34,
                    height: size * .34,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF08243A), border: Border.all(color: _cyan, width: 1.4), boxShadow: const [BoxShadow(color: Color(0x7700BFFF), blurRadius: 26)]),
                    alignment: Alignment.center,
                    child: const Text('OK', style: TextStyle(color: _text, fontSize: 19, fontWeight: FontWeight.w900)),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    },
  );
}

class _Dir extends StatelessWidget {
  const _Dir({required this.align, required this.icon, required this.onTap});
  final Alignment align;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Align(
    alignment: align,
    child: InkResponse(
      onTap: onTap,
      radius: 54,
      child: SizedBox(width: 90, height: 90, child: Icon(icon, color: _text, size: 35)),
    ),
  );
}

class _Touchpad extends StatefulWidget {
  const _Touchpad({required this.onKey});
  final ValueChanged<int> onKey;
  @override
  State<_Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<_Touchpad> {
  Offset _move = Offset.zero;
  double _scroll = 0;

  void _nav(DragUpdateDetails d) {
    _move += d.delta;
    const t = 30.0;
    if (_move.dx.abs() > _move.dy.abs()) {
      if (_move.dx > t) { widget.onKey(_Key.right); _move = Offset(_move.dx - t, _move.dy); }
      if (_move.dx < -t) { widget.onKey(_Key.left); _move = Offset(_move.dx + t, _move.dy); }
    } else {
      if (_move.dy > t) { widget.onKey(_Key.down); _move = Offset(_move.dx, _move.dy - t); }
      if (_move.dy < -t) { widget.onKey(_Key.up); _move = Offset(_move.dx, _move.dy + t); }
    }
  }

  void _wheel(DragUpdateDetails d) {
    _scroll += d.delta.dy;
    const step = 18.0;
    while (_scroll > step) { widget.onKey(_Key.down); _scroll -= step; HapticFeedback.selectionClick(); }
    while (_scroll < -step) { widget.onKey(_Key.up); _scroll += step; HapticFeedback.selectionClick(); }
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: GestureDetector(
          onTap: () => widget.onKey(_Key.ok),
          onPanStart: (_) => _move = Offset.zero,
          onPanUpdate: _nav,
          child: _PadSurface(
            child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.touch_app_rounded, color: _cyan, size: 36),
              SizedBox(height: 14),
              Text('Проведите пальцем', style: TextStyle(color: _text, fontWeight: FontWeight.w800)),
              SizedBox(height: 5),
              Text('Навигация • Нажатие — OK', style: TextStyle(color: _muted, fontSize: 12)),
            ]),
          ),
        ),
      ),
      const SizedBox(width: 9),
      GestureDetector(
        onPanStart: (_) => _scroll = 0,
        onPanUpdate: _wheel,
        child: Container(
          width: 62,
          decoration: BoxDecoration(
            color: const Color(0xFF082033),
            borderRadius: BorderRadius.circular(25),
            border: Border.all(color: const Color(0xFF2588BD)),
            boxShadow: const [BoxShadow(color: Color(0x3300BFFF), blurRadius: 20)],
          ),
          child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.keyboard_arrow_up_rounded, color: _cyan, size: 28),
            SizedBox(height: 12),
            Icon(Icons.mouse_rounded, color: _cyan, size: 24),
            SizedBox(height: 12),
            Text('СКРОЛЛ', style: TextStyle(color: _muted, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1)),
            SizedBox(height: 12),
            Icon(Icons.keyboard_arrow_down_rounded, color: _cyan, size: 28),
          ]),
        ),
      ),
    ],
  );
}

class _MousePad extends StatefulWidget {
  const _MousePad({required this.onKey, required this.sensitivity});
  final ValueChanged<int> onKey;
  final double sensitivity;
  @override
  State<_MousePad> createState() => _MousePadState();
}

class _MousePadState extends State<_MousePad> {
  Offset _move = Offset.zero;
  @override
  Widget build(BuildContext context) {
    final threshold = 24.0 + (1 - widget.sensitivity) * 28.0;
    return GestureDetector(
      onTap: () => widget.onKey(_Key.ok),
      onPanStart: (_) => _move = Offset.zero,
      onPanUpdate: (d) {
        _move += d.delta;
        if (_move.dx.abs() > _move.dy.abs()) {
          if (_move.dx > threshold) { widget.onKey(_Key.right); _move = Offset.zero; }
          if (_move.dx < -threshold) { widget.onKey(_Key.left); _move = Offset.zero; }
        } else {
          if (_move.dy > threshold) { widget.onKey(_Key.down); _move = Offset.zero; }
          if (_move.dy < -threshold) { widget.onKey(_Key.up); _move = Offset.zero; }
        }
      },
      child: _PadSurface(
        child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.mouse_rounded, color: _cyan, size: 47),
          SizedBox(height: 14),
          Text('Мышь — эксперимент', style: TextStyle(color: _text, fontWeight: FontWeight.w900, fontSize: 15)),
          SizedBox(height: 6),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('Пока движение преобразуется в навигацию X96. Настоящий системный курсор зависит от прошивки.', textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 11, height: 1.4)),
          ),
        ]),
      ),
    );
  }
}

class _PadSurface extends StatelessWidget {
  const _PadSurface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF09243A), Color(0xFF06131E)]),
      border: Border.all(color: const Color(0xFF2588BD)),
      boxShadow: const [BoxShadow(color: Color(0x2600BFFF), blurRadius: 26)],
    ),
    child: child,
  );
}

class _AppsPage extends StatelessWidget {
  const _AppsPage({required this.onLaunch});
  final ValueChanged<_AppTarget> onLaunch;

  static const apps = <_AppTarget>[
    _AppTarget('YouTube', Icons.play_circle_fill_rounded, 'https://www.youtube.com/tv'),
    _AppTarget('Браузер', Icons.language_rounded, 'https://www.google.com/'),
    _AppTarget('Netflix', Icons.movie_creation_outlined, 'https://www.netflix.com/'),
    _AppTarget('Prime Video', Icons.ondemand_video_rounded, 'https://www.primevideo.com/'),
    _AppTarget('KION', Icons.live_tv_rounded, 'https://kion.ru/'),
    _AppTarget('Google Play', Icons.shop_rounded, 'market://details'),
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Приложения', style: TextStyle(color: _text, fontSize: 21, fontWeight: FontWeight.w900)),
      const SizedBox(height: 5),
      const Text('Нажатие отправляет X96 прямую ссылку. Если приложение зарегистрировало её, оно откроется поверх текущего.', style: TextStyle(color: _muted, fontSize: 11, height: 1.4)),
      const SizedBox(height: 14),
      Expanded(
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: .92),
          itemCount: apps.length,
          itemBuilder: (_, i) => _AppTile(target: apps[i], onTap: () => onLaunch(apps[i])),
        ),
      ),
    ]),
  );
}

class _AppTarget {
  const _AppTarget(this.title, this.icon, this.link);
  final String title;
  final IconData icon;
  final String link;
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.target, required this.onTap});
  final _AppTarget target;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: _panel,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: _line)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(target.icon, color: _cyan, size: 34),
          const SizedBox(height: 10),
          Text(target.title, textAlign: TextAlign.center, style: const TextStyle(color: _text, fontSize: 12, fontWeight: FontWeight.w800)),
        ]),
      ),
    ),
  );
}

class _KeyboardPage extends StatefulWidget {
  const _KeyboardPage({required this.onSend});
  final ValueChanged<String> onSend;
  @override
  State<_KeyboardPage> createState() => _KeyboardPageState();
}

class _KeyboardPageState extends State<_KeyboardPage> {
  final c = TextEditingController();
  @override
  void dispose() { c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Клавиатура', style: TextStyle(color: _text, fontSize: 21, fontWeight: FontWeight.w900)),
      const SizedBox(height: 6),
      const Text('Сначала поставь курсор в поле ввода на телевизоре, затем отправь текст.', style: TextStyle(color: _muted, fontSize: 11)),
      const SizedBox(height: 16),
      TextField(
        controller: c,
        minLines: 2,
        maxLines: 5,
        autofocus: false,
        style: const TextStyle(color: _text, fontSize: 16),
        decoration: InputDecoration(
          hintText: 'Введите текст для X96…',
          hintStyle: const TextStyle(color: _muted),
          filled: true,
          fillColor: _panel,
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: _line)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: _cyan)),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton.icon(
          onPressed: () => widget.onSend(c.text),
          style: FilledButton.styleFrom(backgroundColor: _cyan2, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          icon: const Icon(Icons.send_rounded),
          label: const Text('Отправить на телевизор', style: TextStyle(fontWeight: FontWeight.w900)),
        ),
      ),
      const SizedBox(height: 16),
      const Text('Быстрый ввод', style: TextStyle(color: _text, fontWeight: FontWeight.w800)),
      const SizedBox(height: 9),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in ['https://', '.com', '@gmail.com', 'YouTube'])
          ActionChip(
            label: Text(t),
            onPressed: () { c.text += t; c.selection = TextSelection.collapsed(offset: c.text.length); },
            side: const BorderSide(color: _line),
            backgroundColor: _panel,
            labelStyle: const TextStyle(color: _muted),
          ),
      ]),
    ]),
  );
}

class _MacrosPage extends StatelessWidget {
  const _MacrosPage({required this.onKey, required this.onLaunch, required this.toast});
  final ValueChanged<int> onKey;
  final bool Function(String) onLaunch;
  final ValueChanged<String> toast;

  Future<void> _night() async {
    onKey(_Key.home);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    onKey(_Key.sleep);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Макросы', style: TextStyle(color: _text, fontSize: 21, fontWeight: FontWeight.w900)),
      const SizedBox(height: 12),
      _Macro(icon: Icons.play_circle_fill_rounded, title: 'YouTube', subtitle: 'Открыть одним нажатием', onTap: () { final ok = onLaunch('https://www.youtube.com/tv'); toast(ok ? 'Открываю YouTube' : 'Прямой запуск недоступен'); }),
      _Macro(icon: Icons.nightlight_round, title: 'Спокойной ночи', subtitle: 'Домой → сон', onTap: _night),
      _Macro(icon: Icons.settings_rounded, title: 'Настройки X96', subtitle: 'Открыть системные настройки', onTap: () => onKey(_Key.settings)),
      _Macro(icon: Icons.home_rounded, title: 'На главный экран', subtitle: 'Мгновенно вернуться домой', onTap: () => onKey(_Key.home)),
    ]),
  );
}

class _Macro extends StatelessWidget {
  const _Macro({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon; final String title; final String subtitle; final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: _panel,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 70,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: _line)),
          child: Row(children: [
            Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0xFF0A2C43), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: _cyan)),
            const SizedBox(width: 12),
            Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: _text, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(subtitle, style: const TextStyle(color: _muted, fontSize: 11)),
            ])),
            const Icon(Icons.chevron_right_rounded, color: _muted),
          ]),
        ),
      ),
    ),
  );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.haptics, required this.sensitivity, required this.onHaptics, required this.onSensitivity, required this.onReconnect});
  final bool haptics; final double sensitivity; final ValueChanged<bool> onHaptics; final ValueChanged<double> onSensitivity; final VoidCallback onReconnect;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
    children: [
      const Text('Настройки', style: TextStyle(color: _text, fontSize: 21, fontWeight: FontWeight.w900)),
      const SizedBox(height: 12),
      _SettingTile(icon: Icons.vibration_rounded, title: 'Виброотклик', trailing: Switch(value: haptics, onChanged: onHaptics)),
      const SizedBox(height: 9),
      Container(
        padding: const EdgeInsets.fromLTRB(15, 13, 15, 8),
        decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(18), border: Border.all(color: _line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [Icon(Icons.mouse_rounded, color: _cyan), SizedBox(width: 10), Text('Чувствительность мыши', style: TextStyle(color: _text, fontWeight: FontWeight.w800))]),
          Slider(value: sensitivity, onChanged: onSensitivity, activeColor: _cyan, inactiveColor: _line),
        ]),
      ),
      const SizedBox(height: 9),
      _SettingTile(icon: Icons.sync_rounded, title: 'Переподключиться', onTap: onReconnect),
      const SizedBox(height: 9),
      const _SettingTile(icon: Icons.info_outline_rounded, title: 'X96 Remote', subtitle: 'Локальное управление • без облака'),
    ],
  );
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({required this.icon, required this.title, this.subtitle, this.trailing, this.onTap});
  final IconData icon; final String title; final String? subtitle; final Widget? trailing; final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: _panel,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        constraints: const BoxConstraints(minHeight: 62),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: _line)),
        child: Row(children: [
          Icon(icon, color: _cyan),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(title, style: const TextStyle(color: _text, fontWeight: FontWeight.w800)),
            if (subtitle != null) ...[const SizedBox(height: 3), Text(subtitle!, style: const TextStyle(color: _muted, fontSize: 11))],
          ])),
          trailing ?? const Icon(Icons.chevron_right_rounded, color: _muted),
        ]),
      ),
    ),
  );
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.labels, required this.index, required this.onChanged});
  final List<String> labels; final int index; final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
    height: 44,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: const Color(0xFF07131D), borderRadius: BorderRadius.circular(15), border: Border.all(color: _line)),
    child: Row(children: [
      for (var i = 0; i < labels.length; i++) Expanded(
        child: InkWell(
          onTap: () => onChanged(i),
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: i == index ? const LinearGradient(colors: [Color(0xFF075D93), Color(0xFF0A9DDF)]) : null,
              boxShadow: i == index ? const [BoxShadow(color: Color(0x6600BFFF), blurRadius: 14)] : null,
            ),
            child: Text(labels[i], style: TextStyle(color: i == index ? _text : _muted, fontSize: 12, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    ]),
  );
}

class _SoftButton extends StatelessWidget {
  const _SoftButton({required this.icon, required this.label, required this.onTap});
  final IconData icon; final String label; final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: _panel,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 50,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: _line)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: _text, size: 20), const SizedBox(height: 3), Text(label, style: const TextStyle(color: _muted, fontSize: 10, fontWeight: FontWeight.w700))]),
      ),
    ),
  );
}

class _MediaRow extends StatelessWidget {
  const _MediaRow({required this.onKey}); final ValueChanged<int> onKey;
  @override
  Widget build(BuildContext context) => _Bar(children: [
    IconButton(onPressed: () => onKey(_Key.previous), icon: const Icon(Icons.skip_previous_rounded, color: _text)),
    IconButton(onPressed: () => onKey(_Key.playPause), icon: const Icon(Icons.play_arrow_rounded, color: _cyan, size: 28)),
    IconButton(onPressed: () => onKey(_Key.next), icon: const Icon(Icons.skip_next_rounded, color: _text)),
  ]);
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({required this.onKey, required this.onStartRepeat, required this.onStopRepeat});
  final ValueChanged<int> onKey; final ValueChanged<int> onStartRepeat; final VoidCallback onStopRepeat;
  @override
  Widget build(BuildContext context) => _Bar(children: [
    _RepeatButton(icon: Icons.volume_down_rounded, tap: () => onKey(_Key.volumeDown), start: () => onStartRepeat(_Key.volumeDown), stop: onStopRepeat),
    IconButton(onPressed: () => onKey(_Key.mute), icon: const Icon(Icons.volume_off_rounded, color: _text)),
    _RepeatButton(icon: Icons.volume_up_rounded, tap: () => onKey(_Key.volumeUp), start: () => onStartRepeat(_Key.volumeUp), stop: onStopRepeat),
  ]);
}

class _RepeatButton extends StatelessWidget {
  const _RepeatButton({required this.icon, required this.tap, required this.start, required this.stop});
  final IconData icon; final VoidCallback tap; final VoidCallback start; final VoidCallback stop;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: tap,
    onLongPressStart: (_) => start(),
    onLongPressEnd: (_) => stop(),
    child: SizedBox(width: 56, height: 48, child: Icon(icon, color: _text)),
  );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.children}); final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
    height: 50,
    decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: _line)),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: children),
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onChanged});
  final int index; final ValueChanged<int> onChanged;
  static const items = [
    (Icons.settings_remote_rounded, 'Пульт'),
    (Icons.grid_view_rounded, 'Приложения'),
    (Icons.keyboard_rounded, 'Клавиатура'),
    (Icons.auto_awesome_motion_rounded, 'Макросы'),
    (Icons.settings_rounded, 'Настройки'),
  ];
  @override
  Widget build(BuildContext context) => Container(
    height: 67,
    padding: const EdgeInsets.fromLTRB(4, 5, 4, 8),
    decoration: const BoxDecoration(color: Color(0xFF06101A), border: Border(top: BorderSide(color: Color(0xFF123650)))),
    child: Row(children: [
      for (var i = 0; i < items.length; i++) Expanded(
        child: InkWell(
          onTap: () => onChanged(i),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(items[i].$1, color: i == index ? _cyan : _muted, size: 21),
            const SizedBox(height: 4),
            Text(items[i].$2, maxLines: 1, overflow: TextOverflow.fade, style: TextStyle(color: i == index ? _cyan : _muted, fontSize: 8.5, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    ]),
  );
}
