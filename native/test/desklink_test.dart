import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desklink_native/desklink_account.dart';
import 'package:flutter_test/flutter_test.dart';

const _password = 'Desklink fixture + & 终端';
const _device = {
  '_id': 'node//mini',
  'name': 'Mac mini',
  'desklinkNative': true,
};
final _accessPassword = List.filled(64, 'a').join();

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
      'one account authorizes the desktop and opens two independent SSH sessions',
      () async {
    final account =
        await DesklinkAccount.signIn(address, 'desklink', _password);
    addTearDown(account.close);
    final device = account.devices.single;
    expect(device.name, 'Mac mini');
    expect(device.nativeAccess, isTrue);
    final access = await account.authorizeDesktop(device);
    expect(access.id, '123456789');
    expect(access.password, _accessPassword);
    await expectLater(
      account.authorizeDesktop(DesklinkDevice(_device)),
      throwsA(isA<HttpException>()),
    );
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
    final node = DesklinkDevice({
      '_id': 'node//foreign',
      'name': 'Foreign',
      'desc': 'RustDesk ID: 123456@elsewhere.test',
    });
    expect(node.nativeAccess, isFalse);
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
      final command = jsonDecode(message as String) as Map<String, dynamic>;
      if (command['action'] == 'nodes' && command['desklink'] == true) {
        socket.add(jsonEncode({
          'action': 'nodes',
          'nodes': {
            'mesh//private': [_device]
          }
        }));
      } else if (command['action'] == 'desklink-desktop-access') {
        socket.add(jsonEncode({
          'action': 'desklink-desktop-access',
          'access': command['nodeid'] == 'node//mini'
              ? {'id': '123456789', 'password': _accessPassword}
              : null,
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
