"""把 EPUB 重做成"通吃型"：公式转文本/图片、补封面、规范化元数据。

用法：
    python epub-compat.py <来源.epub> [<输出.epub>] [--formulas=hybrid|text|image]
    python epub-compat.py --check-renderer          # 检查 MiKTeX 能不能用
    python epub-compat.py --sample-sheet [<输出.png>]

针对三类已知的阅读器毛病：
1. MathML：NeatReader 等对 <math> 支持不佳。默认 hybrid：能用 Unicode 表达的
   公式转成真文本（Aₜ、Δ、θᴴ），分式/多行矩阵这类 2D 结构用 MiKTeX 渲染成 PNG；
2. 封面/元数据：NeatReader 官方帮助说明按规范设置的封面才提取得出，且实测有
   “用 Sigil 重新保存一次就能打开”的案例，所以这里补一张封面、并把 OPF 的
   元数据规范化（去掉 opf: 前缀、补 dc:creator、补 cover 声明与 guide）；
3. 内容目录改成 OEBPS/ 并补上 style.css，与常见阅读器最能接受的布局一致。

只要公式渲染失败就退回纯文本，绝不阻塞；mimetype 仍保持“第一个条目 + 不压缩”。
"""

from __future__ import annotations

import os
import posixpath
import re
import subprocess
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

XHTML_NS = "http://www.w3.org/1999/xhtml"
EPUB_NS = "http://www.idpf.org/2007/ops"
OPF_NS = "http://www.idpf.org/2007/opf"
DC_NS = "http://purl.org/dc/elements/1.1/"
CONTAINER_NS = "urn:oasis:names:tc:opendocument:xmlns:container"
MATHML_NS = "http://www.w3.org/1998/Math/MathML"
MATH_TAG = f"{{{MATHML_NS}}}math"
SKIP_TAGS = {f"{{{MATHML_NS}}}annotation", f"{{{MATHML_NS}}}annotation-xml"}

CONTENT_DIR = "OEBPS"  # 与常见阅读器最能接受的布局一致（Calibre/Sigil 也用这个）
STYLE_NAME = "style.css"
COVER_IMAGE_NAME = "cover.png"
COVER_PAGE_NAME = "cover.xhtml"
COVER_IMAGE_ID = "cover-img"  # Calibre 惯例，NeatReader 认这个 id
COVER_PAGE_ID = "cover-page"
FORMULA_DIR = "formulas"
FORMULA_FONT_PT = 10
FORMULA_SCALE = 4  # 光栅化倍数：10pt × 4 ≈ 300–400 DPI
FORMULA_PAD_PX = 6
FORMULA_TIMEOUT = 20
FORMULA_CACHE = os.path.join(tempfile.gettempdir(), "wenyi-formula-cache")

STYLE_CSS = """\
@charset "utf-8";
body { margin: 0 auto; padding: 1.1em 1.2em; max-width: 42em; line-height: 1.75;
       font-family: "Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC", serif; }
h1, h2, h3, h4, h5, h6 { line-height: 1.35; margin: 1.3em 0 0.55em; }
p { margin: 0.85em 0; text-align: justify; }
img { max-width: 100%; height: auto; }
img.formula-inline { vertical-align: -0.25em; }
img.formula-block { display: block; margin: 0.9em auto; }
span.formula-row { display: block; margin: 0.9em 0; text-align: center; }
span.formula-row img.formula-block { display: inline-block; margin: 0; vertical-align: middle; }
span.formula-tag { margin-left: 0.8em; font-size: 0.92em; color: #555; vertical-align: middle; }
span.formula { font-family: "Cambria Math", "Latin Modern Math", "Times New Roman", serif; }
table { border-collapse: collapse; max-width: 100%; }
td, th { border: 1px solid #dfe2e5; padding: 4px 8px; }
"""

ET.register_namespace("", OPF_NS)
ET.register_namespace("dc", DC_NS)
ET.register_namespace("epub", EPUB_NS)


def build_cover(title: str, target: str) -> bool:
    """用 PIL 画一张简单的文字封面；缺字体或 PIL 时返回 False。"""
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        return False

    font_candidates = [
        r"C:\Windows\Fonts\msyh.ttc",
        r"C:\Windows\Fonts\msyhbd.ttc",
        r"C:\Windows\Fonts\simhei.ttf",
        r"C:\Windows\Fonts\simsun.ttc",
        "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
    ]
    font_path = next((p for p in font_candidates if os.path.isfile(p)), None)
    if font_path is None:
        return False

    # MinerU 会给标题带上脚注符号（如 ∗），字体里没有会显示成方块，直接去掉。
    for mark in ("\u2217", "\u204e", "\u2731", "\uff0a", "*"):
        title = title.replace(mark, "*")
    title = title.strip().strip("*").strip()
    if not title:
        title = "译稿"

    width, height = 1200, 1800
    image = Image.new("RGB", (width, height), (250, 249, 245))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width, 260], fill=(38, 62, 92))
    draw.rectangle([60, 320, width - 60, height - 120], outline=(38, 62, 92), width=3)

    title_font = ImageFont.truetype(font_path, 84)
    small_font = ImageFont.truetype(font_path, 40)

    # 按总长度均衡折行，避免出现"最后一行只剩一个字"。
    line_count = max(1, (len(title) + 10) // 11)
    per_line = -(-len(title) // line_count)
    lines = [title[i : i + per_line] for i in range(0, len(title), per_line)]
    lines = lines[:6]

    total_height = len(lines) * 108
    y = (height - total_height) // 2 + 40
    for line in lines:
        box = draw.textbbox((0, 0), line, font=title_font)
        draw.text(((width - (box[2] - box[0])) / 2, y), line, font=title_font, fill=(28, 28, 30))
        y += 108

    footer = "机器翻译 · wenyi"
    box = draw.textbbox((0, 0), footer, font=small_font)
    draw.text(((width - (box[2] - box[0])) / 2, height - 200), footer, font=small_font, fill=(90, 90, 95))
    image.save(target, "PNG")
    return True


def cover_page_xhtml(title: str) -> bytes:
    """封面页：EPUB 3 的 svg 包一张图，兼容老阅读器。"""
    safe_title = title.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    body = f"""<?xml version='1.0' encoding='utf-8'?>
<!DOCTYPE html>
<html xmlns="{XHTML_NS}" xmlns:epub="{EPUB_NS}" lang="zh-Hans" xml:lang="zh-Hans">
  <head>
    <title>{safe_title}</title>
    <style>html, body {{ margin: 0; padding: 0; height: 100%; }} img {{ max-width: 100%; height: auto; }}</style>
  </head>
  <body>
    <div style="text-align: center;">
      <img src="{COVER_IMAGE_NAME}" alt="{safe_title}"/>
    </div>
  </body>
</html>
"""
    return body.encode("utf-8")


# ── LaTeX → Unicode（文本路径） ──────────────────────────────────────────────

LATEX_SYMBOLS = {
    # 希腊字母
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
    "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
    "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ",
    "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
    "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ",
    "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
    "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    # 运算符与关系符
    "times": "×", "cdot": "·", "pm": "±", "mp": "∓", "approx": "≈", "neq": "≠", "ne": "≠",
    "equiv": "≡", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "ll": "≪", "gg": "≫",
    "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
    "cup": "∪", "cap": "∩", "infty": "∞", "partial": "∂", "nabla": "∇", "ell": "ℓ",
    "sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮",
    "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
    "leftrightarrow": "↔", "mapsto": "↦", "sim": "∼", "simeq": "≃", "propto": "∝", "cong": "≅",
    "star": "⋆", "ast": "∗", "circ": "∘", "bullet": "•", "oplus": "⊕", "otimes": "⊗",
    "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨", "angle": "∠",
    "perp": "⊥", "parallel": "∥", "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮",
    "prime": "′", "degree": "°", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
    "langle": "⟨", "rangle": "⟩", "mid": "|", "vert": "|", "Vert": "‖",
    # 空白
    "quad": " ", "qquad": " ", ",": " ", ";": " ", ":": " ", "!": "", " ": " ",
    # 转义标点（``\&`` / ``\#`` 这类）：按书写内容保留，不要凭空丢掉
    "&": "&", "#": "#", "%": "%", "$": "$",
}

LATEX_DROP = {
    "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
    "textstyle", "displaystyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits",
    "hline", "nonumber", "notag", "noindent", "centering", " ", "protect",
    "underbrace", "overbrace", "underset", "overset", "stackrel", "substack", "boxed",
}

LATEX_FUNCTIONS = {
    "ln", "log", "lg", "exp", "min", "max", "lim", "sin", "cos", "tan", "cot", "sec", "csc",
    "det", "dim", "arg", "deg", "gcd", "sup", "inf", "Pr", "mod", "TFP", "FOC", "Var", "Cov",
}

LATEX_TEXT_COMMANDS = {"text", "mathrm", "operatorname", "textit", "textbf", "texttt", "mbox", "hbox", "mathcal", "mathbf", "mathit", "mathsf"}

COMBINING_MAP = {
    "bar": "\u0304", "overline": "\u0305", "hat": "\u0302", "widehat": "\u0302",
    "tilde": "\u0303", "widetilde": "\u0303", "dot": "\u0307", "ddot": "\u0308",
    "vec": "\u20d7", "check": "\u030c", "breve": "\u0306",
}

SUBSCRIPT_MAP = {
    "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
    "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
    "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ",
    "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
}

SUPERSCRIPT_MAP = {
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
    "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
    "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ",
    "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ",
    "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    # 大写修饰字母（θ^H、A^L 这类上标）
    "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ",
    "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ",
    "U": "ᵁ", "V": "ⱽ", "W": "ᵂ",
}


def _read_group(text: str, index: int) -> tuple[str, int]:
    """读取 ``{...}`` 组（支持嵌套）；index 指向 ``{``。返回（内容, 下一个下标）。"""
    depth = 0
    start = index + 1
    i = index
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i], i + 1
        i += 1
    return text[start:], len(text)


def _read_atom(text: str, index: int) -> tuple[str, int]:
    """读取一个原子：``{...}`` 组、``\\cmd`` 或单个字符。"""
    if index >= len(text):
        return "", index
    if text[index] == "{":
        return _read_group(text, index)
    if text[index] == "\\":
        match = re.match(r"\\[A-Za-z]+", text[index:])
        if match:
            return match.group(0), index + len(match.group(0))
        return text[index : index + 2], index + 2
    return text[index], index + 1


def _skip_ws(text: str, index: int) -> int:
    """跳过空白：LaTeX 允许 ``A _ { t }``、``\\frac { a } { b }`` 这种写法。"""
    while index < len(text) and text[index] in " \t\r\n":
        index += 1
    return index


def _map_script(content: str, table: dict[str, str]) -> str | None:
    """全部字符都能映射时返回 Unicode 上下标，否则返回 None（调用方改用 ``_(...)``）。"""
    mapped = [table.get(char) for char in content]
    if any(item is None for item in mapped):
        return None
    return "".join(item for item in mapped if item is not None)


def latex_to_unicode(tex: str) -> str:
    """把 MinerU 输出的 LaTeX 片段近似转成 Unicode 文本（够读即可，不追求排版）。"""
    text = tex.strip()
    if not text:
        return ""
    out: list[str] = []
    i = 0
    while i < len(text):
        char = text[i]
        if char == "\\":
            match = re.match(r"\\([A-Za-z]+)", text[i:])
            name = match.group(1) if match else ""
            j = _skip_ws(text, i + len(name) + 1) if name else i + 1
            if name in LATEX_TEXT_COMMANDS:
                if j < len(text) and text[j] == "{":
                    inner, i = _read_group(text, j)
                    out.append(latex_to_unicode(inner))
                    continue
                i = j
                continue
            if name in COMBINING_MAP:
                if j < len(text) and text[j] == "{":
                    inner, i = _read_group(text, j)
                else:
                    inner, i = _read_atom(text, j)
                out.append(latex_to_unicode(inner) + COMBINING_MAP[name])
                continue
            if name == "frac":
                numerator, j = _read_atom(text, j)
                j = _skip_ws(text, j)
                denominator, j = _read_atom(text, j)
                top, bottom = latex_to_unicode(numerator), latex_to_unicode(denominator)
                if len(top) <= 1 and len(bottom) <= 1:
                    out.append(f"{top}/{bottom}")
                else:
                    out.append(f"({top})/({bottom})")
                i = j
                continue
            if name == "sqrt":
                inner, j = _read_atom(text, j)
                out.append("√(" + latex_to_unicode(inner) + ")")
                i = j
                continue
            if name == "tag":
                inner, j = _read_atom(text, j)
                out.append(" (" + latex_to_unicode(inner) + ")")
                i = j
                continue
            if name in ("begin", "end"):
                environment = re.match(r"[A-Za-z*]+", text[j:])
                if environment:
                    j += len(environment.group(0))
                j = _skip_ws(text, j)
                if j < len(text) and text[j] == "{":  # 丢掉列格式 {r l}
                    _, j = _read_group(text, j)
                out.append(" ")
                i = j
                continue
            if name in LATEX_DROP:
                i += len(name) + 1
                continue
            if name in LATEX_FUNCTIONS:
                out.append(name)
                i += len(name) + 1
                continue
            symbol = LATEX_SYMBOLS.get(name)
            if symbol is not None:
                out.append(symbol)
                i += len(name) + 1
                continue
            if name:
                out.append(name)  # 未知命令：去掉反斜杠、保留名字，至少不丢信息
                i += len(name) + 1
                continue
            symbol = LATEX_SYMBOLS.get(text[i + 1 : i + 2])  # \, \; \! 这类
            out.append("" if symbol is None else symbol)
            i += 2
            continue
        if char in "_^":
            table = SUBSCRIPT_MAP if char == "_" else SUPERSCRIPT_MAP
            # 去掉 "_" / "^" 之前那个悬空的空格（LaTeX 里 A _ {t} 与 A_{t} 等价）
            if out and out[-1].endswith(" "):
                out[-1] = out[-1].rstrip()
                if not out[-1]:
                    out.pop()
            j = _skip_ws(text, i + 1)
            content, j = _read_atom(text, j)
            stripped = "".join(content.split())
            if not stripped:  # 空上下标（\phi_{} 之类）直接忽略
                i = j
                continue
            mapped = _map_script(stripped, table) if stripped else None
            if mapped is not None:
                out.append(mapped)
            else:
                inner = latex_to_unicode(content)
                out.append(("_(" if char == "_" else "^(") + inner + ")")
            i = j
            continue
        if char in "{}":
            i += 1
            continue
        if text.startswith("\\\\", i):
            out.append(" ")
            i += 2
            continue
        if char in "&~":
            out.append(" ")
            i += 1
            continue
        out.append(char)
        i += 1
    text_out = " ".join("".join(out).split())
    text_out = re.sub(r"\s*\.\s*", ".", text_out)  # 0 . 5 → 0.5
    text_out = re.sub(r"\s*,\s*", ", ", text_out)  # i , t → i, t
    return text_out.strip()


# ── 复杂度判定与 MiKTeX 渲染（图片路径） ────────────────────────────────────

HARD_STRUCTURE = re.compile(
    r"\\begin\{|\\underbrace|\\overbrace|\\substack|\\stackrel|\\overset|\\underset"
    r"|\\overline|\\boxed"
)
BIG_OPERATOR = re.compile(r"\\frac|\\sum|\\prod|\\int")
TAG_PATTERN = re.compile(r"\\tag\s*\{([^{}]*)\}")


def is_complex_formula(tex: str, display: bool) -> bool:
    """按约定规则判断是否需要渲染成图片。"""
    if HARD_STRUCTURE.search(tex):
        return True
    return bool(display and BIG_OPERATOR.search(tex))


def split_equation_tag(tex: str) -> "tuple[str, str]":
    """把 ``\\tag{n}`` 从 LaTeX 里剥出来。

    返回（去掉编号的 LaTeX, 编号文本如 ``(2)``）。amsmath 不允许 ``\\tag``
    出现在 ``$...$`` 内联数学里，直接编译会报 "tag not allowed here"，
    所以编号不进图片，单独当文本排在公式旁边。
    """
    label = ""

    def take(match: "re.Match[str]") -> str:
        nonlocal label
        if not label:
            inner = safe_latex_to_unicode(match.group(1)).strip()
            if inner:
                label = f"({inner})"
        return ""

    return TAG_PATTERN.sub(take, tex).strip(), label


def safe_latex_to_unicode(tex: str) -> str:
    """文本路径永不阻塞：任何意外都退化成空串，由调用方再退一层。"""
    try:
        return latex_to_unicode(tex)
    except Exception:
        return ""


SAMPLE_FORMULAS = [
    (r"A_{t}", False), (r"\Delta", False), (r"\theta^{H}", False), (r"\alpha_{L,i,t}", False),
    (r"\bar{\mu}", False), (r"\sigma = 0.5", False), (r"\frac{s_{K,t_{0}}}{s_{L,t}}", False),
    (r"y_{i,t} = A_{t} \alpha_{L,i,t} \ell_{i,t} + \alpha_{K,i,t} k_{i,t}", False),
    (r"K_{t} = \sum_{i} k_{i,t},\quad L_{t} = \sum_{i} \ell_{i,t}", True),
    (r"\Delta \ln w_{t} \approx m_{t} d_{t} a_{t} - \frac{s_{K,t_{0}}}{s_{L,t}}", True),
    (r"\begin{array}{r} K_{t} = \sum_{i} k_{i,t} \end{array}", True),
    (r"p_{i,t} = \min \left\{\frac{w_{t}}{A_{t} \alpha_{L,i,t}}, \frac{r_{t}}{A_{t} \alpha_{K,i,t}}\right\}", True),
]


class FormulaRenderer:
    """用 MiKTeX 把 LaTeX 渲染成 PNG；任何一步失败都返回 None，调用方退化为文本。"""

    def __init__(self, font_pt: int = FORMULA_FONT_PT, scale: int = FORMULA_SCALE,
                 timeout: int = FORMULA_TIMEOUT) -> None:
        self.font_pt = font_pt
        self.scale = scale
        self.timeout = timeout
        self.available = False
        self.reason = ""

    @staticmethod
    def name_for(tex: str, display: bool) -> str:
        import hashlib
        digest = hashlib.sha1(("%s|%s" % (display, tex)).encode("utf-8")).hexdigest()[:8]
        return f"{FORMULA_DIR}/{digest}.png"

    def probe(self) -> bool:
        """编译一条最简公式，确认 MiKTeX 与 Python 依赖都在。"""
        try:
            import fitz  # noqa: F401
            from PIL import Image  # noqa: F401
        except ImportError as error:
            self.reason = f"缺少 Python 依赖（{getattr(error, 'name', error)}）"
            return False
        # 探针必须真编译一次：走缓存会掩盖"pdflatex 坏了"的情况。
        if self._compile(r"\frac{a}{b}", False, use_cache=False) is None:
            self.reason = "MiKTeX 无法编译测试公式（pdflatex 缺失或执行失败）"
            return False
        self.available = True
        self.reason = "MiKTeX 可用"
        return True

    def render(self, tex: str, display: bool):
        """成功返回 (png 字节, 宽度 em)，失败返回 None。"""
        if not self.available:
            return None
        return self._compile(tex, display)

    def _compile(self, tex: str, display: bool, *, use_cache: bool = True):
        import hashlib
        import io

        # 编号 (\tag) 不能进内联数学，编译前统一剥掉；编号另行当文本输出。
        tex, _label = split_equation_tag(tex)
        if not tex:
            return None
        key = hashlib.sha1(
            ("%s|%s|%s" % (display, self.font_pt, tex)).encode("utf-8")
        ).hexdigest()
        cached_png = os.path.join(FORMULA_CACHE, key + ".png")
        cached_meta = os.path.join(FORMULA_CACHE, key + ".txt")
        if use_cache and os.path.isfile(cached_png) and os.path.isfile(cached_meta):
            try:
                with open(cached_png, "rb") as handle:
                    data = handle.read()
                with open(cached_meta, encoding="utf-8") as handle:
                    return data, float(handle.read().strip())
            except (OSError, ValueError):
                pass

        body = f"$\\displaystyle {tex}$" if display else f"${tex}$"
        source = (
            "\\documentclass[%dpt]{article}\n"
            "\\usepackage{amsmath,amssymb}\n"
            "\\pagestyle{empty}\n"
            "\\setlength{\\parindent}{0pt}\n"
            "\\begin{document}\n%s\n\\end{document}\n" % (self.font_pt, body)
        )
        with tempfile.TemporaryDirectory(prefix="wenyi-formula-") as work:
            with open(os.path.join(work, "formula.tex"), "w", encoding="utf-8") as handle:
                handle.write(source)
            try:
                completed = subprocess.run(
                    ["pdflatex", "-interaction=nonstopmode", "-halt-on-error",
                     "--disable-installer", "formula.tex"],
                    cwd=work,
                    timeout=self.timeout,
                    capture_output=True,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                )
            except (OSError, subprocess.TimeoutExpired):
                return None
            pdf_path = os.path.join(work, "formula.pdf")
            if completed.returncode != 0 or not os.path.isfile(pdf_path):
                return None
            try:
                import fitz
                from PIL import Image, ImageChops

                document = fitz.open(pdf_path)
                pixmap = document[0].get_pixmap(
                    matrix=fitz.Matrix(self.scale, self.scale)
                )
                image = Image.open(io.BytesIO(pixmap.tobytes("png"))).convert("RGB")
                document.close()
                bbox = ImageChops.difference(
                    image, Image.new("RGB", image.size, (255, 255, 255))
                ).getbbox()
                if bbox is None:
                    return None
                box = (
                    max(0, bbox[0] - FORMULA_PAD_PX),
                    max(0, bbox[1] - FORMULA_PAD_PX),
                    min(image.width, bbox[2] + FORMULA_PAD_PX),
                    min(image.height, bbox[3] + FORMULA_PAD_PX),
                )
                image = image.crop(box)
                buffer = io.BytesIO()
                image.save(buffer, "PNG", optimize=True)
                data = buffer.getvalue()
                width_em = (image.width / self.scale) / self.font_pt
            except Exception:
                return None

        try:
            os.makedirs(FORMULA_CACHE, exist_ok=True)
            with open(cached_png, "wb") as handle:
                handle.write(data)
            with open(cached_meta, "w", encoding="utf-8") as handle:
                handle.write("%.4f" % width_em)
        except OSError:
            pass
        return data, width_em


def get_math_latex(element: ET.Element) -> str:
    """从 ``<math>`` 里取出 LaTeX 注解（XML 解析，实体已还原）。"""
    for annotation in element.iter():
        if annotation.tag not in SKIP_TAGS:
            continue
        if "x-tex" in (annotation.get("encoding") or ""):
            return "".join(annotation.itertext()).strip()
    return ""


def flatten_math(element: ET.Element) -> str:
    """把一段 MathML 变成一行纯文本；跳过 annotation/annotation-xml 里的 LaTeX 源码。"""
    parts: list[str] = []

    def walk(node: ET.Element) -> None:
        if node.tag in SKIP_TAGS:
            return
        if node.text:
            parts.append(node.text)
        for child in list(node):
            walk(child)
            if child.tail:
                parts.append(child.tail)

    walk(element)
    return " ".join("".join(parts).split()) or " "


def transform_xhtml(
    raw: bytes,
    *,
    mode: str = "hybrid",
    renderer: "FormulaRenderer | None" = None,
    images: "dict[str, bytes] | None" = None,
    stats: "dict[str, int] | None" = None,
) -> tuple[bytes, int]:
    """把 <math> 换成文本或图片；返回（新的 XHTML 字节, 处理过的公式数）。"""
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return raw, 0

    if images is None:
        images = {}
    if stats is None:
        stats = {}

    replaced = 0
    for parent in list(root.iter()):
        for position, child in enumerate(list(parent)):
            if child.tag != MATH_TAG:
                continue
            tex = get_math_latex(child)
            display = (child.get("display") or "inline").strip().lower() == "block"
            alternative = safe_latex_to_unicode(tex) if tex else ""
            if not alternative:
                alternative = flatten_math(child)
            # 公式编号从图片里剥出来，改成图片旁边的文本（图片用去掉编号的式子）。
            body_tex, tag = split_equation_tag(tex) if tex else ("", "")

            replacement = None
            suffix = ""
            wants_image = (
                mode in ("hybrid", "image")
                and bool(body_tex)
                and (mode == "image" or is_complex_formula(tex, display))
            )
            if wants_image and renderer is not None:
                rendered = renderer.render(body_tex, display)
                if rendered is not None:
                    data, width_em = rendered
                    name = renderer.name_for(body_tex, display)
                    images[name] = data
                    stats["image"] = stats.get("image", 0) + 1
                    image = ET.Element(f"{{{XHTML_NS}}}img")
                    image.set("src", name)
                    image.set("alt", alternative)
                    image.set("class", "formula-block" if display else "formula-inline")
                    image.set("style", "width:%.2fem" % max(0.4, width_em))
                    if tag and display:
                        # 块级公式 + 右侧编号：外层 span 负责居中，保持行内标签合法。
                        row = ET.Element(f"{{{XHTML_NS}}}span")
                        row.set("class", "formula-row")
                        row.append(image)
                        tag_span = ET.Element(f"{{{XHTML_NS}}}span")
                        tag_span.set("class", "formula-tag")
                        tag_span.text = tag
                        row.append(tag_span)
                        replacement = row
                    else:
                        replacement = image
                        if tag:
                            suffix = " " + tag

            if replacement is None:
                span = ET.Element(f"{{{XHTML_NS}}}span")
                span.set("class", "formula")
                span.text = alternative
                replacement = span
                stats["text"] = stats.get("text", 0) + 1

            tail = child.tail or ""
            replacement.tail = (suffix + tail) if (suffix or tail) else None
            parent.remove(child)
            parent.insert(position, replacement)
            replaced += 1

    # 每章都挂上样式表：有些阅读器（含 NeatReader）没有任何样式表时会处理异常。
    head = root.find(f"{{{XHTML_NS}}}head")
    if head is not None:
        has_style_link = any(
            node.tag == f"{{{XHTML_NS}}}link" and "stylesheet" in (node.get("rel") or "")
            for node in head
        )
        if not has_style_link:
            link = ET.Element(f"{{{XHTML_NS}}}link")
            link.set("rel", "stylesheet")
            link.set("type", "text/css")
            link.set("href", STYLE_NAME)
            head.insert(0, link)

    ET.register_namespace("", XHTML_NS)
    ET.register_namespace("epub", EPUB_NS)
    try:
        ET.indent(root, space="  ")  # 避免整章挤成一行，逐行读取的解析器更安全
    except AttributeError:
        pass
    body = ET.tostring(root, encoding="unicode")
    text = "<?xml version='1.0' encoding='utf-8'?>\n<!DOCTYPE html>\n" + body + "\n"
    return text.encode("utf-8"), replaced


def normalize_opf(
    raw: bytes,
    *,
    with_cover: bool,
    title: str = "",
    formula_images: "dict[str, float] | None" = None,
) -> bytes:
    """规范化 OPF：去掉 opf: 前缀、补 dc:creator、补封面声明与 guide。"""
    import uuid
    from datetime import date

    root = ET.fromstring(raw)
    metadata = root.find(f"{{{OPF_NS}}}metadata")
    if metadata is None:
        metadata = ET.SubElement(root, f"{{{OPF_NS}}}metadata")
    manifest = root.find(f"{{{OPF_NS}}}manifest")
    spine = root.find(f"{{{OPF_NS}}}spine")

    if title.strip():
        title_el = metadata.find(f"{{{DC_NS}}}title")
        if title_el is None:
            title_el = ET.SubElement(metadata, f"{{{DC_NS}}}title")
        title_el.text = title.strip()

    if metadata.find(f"{{{DC_NS}}}creator") is None:
        creator = ET.SubElement(metadata, f"{{{DC_NS}}}creator")
        creator.text = "wenyi（机器翻译）"
    # 每次都换一个 uuid：避免阅读器把这次的导入和上一次卡住的半成品混在一起。
    identifier = metadata.find(f"{{{DC_NS}}}identifier")
    if identifier is None:
        identifier = ET.SubElement(metadata, f"{{{DC_NS}}}identifier")
        identifier.set("id", "id")
    identifier.text = f"urn:uuid:{uuid.uuid4()}"
    if metadata.find(f"{{{DC_NS}}}date") is None:
        date_el = ET.SubElement(metadata, f"{{{DC_NS}}}date")
        date_el.text = date.today().isoformat()
    if metadata.find(f"{{{DC_NS}}}description") is None:
        desc = ET.SubElement(metadata, f"{{{DC_NS}}}description")
        desc.text = "由 wenyi 机器翻译，仅供个人阅读。"

    if with_cover and manifest is not None and spine is not None:
        ids = {item.get("id") for item in manifest.findall(f"{{{OPF_NS}}}item")}
        if COVER_IMAGE_ID not in ids:
            item = ET.SubElement(manifest, f"{{{OPF_NS}}}item")
            item.set("href", COVER_IMAGE_NAME)
            item.set("id", COVER_IMAGE_ID)
            item.set("media-type", "image/png")
            item.set("properties", "cover-image")
        if COVER_PAGE_ID not in ids:
            item = ET.SubElement(manifest, f"{{{OPF_NS}}}item")
            item.set("href", COVER_PAGE_NAME)
            item.set("id", COVER_PAGE_ID)
            item.set("media-type", "application/xhtml+xml")
            reference = ET.Element(f"{{{OPF_NS}}}itemref")
            reference.set("idref", COVER_PAGE_ID)
            spine.insert(0, reference)
        if not any(m.get("name") == "cover" for m in metadata.findall(f"{{{OPF_NS}}}meta")):
            cover_meta = ET.SubElement(metadata, f"{{{OPF_NS}}}meta")
            cover_meta.set("name", "cover")
            cover_meta.set("content", COVER_IMAGE_ID)
        if root.find(f"{{{OPF_NS}}}guide") is None:
            guide = ET.SubElement(root, f"{{{OPF_NS}}}guide")
            ref = ET.SubElement(guide, f"{{{OPF_NS}}}reference")
            ref.set("type", "cover")
            ref.set("title", "Cover")
            ref.set("href", COVER_PAGE_NAME)

    if manifest is not None and not any(
        item.get("href") == STYLE_NAME for item in manifest.findall(f"{{{OPF_NS}}}item")
    ):
        style_item = ET.SubElement(manifest, f"{{{OPF_NS}}}item")
        style_item.set("href", STYLE_NAME)
        style_item.set("id", "style")
        style_item.set("media-type", "text/css")

    # 公式图片也要进 manifest，严格的阅读器才肯显示。
    if manifest is not None and formula_images:
        known_hrefs = {
            item.get("href") for item in manifest.findall(f"{{{OPF_NS}}}item")
        }
        for index, href in enumerate(sorted(formula_images)):
            if href in known_hrefs:
                continue
            item = ET.SubElement(manifest, f"{{{OPF_NS}}}item")
            item.set("href", href)
            item.set("id", f"formula-{index}")
            item.set("media-type", "image/png")

    root.attrib.pop("prefix", None)
    ET.register_namespace("", OPF_NS)
    ET.register_namespace("dc", DC_NS)
    try:
        ET.indent(root, space="  ")
    except AttributeError:
        pass
    body = ET.tostring(root, encoding="unicode")
    return ("<?xml version='1.0' encoding='utf-8'?>\n" + body + "\n").encode("utf-8")


def compose_sample_sheet(renderer: FormulaRenderer, target: str | None = None) -> str | None:
    """把代表性公式渲染成一张对比图，供肉眼确认渲染质量。"""
    import io

    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        return None

    font = None
    for candidate in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf"):
        if os.path.isfile(candidate):
            try:
                font = ImageFont.truetype(candidate, 20)
            except OSError:
                font = None
            break

    thumbs = []
    for tex, display in SAMPLE_FORMULAS:
        rendered = renderer.render(tex, display)
        if rendered is None:
            continue
        data, _width_em = rendered
        try:
            image = Image.open(io.BytesIO(data)).convert("RGB")
        except Exception:
            continue
        if image.width > 1400:
            ratio = 1400 / image.width
            image = image.resize((1400, max(1, int(image.height * ratio))), Image.LANCZOS)
        thumbs.append((tex, image))
    if not thumbs:
        return None

    padding, label_height = 16, 34
    width = max(image.width for _, image in thumbs) + padding * 2
    height = sum(image.height + label_height + padding for _, image in thumbs) + padding
    sheet = Image.new("RGB", (max(width, 400), height), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    y = padding
    for tex, image in thumbs:
        draw.text((padding, y), tex[:110], fill=(120, 120, 128), font=font)
        y += label_height
        sheet.paste(image, (padding, y))
        y += image.height + padding
    out = target or os.path.join(tempfile.gettempdir(), "wenyi-formula-sample.png")
    sheet.save(out, "PNG", optimize=True)
    return out


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    mode = "hybrid"
    check_only = False
    sample_sheet = None
    rest: list[str] = []
    for item in sys.argv[1:]:
        if item.startswith("--formulas="):
            mode = item.split("=", 1)[1].strip().lower()
        elif item == "--check-renderer":
            check_only = True
        elif item.startswith("--sample-sheet"):
            sample_sheet = item.split("=", 1)[1] if "=" in item else ""
        else:
            rest.append(item)
    if mode not in ("hybrid", "text", "image"):
        print(f"未知的公式模式: {mode}（可选 hybrid / text / image）")
        return 2

    renderer = FormulaRenderer()

    if check_only:
        import shutil

        print("公式渲染器自检")
        print("  python  :", sys.executable)
        for module in ("PIL", "fitz"):
            try:
                __import__(module)
                print(f"  {module:8}: 可用")
            except ImportError:
                print(f"  {module:8}: 缺失（公式图片路径会退化为纯文本）")
        print("  pdflatex:", shutil.which("pdflatex") or "(未找到)")
        ok = renderer.probe()
        print("  结论    :", renderer.reason)
        if ok:
            made = compose_sample_sheet(renderer)
            if made:
                print("  样张    :", made)
        return 0 if ok else 1

    if sample_sheet is not None:
        if not renderer.probe():
            print("公式渲染不可用:", renderer.reason)
            return 1
        made = compose_sample_sheet(
            renderer, sample_sheet or os.path.join(tempfile.gettempdir(), "wenyi-formula-sample.png")
        )
        if not made:
            print("样张生成失败")
            return 1
        print("样张:", made)
        return 0

    if len(rest) < 1:
        print("用法:")
        print('  epub-compat.cmd "来源.epub" ["输出.epub"] [--formulas=hybrid|text|image]')
        print("  epub-compat.cmd --check-renderer             # 检查公式渲染器是否可用")
        print("  epub-compat.cmd --sample-sheet[=输出.png]     # 生成公式样张供肉眼确认")
        print("作用: 把 MathML 公式转成 Unicode 文本或图片、补封面、规范化元数据，")
        print("      便于 NeatReader 等对 MathML 支持不佳的阅读器打开与阅读。")
        print("未指定输出时，会生成同目录下的 <文件名>-compat.epub。")
        return 2

    source = os.path.abspath(rest[0])
    if not os.path.isfile(source):
        print(f"找不到文件: {source}")
        return 2
    if len(rest) >= 2:
        target = os.path.abspath(rest[1])
    else:
        stem, ext = os.path.splitext(source)
        target = f"{stem}-compat{ext or '.epub'}"
    if os.path.abspath(target) == source:
        print("输出文件不能和来源相同。")
        return 2

    formula_images: dict[str, bytes] = {}
    stats: dict[str, int] = {"image": 0, "text": 0}
    if mode == "text":
        print("公式: 全部转 Unicode 文本（不渲染图片）")
    elif renderer.probe():
        print("公式渲染:", renderer.reason)
    else:
        print("公式渲染不可用，全部公式退化为纯文本:", renderer.reason)

    with zipfile.ZipFile(source) as src:
        infos = src.infolist()
        if not infos or infos[0].filename != "mimetype":
            print("警告: mimetype 不是第一个条目，仍会按规范重写。")

        container_raw = src.read("META-INF/container.xml")
        container_root = ET.fromstring(container_raw)
        opf_path = container_root.find(f".//{{{CONTAINER_NS}}}rootfile").get("full-path")
        opf_dir = posixpath.dirname(opf_path)
        # 内容目录统一改成 OEBPS/：包内相对链接不变，只改 container.xml 的指向。
        opf_out = posixpath.join(CONTENT_DIR, posixpath.basename(opf_path))
        container_out = container_raw.replace(opf_path.encode("utf-8"), opf_out.encode("utf-8"))

        replaced_files = 0
        replaced_total = 0
        payloads: dict[str, bytes] = {}
        display_title = ""
        for info in infos:
            name = info.filename
            if name == "mimetype":
                continue
            if opf_dir and name.startswith(opf_dir + "/"):
                out_name = CONTENT_DIR + name[len(opf_dir):]
            else:
                out_name = name
            data = src.read(name)
            if out_name.lower().endswith((".xhtml", ".html", ".htm")):
                data, count = transform_xhtml(
                    data,
                    mode=mode,
                    renderer=renderer if renderer.available else None,
                    images=formula_images,
                    stats=stats,
                )
                if count:
                    replaced_files += 1
                    replaced_total += count
                if not display_title and not out_name.endswith("cover.xhtml"):
                    try:
                        doc_title = ET.fromstring(data).find(f".//{{{XHTML_NS}}}title")
                        if doc_title is not None and (doc_title.text or "").strip():
                            display_title = doc_title.text.strip()
                    except ET.ParseError:
                        pass
            payloads[out_name] = data

        payloads["META-INF/container.xml"] = container_out
        if not display_title:
            display_title = os.path.splitext(os.path.basename(source))[0]
        print(f"封面标题: {display_title}")

        import tempfile

        cover_bytes = None
        with tempfile.TemporaryDirectory() as tmp:
            cover_file = os.path.join(tmp, "cover.png")
            if build_cover(display_title, cover_file):
                with open(cover_file, "rb") as handle:
                    cover_bytes = handle.read()

        if cover_bytes is not None:
            payloads[posixpath.join(CONTENT_DIR, COVER_IMAGE_NAME)] = cover_bytes
            payloads[posixpath.join(CONTENT_DIR, COVER_PAGE_NAME)] = cover_page_xhtml(display_title)
            print("封面: 已生成并写入（PNG，id=cover-img）")
        else:
            print("封面: 跳过（缺少 PIL 或中文字体）")

        payloads[posixpath.join(CONTENT_DIR, STYLE_NAME)] = STYLE_CSS.encode("utf-8")
        for relative, data in formula_images.items():
            payloads[posixpath.join(CONTENT_DIR, relative)] = data
        clean_title = display_title
        for mark in ("\u2217", "\u204e", "\u2731", "\uff0a", "*"):
            clean_title = clean_title.replace(mark, "")
        payloads[opf_out] = normalize_opf(
            payloads[opf_out],
            with_cover=cover_bytes is not None,
            title=clean_title.strip(),
            formula_images={relative: 1.0 for relative in formula_images},
        )

        with zipfile.ZipFile(target, "w") as dst:
            # 规范要求：mimetype 第一个写入且不压缩。
            dst.writestr("mimetype", b"application/epub+zip", compress_type=zipfile.ZIP_STORED)
            written = {"mimetype"}
            for name in ("META-INF/container.xml", opf_out):
                if name in payloads:
                    dst.writestr(name, payloads[name], compress_type=zipfile.ZIP_DEFLATED)
                    written.add(name)
            for name, data in payloads.items():
                if name in written:
                    continue
                dst.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)

    print(
        "公式: 图片 {0} 处（{1} 个文件）、文本 {2} 处，涉及 {3} 个 XHTML".format(
            stats.get("image", 0), len(formula_images), stats.get("text", 0), replaced_files
        )
    )
    if mode != "text" and stats.get("image", 0) == 0:
        print("提示: 本轮没有产出公式图片（渲染器不可用，或没有判定为复杂的公式）")
    print(f"内容目录: {CONTENT_DIR}/（与常见阅读器一致），已加 {STYLE_NAME}")
    print("元数据: 已规范化（urn:uuid、dc:creator/date/description、封面 id=cover-img）")
    print(f"输出: {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
