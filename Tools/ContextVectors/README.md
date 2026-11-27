# 按上文选词

在 iPhone 或 iPad 的 Yah 键盘点候选栏左侧方案名，开启「按上文选词」。默认关闭。此选项适用于简体全拼的双字候选。例如前文是「医生表示病人需要」时，输入 `shuxue` 可以首选「输血」；前文是「老师表示学生需要」时首选「数学」。关闭后立即恢复 Rime 自身的排序。

键盘只读取光标前最多 12 个连续汉字，遇到标点、空格或换行即止。上文只在当前组字期间留在内存，离开键盘或结束组字时清除。用户默认设置中只保存开关。缺少上下文、模型未就绪或证据不足时沿用当前候选。翻到第二页、切换到其他方案或输出字形、进入社区输入以及选中部分拼音后，也沿用 Rime 的排序。

## 排名与模型

键盘在临时 Rime 会话中重放最后 2、3、4 个汉字的读音及当前拼音。至少两种长度的首选须包含原样前文，并支持首屏同一双字候选。随后用本机词向量比较同一上文词和各候选的相似程度。临时会话只查询，查询结束立即清空。正式选词仍通过原生 Rime 候选索引提交。

原始数据来自 fastText 发布的中文 Common Crawl 和 Wikipedia 词向量。Yah 按上游频率顺序选择 48,000 个长度为 2 至 4 个汉字的词，用固定有符号投影将 300 维折叠为 64 维，再逐词量化为有符号 8 位数。随键盘分发的文件为 4,032,016 字节，以只读内存映射访问。作者、数据源、衍生修改和 CC BY-SA 3.0 完整许可列在模型目录。[fastText 官方数据](https://fasttext.cc/docs/en/crawl-vectors.html) · [随包署名](../../Keyboard/ContextModel/NOTICE.txt) · [随包许可](../../Keyboard/ContextModel/LICENSE.txt)

在项目根目录运行以下命令重建模型。生成器在替换输出前核验固定 SHA-256。已下载原版 `cc.zh.300.vec.gz` 时可加 `--source` 指定本地文件。

```sh
python3 Tools/ContextVectors/rebuild.py
```

## 重跑 iOS 回归

先在 Xcode 解析 Yah 项目的 Swift Package 依赖，启动一个测试用 iOS 模拟器。将其 UDID 和 Xcode 的 `SourcePackages` 目录交给脚本。脚本安装临时测试 App，运行工程内实际的组字、Rime 与词向量代码，验证首选、禁用回退、标点边界与翻页、展开候选的上屏索引。测试结束会卸载本次创建的测试 App。

```sh
Tools/ContextVectors/test-ios.sh "$SIMULATOR_UDID" "$SOURCE_PACKAGES"
```

默认固定样例含教育、医疗、未参与调参的其他同音词、普通输入和同尾不同意图的对照。还可从本机 macOS 自带简体中文文案生成去重的额外盲测。不同 macOS 版本的系统应用、文案和分词词典可能不同，标注用于比较同一组输入的相对变化。

```sh
swift Tools/ContextVectors/Tests/make-blind-cases.swift > /tmp/yah-context-blind.tsv
Tools/ContextVectors/test-ios.sh "$SIMULATOR_UDID" "$SOURCE_PACKAGES" /tmp/yah-context-blind.tsv
```

2026-11-27 的独立 iOS 26.5 模拟器上，5,000 条去重盲测的首选命中从 4,457 升到 4,466。10 条改变排序，9 条由错变对，1 条两次均未命中。另一个 5,300 条对照批次出现过一次原本正确的首选退化，将「体感温度高于」后的「显示」提前排成「现实」。键盘 UI 回归覆盖默认关闭、开启后首选、翻页返回、选择第二项、先输入「病人需要」再从展开候选上屏「输血」，以及关闭开关后恢复「检查」。
