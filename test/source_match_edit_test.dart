import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/source_match_sheet.dart';
import 'package:venera/utils/translations.dart';

/// 换源搜索框必须能当场改书名。
///
/// 不同源给同一本书起的名千差万别（加汉化组、完本、DL 版，或者干脆是另一个
/// 译名），拿原书名一把搜不到是常态。原来这里是一行**只读文本**，用户看到
/// 「没找到」就只能退出去、自己到搜索页碰运气，所以这一格必须是输入框。
ComicSource _source(void Function(String keyword) onSearch) {
  return ComicSource(
    'Test Source',
    'test_source',
    null,
    null,
    null,
    null,
    const [],
    SearchPageData(
      null,
      (keyword, page, options) async {
        onSearch(keyword);
        if (keyword != '另一个译名') {
          return Res(const <Comic>[]);
        }
        return Res([
          const Comic(
            '另一个译名 第2卷',
            '',
            'id_2',
            null,
            null,
            '',
            'test_source',
            null,
            null,
          ),
        ]);
      },
      null,
    ),
    null,
    null,
    null,
    null,
    null,
    null,
    '/tmp/test_source.js',
    'https://example.com/test.js',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  tearDown(() {
    for (final source in ComicSource.all()) {
      ComicSourceManager().remove(source.key);
    }
  });

  testWidgets('换源面板能改书名并重新搜索', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    final queries = <String>[];
    ComicSourceManager().add(_source(queries.add));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () =>
                    showSourceMatchSheet(context, keyword: '[汉化组] 原标题'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 搜索框预填原始书名（不是清洗后的词），用户改的就是自己认识的那个名字。
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '[汉化组] 原标题');

    // 搜原始书名时按清洗后的词去请求，「没找到」的提示要告诉用户可以改书名。
    expect(queries, ['原标题']);
    expect(
      find.text("Can't find it? Edit the title above and search again"),
      findsOneWidget,
    );

    // 改成另一个译名，回车即重新搜索。
    await tester.enterText(find.byType(TextField), '另一个译名');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(queries, ['原标题', '另一个译名']);
    expect(find.text('另一个译名 第2卷'), findsOneWidget);
    // 上一次搜索的「没找到」必须已经被清掉。
    expect(
      find.text("Can't find it? Edit the title above and search again"),
      findsNothing,
    );
  });
}
