import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/comic_update_time.dart';

/// 详情页快照（存进本地漫画目录的 details.json）靠 ComicDetails 的
/// toJson / fromJson 往返。这里锁住三件事：
/// 1. 往返之后页面要用的字段不能丢（标题、副标题、章节表、封面、maxPage）；
/// 2. 老版本写下的 `subTitle` 键仍能读出来——不然已经下载过的漫画升级后
///    副标题会静默消失；
/// 3. 章节表无论是平铺还是分组都要能还原。
ComicDetails _sample(Map<String, dynamic> extra) {
  return ComicDetails.fromJson({
    "title": "Sample",
    "subtitle": "Sub",
    "cover": "https://example.com/cover.jpg",
    "description": "Desc",
    "tags": {
      "author": ["Someone"],
      "更新": ["2026-11-01"],
    },
    "chapters": {"0": "Chapter 1", "1": "Chapter 2"},
    "sourceKey": "demo",
    "comicId": "42",
    "maxPage": 18,
    "stars": 4.5,
    ...extra,
  });
}

ComicDetails _roundTrip(ComicDetails details) {
  return ComicDetails.fromJson(
    Map<String, dynamic>.from(jsonDecode(jsonEncode(details.toJson()))),
  );
}

void main() {
  group('ComicDetails 序列化（详情快照）', () {
    test('往返保留详情页要用的字段', () {
      final round = _roundTrip(_sample(const {}));
      expect(round.title, "Sample");
      expect(round.subTitle, "Sub");
      expect(round.cover, "https://example.com/cover.jpg");
      expect(round.description, "Desc");
      expect(round.comicId, "42");
      expect(round.sourceKey, "demo");
      expect(round.chapters?.length, 2);
      expect(round.chapters?.allChapters["1"], "Chapter 2");
      // 少了 maxPage，详情页的阅读进度条会凭空消失；少了 stars，评分也会没。
      expect(round.maxPage, 18);
      expect(round.stars, 4.5);
    });

    test('标签里的更新时间能重新解析出来', () {
      final round = _roundTrip(_sample(const {}));
      // 快照里存的是 "2026-11-1"（没有补零），角标那边要能照样解析成日期。
      final time = parseComicDate(round.findUpdateTime()!);
      expect(time, DateTime(2026, 11, 1));
    });

    test('旧版本写下的 subTitle 键仍然可读', () {
      // 1.4.27 之前的 toJson 把副标题写成 "subTitle"，老快照里就是这个拼法。
      final round = ComicDetails.fromJson({
        "title": "Old",
        "subTitle": "Legacy sub",
        "cover": "c",
        "tags": {},
        "sourceKey": "demo",
        "comicId": "1",
      });
      expect(round.subTitle, "Legacy sub");
    });

    test('分组章节表往返后仍然是分组的', () {
      final details = ComicDetails.fromJson({
        "title": "Grouped",
        "subtitle": "",
        "cover": "c",
        "tags": {},
        "chapters": {
          "Season 1": {"0": "E1", "1": "E2"},
          "Season 2": {"0": "E1"},
        },
        "sourceKey": "demo",
        "comicId": "7",
      });
      final round = _roundTrip(details);
      expect(round.chapters?.isGrouped, isTrue);
      expect(round.chapters?.groupCount, 2);
      expect(round.chapters?.length, 3);
    });

    test('没有章节的图集也能往返', () {
      final details = ComicDetails.fromJson({
        "title": "One shot",
        "cover": "c",
        "tags": {},
        "chapters": null,
        "sourceKey": "demo",
        "comicId": "8",
        "maxPage": 3,
      });
      final round = _roundTrip(details);
      expect(round.chapters, isNull);
      expect(round.maxPage, 3);
    });
  });
}
