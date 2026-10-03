import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/plugin/cycani_api.dart';
import 'package:kazumi/services/plugin/cycani_rule.dart';
import 'package:kazumi/services/plugin/cycani_windows_session.dart';

void main() {
  test('playback adapter refuses lookalike origins and non-API entries', () {
    expect(CycaniApi.handlesPlayback(
        'https://www.cycani.org/api/v2/sections/1/play-url'), isTrue);
    for (final url in [
      'https://www.cycani.org.evil.test/api/v2/sections/1/play-url',
      'http://www.cycani.org/api/v2/sections/1/play-url',
      'https://www.cycani.org:444/api/v2/sections/1/play-url',
      'https://user@www.cycani.org/api/v2/sections/1/play-url',
      'https://www.cycani.org/api/v2/sections/0/play-url',
      'https://www.cycani.org/api/v2/sections/1/play-url?redirect=evil',
    ]) {
      expect(CycaniApi.handlesPlayback(url), isFalse, reason: url);
    }
  });

  test('authentication header reaches the API, not the returned CDN URL', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      handler.resolve(Response(requestOptions: options, statusCode: 200,
        data: <String, dynamic>{'code': 0,
          'data': {'url': 'https://cdn.example.test/video.m3u8'}}));
    }));
    final api = CycaniApi(dio: dio, tokenProvider: () async => 'test-token');
    expect(await api.resolvePlayback(
        'https://www.cycani.org/api/v2/sections/1/play-url'),
        'https://cdn.example.test/video.m3u8');
    expect(requests, hasLength(1));
    expect(requests.single.uri.host, 'www.cycani.org');
    expect(requests.single.headers['Authorization'], 'Bearer test-token');
    expect(requests.single.followRedirects, isFalse);
  });

  test('missing session requires login before making any protected request', () async {
    final api = CycaniApi(dio: Dio(), tokenProvider: () async => null);
    await expectLater(api.resolvePlayback(
        'https://www.cycani.org/api/v2/sections/1/play-url'),
        throwsA(isA<CycaniLoginRequired>()));
  });

  test('server errors omit token and request options', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.reject(DioException(requestOptions: options,
        response: Response(requestOptions: options, statusCode: 401),
        type: DioExceptionType.badResponse));
    }));
    final api = CycaniApi(dio: dio, tokenProvider: () async => 'private-token');
    try {
      await api.resolvePlayback(
          'https://www.cycani.org/api/v2/sections/1/play-url');
      fail('Expected authentication rejection');
    } catch (error) {
      expect(error, isA<CycaniLoginRequired>());
      expect(error.toString(), isNot(contains('private-token')));
    }
  });

  test('chapter pagination preserves more than one hundred episodes', () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      final page = options.queryParameters['page'] as int;
      final count = page == 1 ? 100 : 1;
      handler.resolve(Response(requestOptions: options, statusCode: 200,
        data: <String, dynamic>{'code': 0, 'data': {
          'list': List.generate(count, (index) => {
            'id': (page - 1) * 100 + index + 1,
            'title': 'episode',
          }),
          'pager': {'total': 101},
        }}));
    }));
    final api = CycaniApi(dio: dio, tokenProvider: () async => 'unused');
    final result = jsonDecode(await api.requestRule(
        'https://www.cycani.org/_kazumi/cycani/chapters', {'id': '1'}));
    expect(result['data']['list'], hasLength(101));
    expect(result['data']['list'][100]['kazumi_url'],
        'https://www.cycani.org/api/v2/sections/101/play-url');
    expect(requests.every((r) => !r.headers.containsKey('Authorization')), isTrue);
  });

  test('expired and malformed sessions cannot be enabled', () {
    final session = CycaniWindowsSession.instance;
    expect(session.accept(jsonEncode({'token': 't',
      'expiresAt': '2000-01-01T00:00:00Z', 'persistent': true})), isFalse);
    expect(session.accept('{bad json'), isFalse);
    expect(session.accept(jsonEncode({'token': 't\r\nx: y'})), isFalse);
    expect(session.accept(jsonEncode({'token': 't',
      'expiresAt': '2099-01-01T00:00:00Z', 'persistent': true})), isTrue);
    session.invalidate();
  });

  test('shared rule contains configuration without authentication data', () {
    final json = jsonEncode(buildCycaniRule().toJson());
    expect(json, isNot(contains('Authorization')));
    expect(json, isNot(contains('token')));
    expect(json, isNot(contains('password')));
    expect(json, isNot(contains('127.0.0.1')));
  });
}
