import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _timeout = Duration(seconds: 12);
final _rustDeskId = RegExp(r'^RustDesk ID: ([a-zA-Z0-9_-]{3,64})$', multiLine: true);

class DesklinkDevice {
  DesklinkDevice(Map<String, dynamic> node)
      : id = node['_id'] as String,
        name = node['name'] as String,
        desktopId = _rustDeskId.firstMatch(node['desc'] as String? ?? '')?.group(1);

  final String id;
  final String name;
  final String? desktopId;
}

class DesklinkAccount {
  DesklinkAccount._(this._base, this._client);

  final Uri _base;
  final HttpClient _client;
  final Map<String, String> _cookies = {};
  List<DesklinkDevice> _devices = const [];
  List<DesklinkDevice> get devices => _devices;

  static Future<DesklinkAccount> signIn(
    String address,
    String username,
    String password,
  ) async {
    final base = Uri.tryParse(address.trim());
    if (base == null ||
        base.host.isEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        base.authority.contains('@') ||
        (base.path.isNotEmpty && base.path != '/') ||
        (base.scheme != 'https' &&
            !(base.scheme == 'http' && base.host == '127.0.0.1'))) {
      throw const FormatException('请输入 HTTPS 账号入口或本机 SSH 转发地址');
    }

    final client = HttpClient()..connectionTimeout = _timeout;
    final account = DesklinkAccount._(base.replace(path: '/'), client);
    try {
      await account._request();
      await account._request({
        'action': 'login',
        'username': username.trim(),
        'password': password,
      });
      account._devices = await account._listDevices();
      return account;
    } catch (_) {
      account.close();
      rethrow;
    }
  }

  Future<void> _request([Map<String, String>? form]) async {
    final request = await _client
        .openUrl(form == null ? 'GET' : 'POST', _base)
        .timeout(_timeout);
    request.followRedirects = false;
    request.headers.set('Origin', _base.origin);
    request.headers.set(HttpHeaders.refererHeader, _base.toString());
    request.headers.set(HttpHeaders.cookieHeader, _cookieHeader);
    if (form != null) {
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      request.write(Uri(queryParameters: form).query);
    }
    final response = await request.close().timeout(_timeout);
    for (final cookie in response.cookies) {
      _cookies[cookie.name] = cookie.value;
    }
    await response.drain<void>().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok &&
        !(form != null && [HttpStatus.found, HttpStatus.seeOther].contains(response.statusCode))) {
      throw const HttpException('账号入口无法登录');
    }
  }

  String get _cookieHeader => _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Future<WebSocket> _connect(String path, [Map<String, String>? query]) {
    final url = _base.replace(
      scheme: _base.scheme == 'https' ? 'wss' : 'ws',
      path: path,
      queryParameters: query,
    );
    return WebSocket.connect(
      url.toString(),
      customClient: _client,
      headers: {'Cookie': _cookieHeader, 'Origin': _base.origin},
    ).timeout(_timeout);
  }

  Future<List<DesklinkDevice>> _listDevices() async {
    final socket = await _connect('/control.ashx');
    try {
      return await _readDevices(socket).timeout(_timeout);
    } finally {
      unawaited(socket.close());
    }
  }

  Future<List<DesklinkDevice>> _readDevices(WebSocket socket) async {
    var signedIn = false;
    await for (final data in socket.where((event) => event is String)) {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      if (message['action'] == 'userinfo' && !signedIn) {
        signedIn = true;
        socket.add(jsonEncode({'action': 'nodes'}));
      }
      if (signedIn && message['action'] == 'nodes') {
        final groups = message['nodes'] as Map<String, dynamic>;
        return List.unmodifiable(groups.values.expand((value) => (value as List)
            .cast<Map<String, dynamic>>()
            .map(DesklinkDevice.new)));
      }
      if (message['action'] == 'close') break;
    }
    throw const HttpException('无法验证账号，请检查用户名和密码');
  }

  Future<WebSocket> openSsh(DesklinkDevice device) {
    if (!devices.contains(device)) {
      throw const HttpException('此设备不在当前账号中');
    }
    return _connect('/sshterminalrelay.ashx', {'nodeid': device.id});
  }

  void close() => _client.close(force: true);
}
