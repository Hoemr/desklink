import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desklink_native/desklink_account.dart';
import 'package:flutter_test/flutter_test.dart';

const _password = 'Desklink fixture + & 终端';
const _device = {
  '_id': 'node//mini',
  'name': 'Mac mini',
  'desc': 'Office\nRustDesk ID: 123456789',
};

void main() {
  late HttpServer server;
  late String address;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    address = 'http://127.0.0.1:${server.port}';
    server.listen(_fixture);
  });

  tearDown(() => server.close(force: true));

  test('wrong password cannot read the device list', () async {
    await expectLater(
      DesklinkAccount.signIn(address, 'desklink', 'incorrect'),
      throwsA(isA<HttpException>()),
    );
  });

  test('credentials require HTTPS outside the loopback', () async {
    await expectLater(
      DesklinkAccount.signIn('http://example.com', 'desklink', _password),
      throwsA(isA<FormatException>()),
    );
  });

  test(
      'one account resolves the desktop ID and opens two independent SSH sessions',
      () async {
    final account =
        await DesklinkAccount.signIn(address, 'desklink', _password);
    addTearDown(account.close);
    final device = account.devices.single;
    expect(device.name, 'Mac mini');
    expect(device.desktopId, '123456789');
    expect(
      () => account
          .openSsh(DesklinkDevice({'_id': 'node//other', 'name': 'Other'})),
      throwsA(isA<HttpException>()),
    );

    Future<void> run(String input) async {
      final socket = await account.openSsh(device);
      final stream = StreamIterator(socket);
      try {
        expect(await stream.moveNext(), isTrue);
        expect(jsonDecode(stream.current as String)['action'], 'sshautoauth');
        socket.add(
            '{"action":"sshautoauth","cols":80,"rows":24,"width":0,"height":0}');
        expect(await stream.moveNext(), isTrue);
        expect(stream.current, 'c');
        socket.add('~$input');
        expect(await stream.moveNext(), isTrue);
        expect(stream.current, '~$input');
      } finally {
        await stream.cancel();
        unawaited(socket.close());
      }
    }

    await Future.wait([run('first terminal'), run('second terminal')]);
  });

  test('device notes cannot override the configured RustDesk server', () {
    final node = DesklinkDevice(
        {..._device, 'desc': 'RustDesk ID: 123456@elsewhere.test'});
    expect(node.desktopId, isNull);
  });
}

Future<void> _fixture(HttpRequest request) async {
  if (request.uri.path == '/') {
    if (request.method == 'POST') {
      final data = await utf8.decoder.bind(request).join();
      final credentials = Uri.splitQueryString(data);
      if (credentials['username'] == 'desklink' &&
          credentials['password'] == _password) {
        request.response.cookies.add(Cookie('mesh_session', 'fixture-session'));
      }
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/');
    }
    await request.response.close();
    return;
  }

  final socket = await WebSocketTransformer.upgrade(request);
  final authenticated = request.headers.value(HttpHeaders.cookieHeader) ==
      'mesh_session=fixture-session';
  if (!authenticated) {
    socket.add('{"action":"close","cause":"noauth"}');
    await socket.close(WebSocketStatus.policyViolation);
    return;
  }
  if (request.uri.path == '/control.ashx') {
    socket.add('{"action":"userinfo"}');
    await for (final message in socket) {
      if (jsonDecode(message as String)['action'] == 'nodes') {
        socket.add(jsonEncode({
          'action': 'nodes',
          'nodes': {
            'mesh//private': [_device]
          }
        }));
      }
    }
  } else if (request.uri.path == '/sshterminalrelay.ashx' &&
      request.uri.queryParameters['nodeid'] == 'node//mini') {
    socket.add('{"action":"sshautoauth"}');
    await for (final message in socket) {
      final text = message as String;
      if (text.startsWith('~')) {
        socket.add(text);
      } else if (jsonDecode(text)['action'] == 'sshautoauth') {
        socket.add('c');
      }
    }
  } else {
    await socket.close(WebSocketStatus.policyViolation);
  }
}
