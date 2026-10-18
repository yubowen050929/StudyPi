import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/services/api/retry_policy.dart';
import 'package:Kelivo/core/services/api/tool_call_cancellation.dart';
import 'package:Kelivo/core/services/study/study_corpus.dart';
import 'package:Kelivo/core/services/study/study_mineru_indexer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Directory workspaceDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('studypi-mineru-indexer-');
    workspaceDir = Directory('${tempDir.path}/workspace')..createSync();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File writeMinerUBucket({
    String folder = '当代教育心理学_92-206',
    required String markdown,
    List<Map<String, dynamic>>? contentList,
  }) {
    final dir = Directory('${tempDir.path}/$folder')
      ..createSync(recursive: true);
    final mdFile = File('${dir.path}/notes.md')..writeAsStringSync(markdown);
    if (contentList != null) {
      File(
        '${dir.path}/notes_content_list.json',
      ).writeAsStringSync(jsonEncode(contentList));
    }
    return mdFile;
  }

  test(
    'slices MinerU Markdown, ignores fenced comments, maps content_list pages, and caches fast-model enrichment',
    () async {
      final mdFile = writeMinerUBucket(
        markdown: '''# 第4章 学习动机
**自我效能感**（Self-efficacy）指个体对自己能否完成某一行为的主观判断。

```python
# This comment inside a code fence is not a Markdown heading
print("hello")
```

## 4.1 期望价值理论
动机强度由期望与价值乘积决定：
\$\$M = E \\times V\$\$
其中 **期望** 与 **主观价值** 共同作用。''',
        contentList: [
          {
            'type': 'text',
            'page_idx': 0,
            'text': '第4章 学习动机 自我效能感（Self-efficacy）指个体对自己能否完成某一行为的主观判断。',
          },
          {'type': 'text', 'page_idx': 1, 'text': '4.1 期望价值理论 动机强度由期望与价值乘积决定'},
          {'type': 'equation', 'page_idx': 2, 'latex': r'$$M = E \times V$$'},
        ],
      );

      var modelCalls = 0;
      Future<String> fastModel(String system, String user) async {
        modelCalls++;
        final input = jsonDecode(user) as Map<String, dynamic>;
        final sections = input['sections'] as List;
        expect(sections, hasLength(2));
        return '''```json
{
  "sections": [
    {
      "sectionId": "sec-1",
      "summary": "界定自我效能感及其对行为选择的影响。",
      "concepts": ["自我效能感", "班杜拉"],
      "questions": ["什么是自我效能感？"]
    },
    {
      "sectionId": "sec-2",
      "summary": "阐述期望价值理论的核心乘积模型 M = E × V。",
      "concepts": ["期望价值理论", "主观价值"],
      "questions": ["期望与价值如何决定动机强度？"]
    }
  ]
}
```''';
      }

      final index = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'textbook-92',
        title: '教材 · 92—206页',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        corpusPageRange: const StudyPageRange(92, 206),
        fastModel: fastModel,
        fastModelId: 'deepseek-flash',
      );

      expect(modelCalls, 1);
      expect(index.indexMode, StudyIndexMode.fastModel);
      expect(index.modelId, 'deepseek-flash');
      expect(index.sections, hasLength(2));

      final sec1 = index.sections[0];
      expect(sec1.headingPath, ['第4章 学习动机']);
      expect(sec1.physicalPageRange, const StudyPageRange(1, 1));
      expect(sec1.corpusPageRange, const StudyPageRange(92, 206));
      expect(sec1.concepts, ['自我效能感', '班杜拉']);
      expect(sec1.questions, ['什么是自我效能感？']);
      expect(
        StudyMineruIndexer.readSectionText(index, 'sec-1'),
        contains(
          '# This comment inside a code fence is not a Markdown heading',
        ),
      );

      final sec2 = index.sections[1];
      expect(sec2.headingPath, ['第4章 学习动机', '4.1 期望价值理论']);
      expect(sec2.physicalPageRange, const StudyPageRange(2, 3));
      expect(sec2.formulas, [r'M = E \times V']);
      expect(sec2.summary, '阐述期望价值理论的核心乘积模型 M = E × V。');

      final indexMd = File(
        '${workspaceDir.path}/.studypi/index/textbook-92/INDEX.md',
      );
      expect(indexMd.existsSync(), isTrue);
      expect(indexMd.readAsStringSync(), contains('M = E \\times V'));

      // Second call hits SHA-256 cache without invoking the model again.
      final cached = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'textbook-92',
        title: '教材 · 92—206页',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        corpusPageRange: const StudyPageRange(92, 206),
        fastModel: fastModel,
        fastModelId: 'deepseek-flash',
      );
      expect(modelCalls, 1);
      expect(cached.sections.last.summary, sec2.summary);
    },
  );

  test(
    'falls back deterministically on invalid fast-model output and upgrades cache when a fast model later succeeds',
    () async {
      final mdFile = writeMinerUBucket(
        markdown: '''# 1 信息摩擦
Allen (2014) 通过搜寻模型刻画贸易中的信息摩擦：
\$\$\\pi_i = p_i - c_i\$\$''',
      );

      final fallbackIndex = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'allen-2014',
        title: 'Allen 2014',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        fastModel: (_, _) async => 'not valid json',
        fastModelId: 'broken-model',
      );
      expect(fallbackIndex.indexMode, StudyIndexMode.deterministicFallback);
      expect(fallbackIndex.modelId, isNull);
      expect(fallbackIndex.sections.single.formulas, [r'\pi_i = p_i - c_i']);
      expect(fallbackIndex.sections.single.concepts, contains('信息摩擦'));

      // Re-indexing with a working fast model upgrades the deterministic cache.
      final upgradedIndex = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'allen-2014',
        title: 'Allen 2014',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        fastModel: (_, _) async => jsonEncode({
          'sections': [
            {
              'sectionId': 'sec-1',
              'summary': 'Allen (2014) 量化农业贸易中的信息摩擦与价格离散。',
              'concepts': ['信息摩擦', '搜寻成本'],
              'questions': ['信息摩擦如何影响价格离散？'],
            },
          ],
        }),
        fastModelId: 'deepseek-flash',
      );
      expect(upgradedIndex.indexMode, StudyIndexMode.fastModel);
      expect(
        upgradedIndex.sections.single.summary,
        'Allen (2014) 量化农业贸易中的信息摩擦与价格离散。',
      );

      // Mutating the source Markdown invalidates readSectionText.
      mdFile.writeAsStringSync('# 1 修改后的原文');
      expect(
        () => StudyMineruIndexer.readSectionText(upgradedIndex, 'sec-1'),
        throwsStateError,
      );
    },
  );

  test(
    'propagates cancellation without writing partial index files and blocks unsafe documentId',
    () async {
      final mdFile = writeMinerUBucket(markdown: '# 标题\n正文内容');
      final entered = Completer<void>();
      final stopped = Completer<void>();
      final cancellation = ToolCallCancellation(
        isCancelled: () => stopped.isCompleted,
        cancelled: stopped.future,
      );

      final future = cancellation.run(
        () => StudyMineruIndexer.indexToWorkspace(
          documentId: 'cancel-doc',
          title: 'Cancel Test',
          markdownPath: mdFile.path,
          workspaceDir: workspaceDir.path,
          fastModel: (_, _) async {
            entered.complete();
            await stopped.future;
            return '{"sections":[]}';
          },
        ),
      );
      await entered.future;
      stopped.complete();
      await expectLater(future, throwsA(predicate(isUserCancelError)));
      expect(
        Directory(
          '${workspaceDir.path}/.studypi/index/cancel-doc',
        ).existsSync(),
        isFalse,
      );

      await expectLater(
        StudyMineruIndexer.indexToWorkspace(
          documentId: '../escape',
          title: 'Bad',
          markdownPath: mdFile.path,
          workspaceDir: workspaceDir.path,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'handles nested 4-backtick fences, avoids splitting multiline formulas, matches late blocks across gaps, and invalidates cache on metadata changes',
    () async {
      final longIntro = '引论段落详细展开背景信息。' * 12;
      final mdFile = writeMinerUBucket(
        folder: 'edge_bucket',
        markdown:
            '''# 第1节 嵌套围栏与公式
$longIntro

````markdown
```
# Nested heading inside 4-backtick fence
\$\$ignored_in_code = 1\$\$
```
````

\$\$
f(x) = \\int_0^x
  g(t) dt
\$\$

结尾关键结论：边际收益递减规律在长期均衡中成立。''',
        contentList: [
          {'type': 'text', 'page_idx': 0, 'text': '第1节 嵌套围栏与公式'},
          {'type': 'text', 'page_idx': 1, 'text': '这段 OCR 噪声未出现在整理后的正文中'},
          {'type': 'text', 'page_idx': 3, 'text': '结尾关键结论：边际收益递减规律在长期均衡中成立。'},
        ],
      );

      final fullIndex = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'edge-doc',
        title: 'Title V1',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        corpusPageRange: const StudyPageRange(1, 10),
      );
      expect(fullIndex.sections, hasLength(1));
      expect(
        fullIndex.sections.single.physicalPageRange,
        const StudyPageRange(1, 4),
      );
      expect(fullIndex.sections.single.formulas, [r'f(x) = \int_0^x g(t) dt']);

      // Splitting with a small maxSectionChars must not cut the multiline formula in half,
      // and must not return the cached 3600-char index.
      final splitIndex = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'edge-doc',
        title: 'Title V1',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        corpusPageRange: const StudyPageRange(1, 10),
        maxSectionChars: 220,
      );
      expect(splitIndex.sections.length, greaterThan(1));
      final allFormulas = [
        for (final sec in splitIndex.sections) ...sec.formulas,
      ];
      expect(allFormulas, [r'f(x) = \int_0^x g(t) dt']);

      // Updating title, corpusPageRange, or content_list.json invalidates the cache.
      final retitled = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'edge-doc',
        title: 'Title V2',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        corpusPageRange: const StudyPageRange(11, 20),
      );
      expect(retitled.title, 'Title V2');
      expect(retitled.corpusPageRange, const StudyPageRange(11, 20));

      File('${mdFile.parent.path}/notes_content_list.json').writeAsStringSync(
        jsonEncode([
          {'type': 'text', 'page_idx': 9, 'text': '第1节 嵌套围栏与公式'},
        ]),
      );
      final updatedPages = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'edge-doc',
        title: 'Title V2',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        corpusPageRange: const StudyPageRange(11, 20),
      );
      expect(
        updatedPages.sections.single.physicalPageRange,
        const StudyPageRange(10, 10),
      );

      for (final badId in [
        'CON',
        'CONIN',
        'CONOUT.json',
        'PRN.txt',
        'a:b',
        'bad.',
        '.hidden',
      ]) {
        await expectLater(
          StudyMineruIndexer.indexToWorkspace(
            documentId: badId,
            title: 'Bad ID',
            markdownPath: mdFile.path,
            workspaceDir: workspaceDir.path,
          ),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'repeated formula in a late chapter does not pull earlier section pages across middle sections, and leading multiline formula splits safely',
    () async {
      final trailingProse = '后续段落继续推导该公式在均衡分析中的性质与收敛条件。' * 12;
      final mdFile = writeMinerUBucket(
        folder: 'repeat_bucket',
        markdown:
            '''\$\$
y = \\alpha + \\beta x
\$\$
$trailingProse

# 第2节 中间章节
中间章节讨论工具变量识别条件与外生性检验。

# 第3节 全书总结
再次回顾线性基准方程：
\$\$y = \\alpha + \\beta x\$\$''',
        contentList: [
          {
            'type': 'equation',
            'page_idx': 0,
            'latex': r'$$y = \alpha + \beta x$$',
          },
          {'type': 'text', 'page_idx': 1, 'text': '后续段落继续推导该公式在均衡分析中的性质与收敛条件。'},
          {
            'type': 'text',
            'page_idx': 4,
            'text': '第2节 中间章节 中间章节讨论工具变量识别条件与外生性检验。',
          },
          {'type': 'text', 'page_idx': 49, 'text': '第3节 全书总结 再次回顾线性基准方程'},
          {
            'type': 'equation',
            'page_idx': 49,
            'latex': r'$$y = \alpha + \beta x$$',
          },
        ],
      );

      final index = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'repeat-doc',
        title: 'Repeat Formula Test',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        maxSectionChars: 220,
      );

      // Leading multiline formula stays intact in sec-1, and trailing prose splits into sec-2.
      expect(index.sections.first.formulas, [r'y = \alpha + \beta x']);
      expect(
        index.sections.first.physicalPageRange,
        const StudyPageRange(1, 1),
      );
      final middle = index.sections.singleWhere(
        (sec) => sec.headingPath.contains('第2节 中间章节'),
      );
      expect(middle.physicalPageRange, const StudyPageRange(5, 5));
      final summarySec = index.sections.singleWhere(
        (sec) => sec.headingPath.contains('第3节 全书总结'),
      );
      expect(summarySec.physicalPageRange, const StudyPageRange(50, 50));
    },
  );

  test(
    'enriches large books in bounded batches and keeps fallback for a failed batch',
    () async {
      final buf = StringBuffer();
      for (var i = 1; i <= 40; i++) {
        buf
          ..writeln('# Section $i')
          ..writeln('Body text of section number $i. ' * 40);
      }
      final mdFile = writeMinerUBucket(markdown: buf.toString());
      final requests = <List<String>>[];
      final index = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'big-book',
        title: 'Big',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
        fastModel: (_, user) async {
          final input = jsonDecode(user) as Map<String, dynamic>;
          final ids = [
            for (final item in input['sections'] as List)
              (item as Map)['sectionId'] as String,
          ];
          requests.add(ids);
          if (requests.length == 2) return 'truncated {"sections": [';
          return jsonEncode({
            'sections': [
              for (final id in ids) {'sectionId': id, 'summary': 'AI $id'},
            ],
          });
        },
        fastModelId: 'flash',
      );
      expect(requests.length, greaterThan(2));
      for (final batch in requests) {
        expect(
          batch.length,
          lessThanOrEqualTo(StudyMineruIndexer.fastModelBatchMaxSections),
        );
      }
      expect(requests.expand((ids) => ids).toSet(), hasLength(40));
      // One failed batch: not a complete fast-model index, so it is retried.
      expect(index.indexMode, StudyIndexMode.deterministicFallback);
      final failed = requests[1].toSet();
      for (final section in index.sections) {
        if (failed.contains(section.sectionId)) {
          expect(section.summary, isNot(startsWith('AI ')));
        } else {
          expect(section.summary, 'AI ${section.sectionId}');
        }
      }
      final leftovers = Directory(
        '${workspaceDir.path}/.studypi/index/big-book',
      ).listSync().map((e) => e.path).where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    },
  );

  test('a hung fast model times out into the deterministic index', () async {
    final mdFile = writeMinerUBucket(markdown: '# A\nSome body text here.');
    final never = Completer<String>();
    final index = await StudyMineruIndexer.indexToWorkspace(
      documentId: 'hung',
      title: 'Hung',
      markdownPath: mdFile.path,
      workspaceDir: workspaceDir.path,
      fastModel: (_, _) => never.future,
      fastModelTimeout: const Duration(milliseconds: 50),
    );
    expect(index.indexMode, StudyIndexMode.deterministicFallback);
    expect(index.sections.single.summary, contains('Some body text'));
  });

  test(
    'headings inside display math are ignored and a stray delimiter ends at a blank line',
    () async {
      final mdFile = writeMinerUBucket(
        markdown: [
          '# Real',
          r'$$',
          '# not a heading',
          'x = 1',
          r'$$',
          r'Broken $$ delimiter left open',
          '',
          '# Later heading',
          'After.',
        ].join('\n'),
      );
      final index = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'math',
        title: 'Math',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
      );
      expect(index.sections.map((s) => s.title), ['Real', 'Later heading']);
    },
  );

  test(
    'tiny content_list blocks such as page numbers do not claim pages',
    () async {
      final mdFile = writeMinerUBucket(
        markdown: '# 第一节\n工作记忆容量有限，需要组块策略来减轻负荷。',
        contentList: [
          {'type': 'text', 'page_idx': 4, 'text': '工作记忆容量有限，需要组块策略来减轻负荷。'},
          {'type': 'text', 'page_idx': 9, 'text': '12'},
          {'type': 'text', 'page_idx': 9, 'text': '组块'},
        ],
      );
      final index = await StudyMineruIndexer.indexToWorkspace(
        documentId: 'probe',
        title: 'Probe',
        markdownPath: mdFile.path,
        workspaceDir: workspaceDir.path,
      );
      expect(
        index.sections.single.physicalPageRange,
        const StudyPageRange(5, 5),
      );
    },
  );

  test('maps pages from MinerU middle JSON (pdf_info)', () async {
    final mdFile = writeMinerUBucket(
      markdown:
          '## 第九章知识的学习\n知识是个体通过与环境相互作用后获得的信息及其组织。\n'
          '## 一、知识的分类\n陈述性知识是关于是什么的知识。',
    );
    File('${mdFile.parent.path}/MinerU_book.json').writeAsStringSync(
      jsonEncode({
        'pdf_info': [
          {
            'page_idx': 0,
            'para_blocks': [
              {
                'type': 'text',
                'lines': [
                  {
                    'spans': [
                      {'type': 'text', 'content': '知识是个体通过与环境相互作用后'},
                      {'type': 'text', 'content': '获得的信息及其组织。'},
                    ],
                  },
                ],
              },
            ],
          },
          {
            'page_idx': 1,
            'para_blocks': [
              {
                'type': 'table',
                'blocks': [
                  {
                    'lines': [
                      {
                        'spans': [
                          {'type': 'text', 'content': '陈述性知识是关于是什么的知识。'},
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      }),
    );
    final index = await StudyMineruIndexer.indexToWorkspace(
      documentId: 'middle-json',
      title: 'Book',
      markdownPath: mdFile.path,
      workspaceDir: workspaceDir.path,
      contentListJsonPath: '${mdFile.parent.path}/MinerU_book.json',
    );
    expect(index.sections.map((s) => s.physicalPageRange), [
      const StudyPageRange(1, 1),
      const StudyPageRange(2, 2),
    ]);
  });
}
