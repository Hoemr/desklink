import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'desklink_account.dart';

class DesklinkPage extends StatefulWidget {
  const DesklinkPage({super.key, required this.openDesktop});

  final void Function(BuildContext context, String id) openDesktop;

  @override
  State<DesklinkPage> createState() => _DesklinkPageState();
}

class _DesklinkPageState extends State<DesklinkPage> {
  final _address = TextEditingController(
    text: const String.fromEnvironment('DESKLINK_ACCOUNT_URL'),
  );
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _terminals = <({int id, DesklinkDevice device})>[];
  int _tab = 0;
  int _nextTerminal = 0;
  DesklinkAccount? _account;
  String? _error;
  bool _busy = false;

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await DesklinkAccount.signIn(
        _address.text,
        _username.text,
        _password.text,
      );
      if (!mounted) {
        account.close();
        return;
      }
      _password.clear();
      setState(() => _account = account);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on HttpException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '连接失败，请检查账号入口和网络');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _account?.close();
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Desklink'),
        actions: [
          if (_tab != 0)
            IconButton(
              tooltip: '关闭当前终端',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _terminals.removeAt(_tab - 1);
                _tab = 0;
              }),
            ),
          if (account != null)
            TextButton(
              onPressed: () {
                account.close();
                setState(() {
                  _account = null;
                  _terminals.clear();
                  _tab = 0;
                });
              },
              child: const Text('退出登录'),
            ),
        ],
      ),
      body: SafeArea(
        child: account == null ? _loginForm() : _workspace(account),
      ),
    );
  }

  Widget _loginForm() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              TextField(
                controller: _address,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '账号入口'),
              ),
              TextField(
                controller: _username,
                enabled: !_busy,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                onSubmitted: (_) => _signIn(),
                decoration: const InputDecoration(labelText: '密码'),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _signIn,
                child: Text(_busy ? '正在登录…' : '登录'),
              ),
            ],
          ),
        ),
      );

  Widget _workspace(DesklinkAccount account) => Column(
        children: [
          if (_terminals.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('设备'),
                    selected: _tab == 0,
                    onSelected: (_) => setState(() => _tab = 0),
                  ),
                  for (final (index, session) in _terminals.indexed)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        label: Text('${session.device.name} · SSH ${session.id}'),
                        selected: _tab == index + 1,
                        onSelected: (_) => setState(() => _tab = index + 1),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _deviceList(account),
                for (final (index, session) in _terminals.indexed)
                  ExcludeFocus(
                    key: ValueKey(session.id),
                    excluding: _tab != index + 1,
                    child: _SshTerminal(account: account, device: session.device),
                  ),
              ],
            ),
          ),
        ],
      );

  Widget _deviceList(DesklinkAccount account) {
    if (account.devices.isEmpty) return const Center(child: Text('账号下暂无设备'));
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: account.devices.length,
      separatorBuilder: (_, __) => const Divider(),
      itemBuilder: (context, index) {
        final device = account.devices[index];
        final desktopId = device.desktopId;
        return ListTile(
          leading: const Icon(Icons.computer_outlined),
          title: Text(device.name),
          subtitle: Wrap(
            spacing: 8,
            children: [
              if (desktopId != null)
                TextButton.icon(
                  icon: const Icon(Icons.desktop_windows_outlined),
                  label: const Text('远程桌面'),
                  onPressed: () => widget.openDesktop(context, desktopId),
                ),
              TextButton.icon(
                icon: const Icon(Icons.terminal),
                label: const Text('SSH 终端'),
                onPressed: () => setState(() {
                  _terminals.add((id: ++_nextTerminal, device: device));
                  _tab = _terminals.length;
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SshTerminal extends StatefulWidget {
  const _SshTerminal({required this.account, required this.device});

  final DesklinkAccount account;
  final DesklinkDevice device;

  @override
  State<_SshTerminal> createState() => _SshTerminalState();
}

class _SshTerminalState extends State<_SshTerminal> {
  final _terminal = Terminal(maxLines: 5000);
  Map<String, int> _size = {'cols': 80, 'rows': 24, 'width': 0, 'height': 0};
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _deadline;
  bool _connected = false;
  String _status = '正在连接 SSH…';

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (text) {
      if (_connected) _socket?.add('~$text');
    };
    _terminal.onResize = (cols, rows, width, height) {
      if (cols < 1 || rows < 1) return;
      _size = {'cols': cols, 'rows': rows, 'width': width, 'height': height};
      if (_connected) _send('resize');
    };
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final socket = await widget.account.openSsh(widget.device);
      if (!mounted) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      _deadline = Timer(const Duration(seconds: 12), () => _stop('SSH 连接超时'));
      _subscription = socket.listen(
        _receive,
        onError: (Object _) => _stop('SSH 连接中断'),
        onDone: () => _stop('SSH 已断开'),
        cancelOnError: true,
      );
    } catch (_) {
      _stop('无法连接 SSH');
    }
  }

  void _send(String action) => _socket?.add(jsonEncode({'action': action, ..._size}));

  void _receive(dynamic data) {
    if (data is! String || data.isEmpty) return;
    if (data.startsWith('~')) {
      _terminal.write(data.substring(1));
      return;
    }
    if (data == 'c') {
      _deadline?.cancel();
      setState(() {
        _connected = true;
        _status = '';
      });
      return;
    }
    if (!data.startsWith('{')) return;
    final message = jsonDecode(data) as Map<String, dynamic>;
    switch (message['action']) {
      case 'sshautoauth':
        _send('sshautoauth');
      case 'sshauth':
        _stop('请在账号后台为此设备保存可自动登录的 SSH 凭据');
      case 'autherror':
      case 'connectionerror':
      case 'sessiontimeout':
      case 'close':
        _stop('设备拒绝 SSH 连接或暂时不可达');
    }
  }

  void _stop(String status) {
    final socket = _socket;
    _socket = null;
    _deadline?.cancel();
    if (socket != null) unawaited(socket.close());
    if (mounted && (socket != null || _status == '正在连接 SSH…')) {
      setState(() {
        _connected = false;
        _status = status;
      });
    }
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _subscription?.cancel();
    _socket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          if (_status.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(_status)),
          Expanded(child: TerminalView(_terminal)),
          if (_connected)
            Wrap(children: [
              TextButton(onPressed: () => _terminal.keyInput(TerminalKey.escape), child: const Text('Esc')),
              TextButton(onPressed: () => _terminal.keyInput(TerminalKey.tab), child: const Text('Tab')),
              TextButton(onPressed: () => _terminal.keyInput(TerminalKey.c, ctrl: true), child: const Text('Ctrl+C')),
              TextButton(onPressed: () => _terminal.keyInput(TerminalKey.b, ctrl: true), child: const Text('Ctrl+B')),
            ]),
        ],
      );
}
