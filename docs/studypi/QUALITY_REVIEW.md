# StudyPi 首轮质量审查

基线：`d6a82abc`，分支 `codex/studypi-foundation`，开始时工作区干净。
这是一次定向审查与修复，不是全项目无缺陷或可发行的保证。

## 范围与结论

优先检查聊天准备/取消/终态收尾、流式检查点、材料索引来源关系；
同时查看学习提示组装、记忆快照与全量注入的关键调用点和现有测试。
后两项本轮未发现有充分证据的新问题，不代表已覆盖所有协议或真实模型行为。

先保住“用户能停止任务、输出能保存、引用不串书”，再推进已有 M1 路线；
本轮不加入账号、自动多模型路由或远端执行，也不改数据库 schema 和发行身份。

## 已修复问题

### P1：已取消的旧准备任务干扰新一轮生成

- 触发：文件提取、OCR 或上下文读取尚未返回时停止；停止完成后在同一会话重新发送；旧准备任务随后抛错。
- 原行为：旧任务再次进入终态收尾、上报过期错误，甚至清掉新任务的加载标记。失败收尾本身在等待写库时被新任务取代，也有同样问题。
- 修复：发送、重新生成和工具问答续接都先核对活跃消息身份；停止已接管的任务不再重复收尾。异步收尾结束时不能清掉替代任务的加载状态或报告旧错误。
- 位置：`lib/features/home/controllers/chat_actions.dart`。
- 回归：`test/features/home/controllers/chat_actions_prepare_lifecycle_test.dart` 的 5 项用例。
  原有失败上报测试补齐活跃消息前提，仍保留“写库也失败时原始错误必须到达 UI”的断言。

### P1：不同书籍的相同页段被配成同一来源

- 触发：同一教材目录含 `BookA_1-20.pdf`、`BookB_1-20.pdf`，只有 BookB 的解析稿。
- 原行为：只凭页码和排序把 BookB 的解析稿挂到 BookA 原文，用户可能得到错误的出处。
- 修复：页码和来源名称都必须匹配；保留书名内部的分隔符。相同来源优先唯一的专用页段；同等候选有歧义则不自动关联，原文和解析稿都继续保留。
- 位置：`lib/core/services/study/study_corpus.dart`。
- 边界：这是基于文件名的本地索引，不是内容校验或正式材料导入；不能由名称推断两份文件内容一致。

### P2：合并材料漏掉未解析页段

- 触发：PDF 包含 `1-10`、`11-20` 两段，但只有前一段解析稿；或一个解析目录自身覆盖多段。
- 原行为：配对第一段就把整份 PDF 视为已处理，后一段消失；解析目录也只记录第一段。
- 修复：按“文件 + 页段”记录配对，展开每个页段；没有解析稿的部分仍作为可读取原文保留。
- 同时修正输入目录带尾部分隔符时科目名变空，并稳定同页段的排序。
- 回归：`test/core/services/study/study_corpus_source_integrity_test.dart` 共 10 项，覆盖来源、歧义、专用页段、组合页段和路径。

### P2：同步异常使后续流式检查点停止写入

- 触发：构建快照或调用写入回调时同步抛错，而不是返回一个异步失败的 Future。
- 原行为：队列清理发生在 `add()` 赋值之前，留下已完成的 `_drainFuture`，后续 `add()` 无法再启动写入。
- 修复：用 `Future.sync` 统一同步/异步异常的调度；仍保留串行写入、只保留最新待写快照和终态等待在途写入的规则。
- 位置：`lib/features/home/controllers/latest_wins_checkpoint_writer.dart`。
- 回归：`test/features/home/controllers/latest_wins_checkpoint_writer_recovery_test.dart` 的 2 项用例。
### P1：生成尝试级取消传播与迟到流回调隔离

- 触发：
  1. 准备阶段（哈希计算、首张图片 OCR、多文档提取）用户点击停止，或父级取消信号已触发但子 HTTP 请求（如 OCR / 嵌套请求）仍在运行；
  2. 取消屏障超时后，旧流继续到达 chunk / error / finish，或旧任务卡在 `onAssistantMessageFinished` 期间用户开启了新一轮生成（包括同一条助手消息在工具回答后恢复续接）。
- 修复：
  - 新增 `GenerationAttempt`（`lib/core/services/chat/generation_attempt.dart`），为每次生成尝试分配独立令牌与 `requestId`，同会话或同一条消息的后续续接都会使旧尝试失效；
  - `ChatApiService.sendMessageStream` 与 `OcrService` 接入父级 `ToolCallCancellation`，停止后立即中断子请求且不再继续后续图片 OCR 或写入缓存/构件；
  - `ChatActions` 的流式 chunk、error、finish、done 与完成回调全链路校验 `_canPublishAttempt(attempt)`，旧尝试无法污染新尝试状态或触发标题/摘要/建议副作用。
- 回归：
  - `test/features/home/controllers/chat_actions_prepare_lifecycle_test.dart`（12 项）
  - `test/features/home/services/ocr_cancellation_test.dart`（2 项）
  - `test/core/services/api/generation_parent_cancellation_test.dart`（2 项）

### P2：语料索引空书名误配与逆序/零页段过滤（`gpt-6-luna-YG` 审查发现）

- 触发：文件名仅有页段和连接符（如 `1-20.pdf`、`_-1-20.pdf`）导致来源名为空并被当作同名配对；或文件名含 `20-1`、`0-10` 等无效页段。
- 修复：`_matchPdf` 拒绝空 `sourceName`；`_pageRanges` 仅接受 `start > 0 && start <= end` 的有效页段。
- 回归：`test/core/services/study/study_corpus_source_integrity_test.dart`（12 项）。

## M1 可追溯最小学习闭环（已落地核心与存储层）

按 M1 路线新增 `lib/core/services/study/study_project_store.dart` 并扩展 `study_prompts.dart` 与 `chat_database_repository.dart`：

1. **材料身份与状态**：`StudyProjectStore.importFile` 计算真实字节 SHA-256 与物理页数，区分同名不同内容文件；明确标记 `ready`、`scannedNeedsOcr`（扫描件无提取文本且无解析稿）、`unreadable`、`pendingSourceLink`（候选原文待确认，不默猜）。
2. **物理页码与教材页段分离**：`StudySourceDocument` 分别保存 PDF `physicalPageCount`（`1..N`）与 `corpusPageRange`（如 `92—206`）；`confirmSourceLink` 校验候选列表、拒绝损坏 PDF 并自动合并同哈希重复记录。
3. **讲解/引导模式与提示分层检查**：`StudyPrompts.compose` 与 `StudyPrompts.inspect` 支持 `StudyInteractionMode.explain` / `guidedPractice`，展示固定 Soul、模式指令与自定义指令的层次关系，并对自定义指令与项目上下文执行 XML 转义防止标签注入。
4. **带真实原文定位的笔记与跨项目隔离**：`StudyProjectStore.saveNote` 校验同项目来源、SHA-256 版本、物理页界限、教材页段界限与原文摘录；任一条件不满足或跨项目引用均标记为 `StudyEvidenceStatus.insufficientEvidence`，且拒绝跨项目 `noteId` 覆盖。新增实体纳入 SQLite 备份合并（`mergeBackupSnapshot`）。
5. **独立子代理审查闭环**：使用 `cliproxyapi/gpt-6-luna-YG` 完成 4 轮独立只读代码审查，发现并修复跨项目 `noteId` 覆盖、扫描件重导升级、同哈希确认合并、XML 转义和畸形 JSON 防御性解析等问题，见 `test/core/services/study/study_project_store_test.dart`。

## 第二轮：可核查引用、MinerU 索引加固与回归修复（2026-10-18）

### 可核查引用协议（新增）

- 格式：`[[cite doc="材料id" sec="sec-3" page="12" book_page="95" quote="原文摘录"]]`。
  `page` 是 PDF 文件内的物理页，`book_page` 是书上印刷的页码，不互相换算。
- `StudyCitationResolver`（`lib/core/services/study/study_citation_resolver.dart`）跳过代码块和行内代码，
  解析字段与转义，并逐项核对：材料是否存在且就绪、来源版本、章节是否在当前索引中、页码范围、
  页码与所在章节页段是否一致、摘录是否真的出现在所引章节或全文。
- 只有页码或章节号的引用只说明去哪里查，不算证据。笔记只有在每个锚点都带有核实过的摘录时
  才是 `grounded`；锚点会记下解析到的 `sectionId` 和来源哈希。
- 摘录比对容忍换行、Markdown 强调、`$`、弯引号；拉丁/希腊/西里尔文字和数字之间保留词边界
  （`the rapist` 不会匹配 `therapist`），中文句内的换行忽略。少于 6 个字符的摘录不计为证据。
- 系统提示中加入 `StudyPrompts.citationProtocol`（`studypi-cite-v1`）。
- 边界：聊天回复中的标记**尚未**在界面上核验或渲染，目前只在保存笔记时生效；
  因此协议文本不承诺“系统会核对”。回复渲染与原文跳转属于 M1 的界面部分。

### 已修复问题

| 级别 | 问题 | 修复 |
| --- | --- | --- |
| P1 | 上一轮的生成尝试改动使 12 项现有测试失败（工具问答续接、原生历史恢复、MCP 取消），先前的“全部通过”记录不成立 | 续接的生成在 `attempt.run` 内部正常收尾，`run` 却因 `finish()` 把成功结果当作取消抛出，用户看到 `tool_call_cancelled` 报错。现在只有取消（含被新尝试取代）才丢弃结果。另把两处测试同步到新的取消异常类型与 `attempt.run` 写法 |
| P1 | 快模型索引把整本书所有章节放进一次请求，输入或输出截断后整本回退 | 按 16,000 字 / 16 节分批，每批独立超时（默认 90 秒）与回退；全部批次成功才标记 `fastModel`，否则下次重试 |
| P1 | 快模型调用没有超时，挂起的请求会让索引永远不结束 | 同上，每批 `timeout` |
| P1 | 未建立索引的长材料整本内联进系统提示 | 超过 12,000 字不内联，标注 `content="not_inlined"` 并提示先建立索引 |
| P1 | 笔记锚点只校验页码范围，摘录在全书任意位置出现即通过 | 改用 `StudyCitationResolver`，有索引时核对章节与页段 |
| P2 | PDF 解析、整本哈希等同步 I/O 在 UI isolate 上执行 | 导入、确认来源、索引准备与索引校验移到 `Isolate.run`；大文件分块哈希 |
| P2 | `listDocuments` / `listNotes` 读取所有项目的记录再过滤 | `ExtensionEntityStore.listByOwner` 在 SQL 中按项目过滤 |
| P2 | `confirmSourceLink` 可替换已就绪材料的来源 | 只接受 `pendingSourceLink` 状态，且所选 PDF 必须在候选列表中 |
| P2 | 同一解析稿重复导入生成多条待确认记录 | 按内容哈希与候选集合去重 |
| P2 | 工作区索引只核对文档 id 和 PDF 哈希 | 同时核对解析稿路径、教材页段、文本材料自身哈希 |
| P2 | `$$` 公式块中的 `# ...` 被当作章节标题 | 切片时跟踪公式块；空行结束公式状态，避免一个落单的 `$$` 吞掉后面所有标题 |
| P2 | 页码、图号等短块使章节获得错误的物理页 | `content_list` 探针少于 6 字不参与页码映射 |
| P2 | `index.json` 直接覆盖写入，中断后可能损坏 | 唯一临时文件写入后改名；先写 `INDEX.md`，`index.json` 作为提交点 |
| P2 | 子请求结束后，父级取消监听仍持有其令牌 | 请求结束时解除引用 |

### 回归

- `test/core/services/study/study_citation_resolver_test.dart`：16 项。
- `study_mineru_indexer_test.dart` 新增 4 项（分批与部分失败、超时、公式内标题、短探针）。
- `study_project_store_test.dart` 新增 2 项（来源确认守卫、待确认去重、长材料不内联、摘录证据与页段一致性、过期索引）。
- `test/core/services/chat/generation_attempt_test.dart`：3 项。

### 已知限制

- 章节以行号定位，单行超长的解析稿（数万字一行）不会再拆分。
- 没有逐页文本时，只能检查“摘录所在章节的页段”是否包含所引页码，不能确认摘录位于该页。
- 回复中的引用尚未在界面上核验、渲染或跳转原文；学习项目还没有接入应用界面。

## 第三轮：学习项目界面、回复引用角标与原文跳转（2026-10-18）

M1 的第一个可用闭环已接入应用：**建项目 → 导入材料 → 建索引 → 在项目讨论中提问 → 点角标核对原文 → 存为笔记**。

### 数据与接线

- `StudyProjectProvider`（`lib/features/study/providers/`）是学习状态的唯一持有者，注册在 `main.dart`。
  导入的文件**复制**到 `<appData>/study/<项目id>/sources/`：Android 选择器给出的是缓存副本，
  原文件也不能在记录哈希之后被改动。字节相同的重复导入只保留一份。索引写在同一项目目录的 `.studypi/index/`。
- 与项目绑定的会话在系统提示末尾追加：学习模式、引用协议和项目材料（有索引时只给章节图）。
  普通会话不变。组装失败时照常发送，不阻断聊天。
- 改模式、改目标会立刻体现在下一次请求里（每次从存储读取）。

### 回复中的引用

- 绑定会话里的 `[[cite …]]` 改写成现有的引用角标（`[citation](studycite-N)`），按每个文本块编号。
  核实失败或只有页码、没有原文摘录的角标显示警示色。点开后显示核对结果、逐条原因、材料/章节/页码/摘录，
  可以“查看原文”（跳到章节并显示被引用的原文）或“存为笔记”。
- 流式输出时，尚未写完的标记先隐藏（最多 600 字符，避免正文里提到语法时被一直藏住）。
- 朗读（TTS）跳过引用标记。

### 界面（argon 起草，主代理验收修改）

- 入口：手机侧边栏底部的“学习项目”按钮；桌面导航栏新增“学习”标签（索引 4，原有标签顺序不变）。
- 项目列表（手机为单列，桌面为左侧列表加右侧详情）、项目页（目标与模式、材料、讨论、笔记）、
  原文阅读页（章节目录、上一节/下一节、被引用原文提示；未建索引时分段显示全文并提示建立索引）、
  引用详情（手机用底部面板，桌面用对话框）。新增 105 条 `study*` 文案（简体、繁体、英文）。

### 审查与修复

| 来源 | 问题 | 处理 |
| --- | --- | --- |
| sonnet | 一条回复被拆成多个文本块（工具调用或按段落分气泡）时，状态里只缓存一份改写结果，点击角标会打开别的引用 | 每个块各自持有改写结果，点击回调直接用该块的数据；补组件测试 |
| sonnet | 自定义提示词被整体 XML 转义，所有用户的 `<thinking>`、`A & B` 都会变样，影响普通聊天 | 只处理包装层的结束标签 |
| sonnet | 引用核对器加载失败后，流式输出的每一帧都会重新加载 | 失败后 30 秒内不再重试 |
| sonnet | 摘录归一化逐字符跑正则，长材料首次核对会卡界面 | 改为按码点判断 |
| sonnet | 删除文件失败时数据库与界面缓存不一致；导入失败留下拷贝 | 先更新记录与缓存，文件清理改为尽力而为；失败时删除拷贝 |
| sonnet | 每次发消息都把整本书的行列表从后台 isolate 拷回来 | 组装提示时只取章节图 |
| sonnet | 标记紧跟 `!` 时会被解析成图片 | 中间插入零宽空格 |
| sonnet | 标记语法与项目存储耦合，TTS 因此引入整套存储代码 | 拆出 `study_citation_syntax.dart` |
| haiku | 桌面端学习页常驻，却整体监听 `ChatService`，聊天流式输出时整个项目页随之重建 | 只订阅绑定会话的标题 |
| haiku | 阅读页、项目页的读取失败会让转圈永不结束；多个写操作失败时没有提示 | 读取失败落到空状态；写操作统一用 `runStudyAction` 提示错误 |
| haiku | 桌面阅读对话框较窄时会弹出底部面板（违反桌面规范） | 桌面固定使用双栏 |
| haiku | 长标题撑破标题栏 | 单行省略 |

### 回归

- `test/features/study/study_project_provider_test.dart`（5 项）：复制导入与去重、建索引后核对引用、存笔记、删除清理、
  绑定会话的提示注入与普通会话不变、标记改写与流式隐藏、朗读跳过标记。
- `test/features/study/study_chat_citation_test.dart`：多文本块各自打开正确的引用，未核实的角标显示警示色。
- `test/features/study/study_projects_page_test.dart`（argon）：通过界面创建项目并出现在列表中。

### 已知限制

- 没有在真机或桌面实际运行界面；版式只经过组件测试和代码审查。320dp、大字号和读屏需要真机验收。
- 快模型增强索引还没有界面入口，目前界面上建立的都是不调模型的确定性索引。
- 教材页段（`corpusPageRange`）只能在导入时写入，界面上不能修改；原文 PDF 只能整份打开，不能跳到指定页。
- iOS 上应用容器路径会随更新变化，而材料按绝对路径记录；首发以 Android 为准。
- 学习项目目录不在现有备份范围内：数据库记录会被备份，复制进来的材料文件不会。

## 验证记录

工具链：项目自带 Flutter 3.47.6 / Dart 3.13.5，命令前设置：

```bash
export PATH="$PWD/.scratch/flutter/bin:$PATH"
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos lib test integration_test
flutter test
```

- 格式检查：`dart format --output=none --set-exit-if-changed lib test` 0 个文件需要修改。
- 静态分析：`dart analyze --fatal-infos lib test integration_test` 无问题。
- 全量测试（第二轮，2026-10-18）：8,089 项通过，1 项跳过，0 失败。
- 全量测试（第三轮，2026-10-18）：8,096 项通过，1 项跳过，0 失败。日志：`.scratch/quality-review/round3-full-tests.log`。
  `flutter gen-l10n` 重新生成后无差异。
  第一轮记录的“全部通过”经复查不成立：同一工作区当时有 12 项失败，已在第二轮修复。
- 品牌切换（2026-10-18）：全量 8,103 项通过，1 项跳过，0 失败；Android `OAuthLifecycleTest` 54 项通过；
  arm64 release APK 经 `aapt2`/`apksigner` 核对：包名 `app.studypi`、名称 StudyPi、仅 arm64-v8a、
  OAuth scheme 与全部 provider authority 均为 `app.studypi` 前缀，已签名。
  工作区不要放在 iCloud 同步目录（如桌面）：文件被换成占位后读取变慢，静态门禁与计时类测试会超时。
- 第二轮的独立复审由 `gpt-6-luna-YG` 子代理完成 3 次（取消链路、索引与存储、引用协议），结论均已处理或列入已知限制。

单元/组件测试不替代 Android 真机安装、后台运行、语音权限和真实模型教学行为验收。
