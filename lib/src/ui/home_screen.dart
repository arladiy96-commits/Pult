import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/remote_device.dart';
import '../state/remote_controller.dart';
import '../state/remote_state.dart';

const _bg = Color(0xFF07090D);
const _panel = Color(0xFF11161E);
const _panel2 = Color(0xFF171E28);
const _line = Color(0xFF27313D);
const _accent = Color(0xFF79C7FF);
const _accent2 = Color(0xFF9C8CFF);
const _text = Color(0xFFF4F7FA);
const _muted = Color(0xFF8996A6);
const _good = Color(0xFF68E6B2);

class AndroidKey {
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
  static const previous = 88;
  static const next = 87;
  static const mute = 164;
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(remoteControllerProvider);
    final controller =
        ref.read(remoteControllerProvider.notifier);

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (state) {
            Scanning() => _ScanningScreen(
                key: const ValueKey('scan'),
                state: state,
                onConnect: controller.connect,
                onRefresh: controller.scan,
                onManual: controller.connectManual,
              ),
            Connecting() => _ConnectingScreen(
                key: const ValueKey('connecting'),
                name: state.device.name,
              ),
            PairingRequired() => _PairingScreen(
                key: const ValueKey('pairing'),
                state: state,
                onSubmit: controller.submitPin,
                onCancel: controller.scan,
              ),
            Connected() => _RemoteScreen(
                key: const ValueKey('remote'),
                name: state.device.name,
                onKey: controller.sendKey,
                onStartRepeat: controller.startRepeat,
                onStopRepeat: controller.stopRepeat,
                onForget: controller.forgetAndScan,
              ),
            Disconnected() => _ErrorScreen(
                key: const ValueKey('error'),
                message: state.reason,
                onRetry: controller.scan,
              ),
          },
        ),
      ),
    );
  }
}


class _ScanningScreen extends StatefulWidget {
  const _ScanningScreen({
    super.key,
    required this.state,
    required this.onConnect,
    required this.onRefresh,
    required this.onManual,
  });

  final Scanning state;
  final Future<void> Function(RemoteDevice) onConnect;
  final VoidCallback onRefresh;
  final Future<void> Function(String) onManual;

  @override
  State<_ScanningScreen> createState() => _ScanningScreenState();
}

class _ScanningScreenState extends State<_ScanningScreen> {
  final _ipController = TextEditingController();
  bool _manualOpen = false;

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TopBar(
            trailing: IconButton(
              onPressed: widget.onRefresh,
              color: _muted,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
          const SizedBox(height: 38),
          const Text(
            'Твой X96',
            style: TextStyle(
              color: _text,
              fontSize: 34,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.2,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Ищу приставку в домашней Wi‑Fi сети. '
            'На X96 ничего устанавливать не нужно.',
            style: TextStyle(
              color: _muted,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          if (widget.state.devices.isEmpty)
            const _SearchingCard()
          else
            ...widget.state.devices.map(
              (device) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _DeviceCard(
                  name: device.name,
                  host: device.host,
                  onTap: () => widget.onConnect(device),
                ),
              ),
            ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () {
              setState(() => _manualOpen = !_manualOpen);
            },
            icon: const Icon(Icons.router_rounded, size: 19),
            label: const Text('Подключить по IP'),
            style: TextButton.styleFrom(
              foregroundColor: _muted,
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _manualOpen
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ipController,
                      keyboardType:
                          const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: const TextStyle(color: _text),
                      decoration: InputDecoration(
                        hintText: '192.168.1.120',
                        hintStyle: const TextStyle(color: _muted),
                        filled: true,
                        fillColor: _panel,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 15,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: _line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: _accent),
                        ),
                      ),
                      onSubmitted: widget.onManual,
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    onPressed: () =>
                        widget.onManual(_ipController.text),
                    icon: const Icon(
                      Icons.arrow_forward_rounded,
                    ),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(54, 54),
                      backgroundColor: _accent,
                      foregroundColor: _bg,
                    ),
                  ),
                ],
              ),
            ),
            secondChild: const SizedBox.shrink(),
          ),
          const Spacer(),
          const _Footer(),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    this.trailing,
  });

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              colors: [_accent, _accent2],
            ),
          ),
          child: const Icon(
            Icons.sensors_rounded,
            color: _bg,
            size: 21,
          ),
        ),
        const SizedBox(width: 11),
        const Text(
          'X96 REMOTE',
          style: TextStyle(
            color: _text,
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.8,
          ),
        ),
        const Spacer(),
        trailing ?? const SizedBox.shrink(),
      ],
    );
  }
}

class _SearchingCard extends StatelessWidget {
  const _SearchingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 82,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _line),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 27,
            height: 27,
            child: CircularProgressIndicator(
              strokeWidth: 2.3,
              color: _accent,
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              'Поиск Android TV Remote Service…',
              style: TextStyle(
                color: _text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.name,
    required this.host,
    required this.onTap,
  });

  final String name;
  final String host;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _accent.withValues(alpha: 0.32),
            ),
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: 0.05),
                blurRadius: 28,
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: _panel2,
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(color: _line),
                ),
                child: const Icon(
                  Icons.tv_rounded,
                  color: _accent,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _text,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      host,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                color: _muted,
                size: 17,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectingScreen extends StatelessWidget {
  const _ConnectingScreen({
    super.key,
    required this.name,
  });

  final String name;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 42,
              height: 42,
              child: CircularProgressIndicator(
                color: _accent,
                strokeWidth: 2.5,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              'Подключаюсь к $name',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _text,
                fontSize: 21,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PairingScreen extends StatefulWidget {
  const _PairingScreen({
    super.key,
    required this.state,
    required this.onSubmit,
    required this.onCancel,
  });

  final PairingRequired state;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  @override
  State<_PairingScreen> createState() =>
      _PairingScreenState();
}

class _PairingScreenState extends State<_PairingScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _TopBar(),
          const SizedBox(height: 48),
          const Text(
            'Код с телевизора',
            style: TextStyle(
              color: _text,
              fontSize: 31,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.9,
            ),
          ),
          const SizedBox(height: 11),
          Text(
            'На ${widget.state.device.name} должен появиться '
            '${widget.state.pinLength}‑символьный Android TV Pairing код.',
            style: const TextStyle(
              color: _muted,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 30),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                RegExp('[0-9a-fA-F]'),
              ),
              LengthLimitingTextInputFormatter(widget.state.pinLength),
            ],
            style: const TextStyle(
              color: _text,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: 9,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: _panel,
              hintText: widget.state.pinLength == 4 ? 'A1B2' : 'A1B2C3',
              hintStyle: TextStyle(
                color: _muted.withValues(alpha: 0.28),
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: 9,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 20,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: const BorderSide(color: _line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide:
                    const BorderSide(color: _accent),
              ),
            ),
            onSubmitted: widget.onSubmit,
          ),
          if (widget.state.error != null) ...[
            const SizedBox(height: 12),
            Text(
              widget.state.error!,
              style: const TextStyle(
                color: Color(0xFFFF8089),
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton(
              onPressed: () {
                HapticFeedback.mediumImpact();
                widget.onSubmit(_controller.text);
              },
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: _bg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text(
                'Подключить',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: widget.onCancel,
              child: const Text(
                'Отмена',
                style: TextStyle(color: _muted),
              ),
            ),
          ),
          const Spacer(),
          const _Footer(),
        ],
      ),
    );
  }
}

class _RemoteScreen extends StatefulWidget {
  const _RemoteScreen({
    super.key,
    required this.name,
    required this.onKey,
    required this.onStartRepeat,
    required this.onStopRepeat,
    required this.onForget,
  });

  final String name;
  final ValueChanged<int> onKey;
  final ValueChanged<int> onStartRepeat;
  final VoidCallback onStopRepeat;
  final VoidCallback onForget;

  @override
  State<_RemoteScreen> createState() =>
      _RemoteScreenState();
}

class _RemoteScreenState extends State<_RemoteScreen> {
  bool _touchpad = false;

  void _tap(int key) {
    HapticFeedback.selectionClick();
    widget.onKey(key);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        children: [
          _ConnectedHeader(
            name: widget.name,
            onPower: () => _tap(AndroidKey.power),
            onForget: widget.onForget,
          ),
          const SizedBox(height: 14),
          _ModeSwitch(
            touchpad: _touchpad,
            onChanged: (value) {
              HapticFeedback.selectionClick();
              setState(() => _touchpad = value);
            },
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _touchpad
                  ? _Touchpad(
                      key: const ValueKey('touchpad'),
                      onKey: _tap,
                    )
                  : _DPad(
                      key: const ValueKey('dpad'),
                      onKey: _tap,
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.arrow_back_rounded,
                  label: 'Назад',
                  onTap: () => _tap(AndroidKey.back),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _ActionButton(
                  icon: Icons.home_rounded,
                  label: 'Домой',
                  onTap: () => _tap(AndroidKey.home),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _ActionButton(
                  icon: Icons.menu_rounded,
                  label: 'Меню',
                  onTap: () => _tap(AndroidKey.menu),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ControlBar(
            children: [
              _IconControl(
                icon: Icons.skip_previous_rounded,
                onTap: () => _tap(AndroidKey.previous),
              ),
              _IconControl(
                icon: Icons.play_arrow_rounded,
                accent: true,
                onTap: () => _tap(AndroidKey.playPause),
              ),
              _IconControl(
                icon: Icons.skip_next_rounded,
                onTap: () => _tap(AndroidKey.next),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ControlBar(
            children: [
              _RepeatIconControl(
                icon: Icons.volume_down_rounded,
                onTap: () => _tap(AndroidKey.volumeDown),
                onStart: () =>
                    widget.onStartRepeat(AndroidKey.volumeDown),
                onStop: widget.onStopRepeat,
              ),
              _IconControl(
                icon: Icons.volume_off_rounded,
                onTap: () => _tap(AndroidKey.mute),
              ),
              _RepeatIconControl(
                icon: Icons.volume_up_rounded,
                onTap: () => _tap(AndroidKey.volumeUp),
                onStart: () =>
                    widget.onStartRepeat(AndroidKey.volumeUp),
                onStop: widget.onStopRepeat,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectedHeader extends StatelessWidget {
  const _ConnectedHeader({
    required this.name,
    required this.onPower,
    required this.onForget,
  });

  final String name;
  final VoidCallback onPower;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.fromLTRB(15, 0, 8, 0),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: _good,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x5568E6B2),
                  blurRadius: 12,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Подключено по Wi‑Fi',
                  style: TextStyle(
                    color: _muted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            color: _panel2,
            icon: const Icon(
              Icons.more_horiz_rounded,
              color: _muted,
            ),
            onSelected: (value) {
              if (value == 'forget') onForget();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'forget',
                child: Text('Отвязать приставку'),
              ),
            ],
          ),
          IconButton(
            onPressed: onPower,
            icon: const Icon(
              Icons.power_settings_new_rounded,
            ),
            color: const Color(0xFFFF7C86),
          ),
        ],
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.touchpad,
    required this.onChanged,
  });

  final bool touchpad;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeButton(
              selected: !touchpad,
              icon: Icons.gamepad_outlined,
              label: 'Кнопки',
              onTap: () => onChanged(false),
            ),
          ),
          Expanded(
            child: _ModeButton(
              selected: touchpad,
              icon: Icons.touch_app_rounded,
              label: 'Тачпад',
              onTap: () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _panel2 : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 17,
              color: selected ? _accent : _muted,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: selected ? _text : _muted,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DPad extends StatelessWidget {
  const _DPad({
    super.key,
    required this.onKey,
  });

  final ValueChanged<int> onKey;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = math.min(
            constraints.maxWidth,
            math.min(constraints.maxHeight, 330.0),
          );

          return SizedBox(
            width: size,
            height: size,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  colors: [
                    Color(0xFF1A222D),
                    Color(0xFF0B0E13),
                  ],
                ),
                border: Border.all(color: _line),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.42),
                    blurRadius: 32,
                    offset: const Offset(0, 16),
                  ),
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.05),
                    blurRadius: 38,
                  ),
                ],
              ),
              child: Stack(
                children: [
                  _DirectionButton(
                    alignment: Alignment.topCenter,
                    icon: Icons.keyboard_arrow_up_rounded,
                    onTap: () => onKey(AndroidKey.up),
                  ),
                  _DirectionButton(
                    alignment: Alignment.bottomCenter,
                    icon: Icons.keyboard_arrow_down_rounded,
                    onTap: () => onKey(AndroidKey.down),
                  ),
                  _DirectionButton(
                    alignment: Alignment.centerLeft,
                    icon: Icons.keyboard_arrow_left_rounded,
                    onTap: () => onKey(AndroidKey.left),
                  ),
                  _DirectionButton(
                    alignment: Alignment.centerRight,
                    icon: Icons.keyboard_arrow_right_rounded,
                    onTap: () => onKey(AndroidKey.right),
                  ),
                  Center(
                    child: InkWell(
                      onTap: () => onKey(AndroidKey.ok),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: size * 0.34,
                        height: size * 0.34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _panel2,
                          border: Border.all(
                            color: _accent.withValues(alpha: 0.55),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _accent.withValues(alpha: 0.10),
                              blurRadius: 22,
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'OK',
                          style: TextStyle(
                            color: _text,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.7,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DirectionButton extends StatelessWidget {
  const _DirectionButton({
    required this.alignment,
    required this.icon,
    required this.onTap,
  });

  final Alignment alignment;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: InkResponse(
        onTap: onTap,
        radius: 60,
        child: SizedBox(
          width: 98,
          height: 98,
          child: Icon(
            icon,
            color: _muted,
            size: 39,
          ),
        ),
      ),
    );
  }
}

class _Touchpad extends StatefulWidget {
  const _Touchpad({
    super.key,
    required this.onKey,
  });

  final ValueChanged<int> onKey;

  @override
  State<_Touchpad> createState() =>
      _TouchpadState();
}

class _TouchpadState extends State<_Touchpad> {
  Offset _movement = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => widget.onKey(AndroidKey.ok),
      onPanStart: (_) => _movement = Offset.zero,
      onPanUpdate: (details) {
        _movement += details.delta;
        const threshold = 34.0;

        if (_movement.dx.abs() > _movement.dy.abs()) {
          if (_movement.dx > threshold) {
            widget.onKey(AndroidKey.right);
            _movement = Offset(
              _movement.dx - threshold,
              _movement.dy,
            );
          } else if (_movement.dx < -threshold) {
            widget.onKey(AndroidKey.left);
            _movement = Offset(
              _movement.dx + threshold,
              _movement.dy,
            );
          }
        } else {
          if (_movement.dy > threshold) {
            widget.onKey(AndroidKey.down);
            _movement = Offset(
              _movement.dx,
              _movement.dy - threshold,
            );
          } else if (_movement.dy < -threshold) {
            widget.onKey(AndroidKey.up);
            _movement = Offset(
              _movement.dx,
              _movement.dy + threshold,
            );
          }
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: _line),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF151C25),
              Color(0xFF0B0E13),
            ],
          ),
        ),
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.touch_app_rounded,
              color: _accent,
              size: 36,
            ),
            SizedBox(height: 12),
            Text(
              'Свайп — навигация',
              style: TextStyle(
                color: _text,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 5),
            Text(
              'Касание — OK',
              style: TextStyle(
                color: _muted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _panel,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: _line),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: _muted, size: 19),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  color: _text,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.children,
  });

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _line),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: children,
      ),
    );
  }
}

class _IconControl extends StatelessWidget {
  const _IconControl({
    required this.icon,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      iconSize: accent ? 31 : 24,
      color: accent ? _accent : _muted,
      icon: Icon(icon),
    );
  }
}

class _RepeatIconControl extends StatelessWidget {
  const _RepeatIconControl({
    required this.icon,
    required this.onTap,
    required this.onStart,
    required this.onStop,
  });

  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: (_) => onStart(),
      onLongPressEnd: (_) => onStop(),
      child: SizedBox(
        width: 64,
        height: 54,
        child: Icon(
          icon,
          color: _muted,
          size: 25,
        ),
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.wifi_off_rounded,
                color: Color(0xFFFF7C86),
                size: 38,
              ),
              const SizedBox(height: 16),
              const Text(
                'Нет соединения',
                style: TextStyle(
                  color: _text,
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: _bg,
                  ),
                  child: const Text(
                    'Найти приставку заново',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Локальное управление • без рекламы • без облака',
        style: TextStyle(
          color: Color(0xFF566170),
          fontSize: 11.5,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
