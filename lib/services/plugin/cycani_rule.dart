import 'package:kazumi/plugins/plugins.dart';

Plugin buildCycaniRule() => Plugin.fromJson({
  'api': '8', 'type': 'anime', 'name': '次元城动画-内置登录',
  'version': '1.0', 'muliSources': false,
  'useWebview': true, 'useNativePlayer': true,
  'baseURL': 'https://www.cycani.org/',
  'referer': 'https://www.cycani.org/',
  'searchMode': 'api', 'chapterMode': 'api',
  'searchApiConfig': {
    'request': {'method': 'GET',
      'url': 'https://www.cycani.org/_kazumi/cycani/search',
      'query': {'q': '@keyword'}},
    'listPath': r'$.data.list[*]', 'namePath': r'$.title',
    'sourcePath': r'$.video_id',
  },
  'chapterApiConfig': {
    'request': {'method': 'GET',
      'url': 'https://www.cycani.org/_kazumi/cycani/chapters',
      'query': {'id': '@source'}},
    'format': 'nested', 'roadsPath': '', 'roadNamePath': '',
    'episodesPath': r'$.data.list[*]', 'episodeNamePath': r'$.title',
    'episodeUrlPath': r'$.kazumi_url',
  },
});
