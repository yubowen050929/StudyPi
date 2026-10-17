# StudyPi 项目入口

日期：2026-10-17。代码基线：Kelivo `4588c264fb57aaf455f7e6f9a00b0c06e44cc163`。
本地工作分支：`codex/studypi-foundation`。

用户已确认：个人深度学习与研究优先；Android 优先，兼顾桌面架构；参考
`stablyai/orca` 与 Pi 的设计理念。

## 文档

- [产品设计](PRODUCT_DESIGN.md)：核心学习流程、Soul 的行为原则、功能改造清单与扩展想法。
- [技术架构](ARCHITECTURE.md)：现有代码证据、路由与 agent 分工、双环境、账号和同步边界。
- [实施路线与验收](ROADMAP.md)：按可运行的纵向功能分期，而不是一次替换所有模块。
- [行为评估用例](../../evals/study/behavior_cases.json)：用于真实模型评估的输入与评分条件。

## 本次落地范围

新增版本化的 [StudyPrompts](../../lib/core/services/study/study_prompts.dart)，
在聊天请求的系统提示组装入口接入学习核心，包括没有自定义提示词的请求。
现有助手和单会话自定义指令继续作为后续层组装，变量替换沿用原流程；
完整组装结果纳入现有上下文计数与日志。
新建安装的学习模式默认卡片改用可调整的引导练习指令。

这是一版提示词与架构基础。多模型自动路由、结构化学习状态、云端运行服务、
StudyPi 账号、整体界面和品牌切换都仍待实现。
现有用户已保存的提示卡片不自动重写；旧卡片可能需要用户在编辑器中重置或修改。

## 当前开发环境

已在项目忽略目录 `.scratch/flutter/` 安装 Flutter **3.47.6 / Dart 3.13.5**，与上游 CI 的 Flutter 版本一致。
运行检查时将项目 SDK 加入当前进程的 PATH，备份进程测试会直接启动 `dart` 子进程：

```bash
PATH="$PWD/.scratch/flutter/bin:$PATH" flutter test
PATH="$PWD/.scratch/flutter/bin:$PATH" dart analyze --fatal-infos lib test integration_test
```

无需修改系统全局 PATH，也未修改全局 Flutter 配置。

验证记录见 [ROADMAP](ROADMAP.md)。单元与组件测试只能证明接线、数据与界面逻辑；
真实模型的教学行为、Android 麦克风和后台运行必须另行验收。
