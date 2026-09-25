# Windows 启动脚本

`wenyi` 本身是跨平台的命令行工具；这个目录里是给 Windows 用户准备的启动脚本，
把常用参数、EPUB 兼容处理和图形界面包好，省得每次手敲一长串命令。
它们只是辅助工具，不参与 `wenyi` 包本身的构建，也不改动核心代码。

| 文件 | 作用 |
| --- | --- |
| `wenyi-gui.cmd` / `wenyi-gui.ps1` | 图形界面（推荐入口） |
| `translate-doc.cmd` / `translate-doc.ps1` | 命令行入口：翻译、或从已有状态重新导出 |
| `epub-compat.cmd` / `epub-compat.py` | 把导出的 EPUB 重做成 NeatReader 这类阅读器能正常显示的版本 |
| `wenyi-paths.ps1` | 上面几个脚本共用的目录解析 |

## 依赖

- Windows PowerShell 5.1（系统自带）与 `cmd.exe`。
- wenyi 自己的虚拟环境：`wenyi\.venv`（按仓库 README 用 `uv sync` 装好）。
- 可选 **MiKTeX**（或任何提供 `pdflatex` 的 TeX 发行版）：只有「兼容 EPUB 的公式图片」
  需要它。没装也不影响使用，公式会自动退化成 Unicode 文本。
- 可选 **wenyi-babeldoc-bridge**：只有 `-PdfBackend babeldoc`（保留原版式的 PDF 后端）
  需要它；用 `-PdfBackend mineru` 或翻译 EPUB/Markdown 时不需要。

## 目录约定

脚本放在哪儿都能跑，`wenyi-paths.ps1` 会自动认出仓库和工作目录：

1. 脚本放在工作目录里，仓库是它的子目录

   ```
   C:\work\llm-translator\          <- 工作目录：脚本、babeldoc-sessions\、state*\
   C:\work\llm-translator\wenyi\    <- 仓库（含 pyproject.toml）
   ```

2. 脚本直接用仓库里的这份（例如 `wenyi\scripts\windows\`）

   工作目录取仓库的上一层（前提是那一层已经有 `babeldoc-sessions\` 或
   `wenyi-babeldoc-bridge\`），否则就用仓库自身。

想手动指定工作目录，设环境变量 `WENYI_WORKSPACE=<路径>` 即可。

工作目录里会生成：`babeldoc-sessions\`（会话与输出）、`state*\`（翻译状态，
默认在 `wenyi\` 下）、`wenyi-gui.settings.json`（界面记住了上次的选项）。
这些都已经写进 `.gitignore`，不会被误提交。

## 图形界面

双击 `wenyi-gui.cmd`。界面只是把选项拼成 `translate-doc.ps1` 的命令行，翻译逻辑一套都不重复：

- **检查配置 / 预览命令**：`-DryRun`，只打印将要执行的命令与预计输出路径，不翻译、不改状态；
  勾了兼容 EPUB 时，还会顺带打印一次公式渲染器自检（`--check-renderer`）。
- **开始翻译**：在独立命令行窗口里执行，进度和结果都在那个窗口里。
- **仅导出（不翻译）**：`-Assemble`，从已有译文重新导出，不调用模型、不需要 API key。

默认值：目标语言 `zh`、PDF 后端 `babeldoc`、**兼容 EPUB 默认勾选**、公式处理默认
「混合」。上次的选项会记在 `wenyi-gui.settings.json`，下次打开自动带出来。

## 命令行

```powershell
# 翻译（默认输出 epub 到文档旁的 output\ 目录）
.\translate-doc.cmd "D:\books\book.pdf"

# 常用组合：MinerU 云端解析 + 顺带生成 NeatReader 用的兼容版
.\translate-doc.cmd "D:\books\book.pdf" -PdfBackend mineru -CompatEpub

# 只跑一遍检查，不翻译
.\translate-doc.cmd "D:\books\book.pdf" -DryRun

# 从已有状态重新导出（不调用模型）
.\translate-doc.cmd "D:\books\book.pdf" -Assemble
```

| 参数 | 说明 |
| --- | --- |
| `-Target` | 目标语言，默认 `zh`；还支持 `zh-Hant en ja ko fr de es it pt ru` |
| `-PdfBackend` | `babeldoc`（默认，保留原版式，需要本地 bridge）或 `mineru`（云端） |
| `-StateDir` | 状态目录名，默认 `state`（MinerU 常用 `state-mineru`） |
| `-Format` | 导出格式，默认按输入自动；可指定 `epub pdf txt html markdown docx` |
| `-Out` | 指定输出路径 |
| `-Assemble` | 只导出，不翻译 |
| `-SkipReview` | 跳过审校（更快） |
| `-CompatEpub` | 额外生成 `<文件名>-compat.epub` |
| `-FormulaMode` | 兼容版的公式处理：`hybrid`（默认）\| `text` \| `image` |
| `-Reset` | 翻译前清空这本书的运行状态 |
| `-RestartBridge` | 先重启 BabelDOC 服务（遇到 HTTP 502 之类的桥错误时用） |
| `-DryRun` | 只检查、只打印命令 |

## 兼容 EPUB 与公式

不少阅读器（NeatReader 等）对 EPUB 里的 MathML 支持不好，公式会显示成乱码或空白，
所以 `-CompatEpub` 会重做一份副本：把 `<math>` 换掉，顺带补封面、补 `style.css`、
规范化 OPF 元数据，并给每次生成的副本换一个新的 `urn:uuid`（阅读器会当新书导入）。

公式有三种处理方式：

- **`hybrid`（默认）**：能用 Unicode 表达的转成真文本（`Aₜ`、`Δ`、`θᴴ`）；分式、矩阵、
  带上下限的求和这类 2D 结构用 MiKTeX 渲染成 PNG 插图。博客/论文类 PDF 体感最好。
- **`text`**：全部转文本，不需要 MiKTeX，体积最小，但复杂公式会退化成 `_(...)` 写法。
- **`image`**：全部渲染成图片，最接近原版式，体积最大。

细节：

- 图片按公式去重，重跑走缓存（`%TEMP%\wenyi-formula-cache`），第二次几乎瞬间完成。
- 渲染失败（没装 MiKTeX、缺宏包、超时）只会让那一条公式退化成文本，不会中断整次转换。
- 只处理带 LaTeX 注解的 MinerU 公式；公式编号 `\tag{}` 会剥出来排在公式右侧。

单独运行转换器：

```powershell
.\epub-compat.cmd "D:\books\book.epub"                       # 输出 <文件名>-compat.epub
.\epub-compat.cmd "D:\books\book.epub" "D:\out\book-zh.epub" --formulas=image
.\epub-compat.cmd --check-renderer                            # 自检 MiKTeX / Pillow / PyMuPDF
.\epub-compat.cmd --sample-sheet="D:\out\formula-sample.png"  # 生成公式样张，肉眼确认渲染效果
```

`epub-compat.py` 需要 Pillow（封面）和 PyMuPDF（公式栅格化），这两个装在
`wenyi-babeldoc-bridge\.venv` 里；`epub-compat.cmd` 会自动挑一个装齐了的解释器。

## 常见问题

- **公式全是文本、没有图片**：跑 `epub-compat.cmd --check-renderer` 看结论，多半是没装
  MiKTeX，或者 `pdflatex` 不在 `PATH` 里。装好 MiKTeX 后重跑即可，缓存里的条目不受影响。
- **阅读器里书打不开 / 一直转圈**：先确认拿到的是兼容版（`-compat.epub`）；它带封面和
  新 uuid，正常情况下能被当成新书导入。
- **封面是空白或没有封面**：封面用 PIL 画中文标题，缺中文字体会跳过（不影响正文）。
- **`找不到 wenyi 仓库`**：脚本要求 `wenyi` 的 `pyproject.toml` 在脚本所在目录、它的
  `wenyi\` 子目录，或某个上层目录里。用 `WENYI_WORKSPACE` 指定工作目录也行。
- **`pwsh` 不是命令**：这些脚本面向 Windows 自带的 Windows PowerShell 5.1，
  直接双击 `.cmd`，或 `powershell -File .\translate-doc.ps1 ...`（不需要 PowerShell 7）。
