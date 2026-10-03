import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/plugin/cycani_api.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/services/video_source/webview_video_source_service.dart';

const _episode = 'https://www.cycani.org/api/v2/sections/1/play-url';
const _media = 'https://cdn.example.test/episode.m3u8';

class _StubCycaniApi extends CycaniApi {
  _StubCycaniApi(this.resolve)
      : super(dio: Dio(), tokenProvider: () async => 'test-token');
  final Future<String> Function(String) resolve;

  @override
  Future<String> resolvePlayback(String entry) => resolve(entry);
}

WebViewVideoSourceService _service(_StubCycaniApi api) =>
    WebViewVideoSourceService(
      cycaniApi: api,
      webviewFactory: () => throw PlatformException(
        code: 'unsupported_platform',
        message: 'The platform is not supported',
      ),
    );

void main() {
  group('Windows Cycani playback without the legacy WebView', () {
    test('returns API media and offset even when the page parser is unavailable', () async {
      final service = _service(_StubCycaniApi((entry) async {
        expect(entry, _episode);
        return _media;
      }));
      addTearDown(service.dispose);
      final result = await service.resolve(
        _episode, useLegacyParser: true, offset: 73,
      );
      expect(result.url, _media);
      expect(result.offset, 73);
      expect(result.type, VideoSourceType.online);
    });

    test('ordinary pages still use the page parser', () async {
      final service = _service(_StubCycaniApi((_) async {
        fail('An ordinary page must not enter the authenticated API');
      }));
      addTearDown(service.dispose);
      await expectLater(
        service.resolve('https://example.test/watch/1', useLegacyParser: false),
        throwsA(isA<PlatformException>().having(
          (error) => error.code, 'code', 'unsupported_platform',
        )),
      );
    });

    test('expired login reports an account error without initializing a parser', () async {
      final service = _service(_StubCycaniApi((_) async {
        throw const CycaniLoginRequired();
      }));
      addTearDown(service.dispose);
      await expectLater(
        service.resolve(_episode, useLegacyParser: false),
        throwsA(isA<CycaniLoginRequired>()),
      );
    });

    test('changing episodes cancels a pending API result', () async {
      final firstStarted = Completer<void>();
      final firstMedia = Completer<String>();
      final secondEpisode = _episode.replaceFirst('/1/', '/2/');
      final service = _service(_StubCycaniApi((entry) async {
        if (entry == _episode) {
          firstStarted.complete();
          return firstMedia.future;
        }
        expect(entry, secondEpisode);
        return 'https://cdn.example.test/second.m3u8';
      }));
      addTearDown(service.dispose);
      final first = service.resolve(_episode, useLegacyParser: false);
      final cancelled = expectLater(first, throwsA(isA<VideoSourceCancelledException>()));
      await firstStarted.future;
      final second = service.resolve(secondEpisode, useLegacyParser: false, offset: 9);
      await cancelled;
      final result = await second;
      firstMedia.complete(_media);
      expect(result.url, 'https://cdn.example.test/second.m3u8');
      expect(result.offset, 9);
    });

    test('cancel releases a pending API request', () async {
      final started = Completer<void>();
      final pending = Completer<String>();
      final service = _service(_StubCycaniApi((_) {
        started.complete();
        return pending.future;
      }));
      addTearDown(service.dispose);
      final result = service.resolve(_episode, useLegacyParser: false);
      final cancelled = expectLater(result, throwsA(isA<VideoSourceCancelledException>()));
      await started.future;
      service.cancel();
      await cancelled;
      pending.complete(_media);
    });

    test('API timeout allows a later retry to succeed', () async {
      final pending = Completer<String>();
      var calls = 0;
      final service = _service(_StubCycaniApi((_) {
        calls++;
        return calls == 1 ? pending.future : Future.value(_media);
      }));
      addTearDown(service.dispose);
      await expectLater(
        service.resolve(_episode, useLegacyParser: false,
          timeout: const Duration(milliseconds: 20)),
        throwsA(isA<VideoSourceTimeoutException>()),
      );
      final retry = await service.resolve(_episode, useLegacyParser: false);
      expect(retry.url, _media);
      pending.complete(_media);
    });

    test('dispose cancels a pending API request and rejects future work', () async {
      final started = Completer<void>();
      final pending = Completer<String>();
      final service = _service(_StubCycaniApi((_) {
        started.complete();
        return pending.future;
      }));
      final result = service.resolve(_episode, useLegacyParser: false);
      final cancelled = expectLater(result, throwsA(isA<VideoSourceCancelledException>()));
      await started.future;
      await service.dispose();
      await cancelled;
      pending.complete(_media);
      await expectLater(
        service.resolve(_episode, useLegacyParser: false),
        throwsA(isA<VideoSourceCancelledException>()),
      );
    });
  }, skip: !Platform.isWindows);
}
