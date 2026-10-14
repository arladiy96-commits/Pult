import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tv_companion_client.dart';

const _bg = Color(0xFF06101A);
const _panel = Color(0xFF0A1C29);
const _line = Color(0xFF215370);
const _cyan = Color(0xFF29C7FF);
const _muted = Color(0xFF8EA7BA);

/// The original Android TV remote remains unchanged. This is an optional
/// separate screen to exercise TV-side mouse/IME/application features.
class TvCompanionScreen extends StatefulWidget {
  const TvCompanionScreen({super.key, required this.host});
  final String host;

  @override
  State<TvCompanionScreen> createState() => _TvCompanionScreenState();
}

class _TvCompanionScreenState extends State<TvCompanionScreen> {
  late final TvCompanionClient client = TvCompanionClient(widget.host);
  final pin = TextEditingController();
  final input = TextEditingController();
  final apps = <_TvApp>[];
  String? pendingFingerprint;
  String status = 'Поиск установленного компонента…';
  bool confirmed = false;
  bool busy = false;
  bool connected = false;
  bool loadingApps = false;
  double sensitivity = 1.7;
  double accumX = 0, accumY = 0, accumScroll = 0;
  DateTime lastPointerSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    pin.dispose();
    input.dispose();
    client.close();
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() { busy = true; status = 'Подключение к ${widget.host}…'; });
    try {
      final identity = await client.storedIdentity();
      if (identity != null) {
        await client.connectSaved();
        if (!mounted) return;
        setState(() { connected = true; status = 'Защищённое соединение с приставкой'; });
      } else {
        await _probe();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { connected = false; status = 'Нет подключения: $e'; });
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
      status = 'Сравни отпечаток ниже с экраном приставки';
    });
  }

  Future<void> _pair() async {
    if (!confirmed || pendingFingerprint == null) return;
    setState(() { busy = true; status = 'Сопряжение…'; });
    try {
      await client.pair(pendingFingerprint!, pin.text.trim());
      if (!mounted) return;
      setState(() { connected = true; status = 'Подключено и сохранено'; });
      pin.clear();
    } catch (e) {
      if (mounted) setState(() => status = 'Не удалось сопрячь: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _forget() async {
    await client.forget();
    if (!mounted) return;
    setState(() { connected = false; pendingFingerprint = null; confirmed = false; apps.clear(); });
    try {
      await _probe();
    } catch (e) {
      if (mounted) setState(() => status = 'Нет связи: $e');
    }
  }

  Future<void> _command(String cmd, [Map<String, dynamic> extras = const {}]) async {
    try {
      final response = await client.request({'cmd': cmd, ...extras});
      if (response['ok'] != true) {
        throw StateError('${response['error'] ?? 'Команда отклонена'}');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: _panel),
      );
    }
  }

  void _move(DragUpdateDetails d) {
    accumX += d.delta.dx * sensitivity;
    accumY += d.delta.dy * sensitivity;
    if (DateTime.now().difference(lastPointerSent).inMilliseconds < 30) return;
    _flushMove();
  }

  void _flushMove() {
    if (accumX == 0 && accumY == 0) return;
    final dx = accumX, dy = accumY;
    accumX = accumY = 0;
    lastPointerSent = DateTime.now();
    // Mouse movements are best-effort, but a session stays authenticated.
    unawaited(client.request({'cmd': 'move', 'dx': dx, 'dy': dy}).catchError((Object _) => <String, dynamic>{}));
  }

  void _scroll(DragUpdateDetails d) {
    accumScroll += d.delta.dy;
    if (accumScroll.abs() < 24) return;
    final direction = accumScroll < 0 ? 1 : -1;
    accumScroll = 0;
    unawaited(client.request({'cmd': 'scroll', 'dy': direction}).catchError((Object _) => <String, dynamic>{}));
  }

  Future<void> _loadApps() async {
    if (loadingApps) return;
    setState(() => loadingApps = true);
    try {
      final answer = await client.request({'cmd': 'apps'});
      if (answer['ok'] != true) throw StateError('${answer['error'] ?? 'Ошибка списка'}');
      final entries = (answer['apps'] as List<dynamic>?) ?? [];
      if (!mounted) return;
      setState(() {
        apps
          ..clear()
          ..addAll(entries.whereType<Map<String, dynamic>>().map(_TvApp.fromJson));
        apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      });
    } catch (e) {
      if (mounted) setState(() => status = 'Ошибка загрузки приложений: $e');
    } finally {
      if (mounted) setState(() => loadingApps = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          foregroundColor: Colors.white,
          title: const Text('Пульт · Расширенное'),
          actions: [
            if (connected) IconButton(
              tooltip: 'Забыть сопряжение',
              icon: const Icon(Icons.link_off_rounded),
              onPressed: _forget,
            ),
          ],
          bottom: connected ? const TabBar(
            indicatorColor: _cyan,
            labelColor: _cyan,
            unselectedLabelColor: _muted,
            tabs: [Tab(text: 'Мышь'), Tab(text: 'Приложения'), Tab(text: 'Клавиатура')],
          ) : null,
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: _tile(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('X96 · ${widget.host}:39678', style: const TextStyle(color: _cyan, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(status, style: const TextStyle(color: _muted, fontSize: 12)),
            ])),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 2, color: _cyan),
          Expanded(child: connected ? TabBarView(children: [
            _mousePage(),
            _appsPage(),
            _keyboardPage(),
          ]) : _pairPage()),
        ]),
      ),
    );
  }

  Widget _pairPage() {
    return ListView(padding: const EdgeInsets.all(15), children: [
      const Text('Подключение компонента на приставке', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 19)),
      const SizedBox(height: 9),
      const Text('Установи Pult-TV.apk на X96, включи службу специальных возможностей и нажми на приставке «Показать код на 2 минуты». Телефон и X96 должны быть в одной сети.', style: TextStyle(color: _muted, height: 1.4)),
      const SizedBox(height: 15),
      if (pendingFingerprint != null) ...[
        const Text('Отпечаток сертификата SHA-256:', style: TextStyle(color: Colors.white)),
        const SizedBox(height: 9),
        SelectableText(pendingFingerprint!.replaceAllMapped(RegExp(r'.{2}'), (m) => '${m.group(0)}:' ).replaceFirst(RegExp(r':$'), ''),
            style: const TextStyle(color: _cyan, fontSize: 13)),
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Отпечаток полностью совпадает с тем, что показан на телевизоре', style: TextStyle(color: Colors.white, fontSize: 13)),
          value: confirmed,
          onChanged: (v) => setState(() => confirmed = v ?? false),
          activeColor: _cyan,
          controlAffinity: ListTileControlAffinity.leading,
        ),
        TextField(
          controller: pin,
          style: const TextStyle(color: Colors.white, fontSize: 20),
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Код с экрана X96', labelStyle: TextStyle(color: _muted)),
        ),
        const SizedBox(height: 6),
        FilledButton(onPressed: busy || !confirmed ? null : _pair, child: const Text('Сопрячь и сохранить')),
      ],
      const SizedBox(height: 10),
      OutlinedButton(onPressed: busy ? null : () async {
        setState(() => busy = true);
        try {
          final saved = await client.storedIdentity();
          if (saved != null) { await client.connectSaved(); if (mounted) setState(() { connected = true; status = 'Подключено'; }); }
          else { await _probe(); }
        } catch (e) { if (mounted) setState(() => status = '$e'); }
        finally { if (mounted) setState(() => busy = false); }
      }, child: const Text('Проверить соединение ещё раз')),
      OutlinedButton(onPressed: busy ? null : _forget, child: const Text('Сбросить старое сопряжение')),
    ]);
  }

  Widget _mousePage() => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(children: [
      const Text('Двигай пальцем — курсор на телевизоре. Нажатие — клик, удержание — длинный клик.',
          style: TextStyle(color: _muted, fontSize: 12)),
      const SizedBox(height: 12),
      Expanded(child: Row(children: [
        Expanded(child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: _move,
          onPanEnd: (_) => _flushMove(),
          onTap: () => _command('tap'),
          onLongPress: () => _command('long_press'),
          child: _tile(const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.mouse_rounded, size: 56, color: _cyan),
            SizedBox(height: 15),
            Text('ТАЧПАД', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            SizedBox(height: 7),
            Text('Движение · Клик', style: TextStyle(color: _muted)),
          ]))),
        )),
        const SizedBox(width: 10),
        SizedBox(width: 65, child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: _scroll,
          child: _tile(const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.keyboard_arrow_up, color: _cyan),
            SizedBox(height: 12),
            Icon(Icons.swap_vert_rounded, color: Colors.white),
            SizedBox(height: 9),
            Text('СКРОЛЛ', style: TextStyle(color: _muted, fontSize: 9)),
            SizedBox(height: 12),
            Icon(Icons.keyboard_arrow_down, color: _cyan),
          ]))),
        )),
      ])),
      Row(children: [
        const Text('Чувствительность', style: TextStyle(color: _muted, fontSize: 11)),
        Expanded(child: Slider(
          value: sensitivity, min: .6, max: 3.5,
          onChanged: (v) => setState(() => sensitivity = v),
          activeColor: _cyan,
        )),
      ]),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () => _command('key', {'code': 4}), child: const Text('Назад'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton(onPressed: () => _command('key', {'code': 3}), child: const Text('Домой'))),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton(onPressed: () => _command('hide_cursor'), child: const Text('Скрыть'))),
      ]),
    ]),
  );

  Widget _appsPage() => Column(children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child:
      Row(children: [
        Expanded(child: Text('Установлено: ${apps.length}', style: const TextStyle(color: _muted))),
        TextButton.icon(onPressed: _loadApps, icon: const Icon(Icons.refresh), label: const Text('Обновить')),
      ])),
    if (loadingApps) const LinearProgressIndicator(minHeight: 2, color: _cyan),
    Expanded(child: apps.isEmpty
      ? Center(child: FilledButton.icon(
          onPressed: _loadApps,
          icon: const Icon(Icons.grid_view_rounded),
          label: const Text('Загрузить приложения с X96'),
        ))
      : GridView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: apps.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 9, crossAxisSpacing: 9, childAspectRatio: .82),
          itemBuilder: (_, i) {
            final a = apps[i];
            return InkWell(
              onTap: () => _command('launch', {'package': a.packageName}),
              child: _tile(Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (a.icon != null) Image.memory(a.icon!, width: 48, height: 48, errorBuilder: (_, _, _) => const Icon(Icons.apps_rounded, color: _cyan, size: 42))
                else const Icon(Icons.apps_rounded, color: _cyan, size: 42),
                const SizedBox(height: 10),
                Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
              ])),
            );
          },
        )),
  ]);

  Widget _keyboardPage() => ListView(padding: const EdgeInsets.all(15), children: [
    const Text('Сначала открой поле ввода на приставке и выбери системную клавиатуру «Пульт · ввод с телефона».',
      style: TextStyle(color: _muted, height: 1.5)),
    const SizedBox(height: 15),
    TextField(
      controller: input,
      minLines: 2,
      maxLines: 5,
      style: const TextStyle(color: Colors.white),
      decoration: const InputDecoration(
        labelText: 'Текст для телевизора', labelStyle: TextStyle(color: _muted),
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 10),
    FilledButton.icon(
      onPressed: () async {
        if (input.text.isEmpty) return;
        try {
          final result = await client.request({'cmd': 'text', 'text': input.text});
          if (result['ok'] == true) { input.clear(); }
          else if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${result['error']}')));
        } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
      },
      icon: const Icon(Icons.send_rounded),
      label: const Text('Отправить текст'),
    ),
    const SizedBox(height: 10),
    OutlinedButton.icon(onPressed: () => _command('delete'), icon: const Icon(Icons.backspace_outlined),
        label: const Text('Удалить символ на приставке')),
  ]);

  Widget _tile(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _line),
    ),
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
    return _TvApp('${data['name'] ?? 'Приложение'}', '${data['package'] ?? ''}', icon);
  }
}
