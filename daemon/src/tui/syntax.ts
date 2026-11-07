/**
 * Lightweight, dependency-free syntax highlighting for the built-in editor.
 *
 * `highlightLine()` returns absolute character spans on the already tab-expanded
 * line. The editor turns those spans into blessed color tags, so multi-line
 * comment state stays in the caller (one boolean per line).
 */
import { PAL } from "./theme";

/** Semantic syntax colors, resolved lazily so theme switches apply at once. */
export type SynKey =
  | "keyword"
  | "string"
  | "number"
  | "comment"
  | "function"
  | "variable"
  | "property"
  | "constant"
  | "type"
  | "operator"
  | "tag"
  | "attribute"
  | "heading"
  | "link"
  | "plain";

function synColor(key: string): string {
  switch (key) {
    case "keyword":
    case "tag":
      return PAL.magenta;
    case "string":
      return PAL.green;
    case "number":
      return PAL.orange;
    case "comment":
      return PAL.dim;
    case "function":
    case "property":
    case "attribute":
    case "type":
      return PAL.cyan;
    case "variable":
    case "heading":
    case "link":
      return PAL.accent;
    case "constant":
      return PAL.yellow;
    case "operator":
      return PAL.muted;
    default:
      return PAL.text;
  }
}

export const SYN: Record<SynKey, string> = new Proxy({} as Record<SynKey, string>, {
  get: (_target, key) => synColor(String(key))
});

export interface Span {
  start: number;
  end: number;
  color: string;
}

export type LangId =
  | "ts"
  | "js"
  | "java"
  | "json"
  | "yaml"
  | "props"
  | "shell"
  | "batch"
  | "html"
  | "markdown"
  | "text";

export interface LangSpec {
  id: LangId;
  label: string;
  /** Multi-line comment/fence markers: [open, close]. */
  block?: [string, string];
  /** Single-line comment prefixes used to avoid mis-reading block markers. */
  lineComments?: string[];
}

const LANGS: Record<LangId, LangSpec> = {
  ts: { id: "ts", label: "TypeScript", block: ["/*", "*/"], lineComments: ["//"] },
  js: { id: "js", label: "JavaScript", block: ["/*", "*/"], lineComments: ["//"] },
  java: { id: "java", label: "Java", block: ["/*", "*/"], lineComments: ["//"] },
  json: { id: "json", label: "JSON" },
  yaml: { id: "yaml", label: "YAML" },
  props: { id: "props", label: "配置" },
  shell: { id: "shell", label: "Shell" },
  batch: { id: "batch", label: "批处理" },
  html: { id: "html", label: "HTML/XML", block: ["<!--", "-->"] },
  markdown: { id: "markdown", label: "Markdown", block: ["```", "```"] },
  text: { id: "text", label: "纯文本" }
};

const EXT_LANG: Record<string, LangId> = {
  js: "js",
  mjs: "js",
  cjs: "js",
  jsx: "js",
  ts: "ts",
  tsx: "ts",
  mts: "ts",
  cts: "ts",
  java: "java",
  json: "json",
  json5: "json",
  mcmeta: "json",
  yml: "yaml",
  yaml: "yaml",
  properties: "props",
  conf: "props",
  cfg: "props",
  ini: "props",
  toml: "props",
  env: "props",
  sh: "shell",
  bash: "shell",
  zsh: "shell",
  bat: "batch",
  cmd: "batch",
  html: "html",
  htm: "html",
  xml: "html",
  svg: "html",
  md: "markdown",
  markdown: "markdown",
  log: "text",
  txt: "text"
};

/** Pick a language from a file path; unknown files stay plain. */
export function detectLanguage(relPath: string): LangSpec {
  const base = String(relPath ?? "")
    .replace(/\\/g, "/")
    .split("/")
    .pop()!
    .toLowerCase();
  const dot = base.lastIndexOf(".");
  const ext = dot >= 0 ? base.slice(dot + 1) : "";
  return LANGS[EXT_LANG[ext] ?? "text"];
}

const JS_KEYWORDS = new Set(
  (
    "break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield async await interface type enum implements declare namespace readonly public private protected abstract as is keyof infer satisfies"
  ).split(" ")
);
const JAVA_KEYWORDS = new Set(
  (
    "abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public record return sealed permits static strictfp super switch synchronized this throw throws transient try var void volatile while yield boolean byte char double float int long short"
  ).split(" ")
);
const DECLARATION = new Set(
  "let const var int long short float double boolean char byte string String final val auto public private protected static readonly".split(
    " "
  )
);
const CONSTANTS = new Set(["true", "false", "null", "undefined", "NaN", "Infinity"]);

const SHELL_KEYWORDS = new Set(
  (
    "if then else elif fi for while until do done case esac function in select time coproc return break continue local export readonly declare unset shift source alias"
  ).split(" ")
);
const BATCH_KEYWORDS = new Set(
  (
    "set setlocal endlocal if else for in do goto call exit echo cd chdir start pause title shift pushd popd del copy move mkdir md rd ren type cls color prompt verify"
  ).split(" ")
);

function add(spans: Span[], start: number, end: number, color: string) {
  if (end > start && start >= 0) spans.push({ start, end, color });
}

function inside(spans: Span[], index: number): Span | undefined {
  return spans.find((span) => index >= span.start && index < span.end);
}

/** Skip a quoted run; returns the index just past the closing quote. */
function skipString(line: string, i: number, quote: string): number {
  let j = i + 1;
  while (j < line.length) {
    if (line[j] === "\\") {
      j += 2;
      continue;
    }
    if (line[j] === quote) return j + 1;
    j++;
  }
  return line.length;
}

/** Multi-line block comment state after this line. */
export function nextBlockState(
  line: string,
  inBlock: boolean,
  block?: [string, string],
  lineComments: string[] = []
): boolean {
  if (!block) return false;
  let i = 0;
  let state = inBlock;
  while (i < line.length) {
    if (state) {
      const close = line.indexOf(block[1], i);
      if (close < 0) return true;
      i = close + block[1].length;
      state = false;
      continue;
    }
    const ch = line[i];
    if (ch === '"' || ch === "'" || ch === "`") {
      i = skipString(line, i, ch);
      continue;
    }
    if (lineComments.some((prefix) => line.startsWith(prefix, i))) return false;
    const open = line.indexOf(block[0], i);
    if (open < 0) return false;
    i = open + block[0].length;
    state = true;
  }
  return state;
}

/** Block comment spans for this line (handles open state from previous lines). */
function blockScan(
  line: string,
  inBlock: boolean,
  block: [string, string],
  lineComments: string[] = []
): { spans: Span[]; state: boolean } {
  const spans: Span[] = [];
  let i = 0;
  let state = inBlock;
  if (state) {
    const close = line.indexOf(block[1]);
    if (close < 0) {
      add(spans, 0, line.length, SYN.comment);
      return { spans, state: true };
    }
    const stop = close + block[1].length;
    add(spans, 0, stop, SYN.comment);
    i = stop;
    state = false;
  }
  while (i < line.length) {
    const ch = line[i];
    if (ch === '"' || ch === "'" || ch === "`") {
      i = skipString(line, i, ch);
      continue;
    }
    if (lineComments.some((prefix) => line.startsWith(prefix, i))) break;
    const open = line.indexOf(block[0], i);
    if (open < 0) break;
    const close = line.indexOf(block[1], open + block[0].length);
    if (close < 0) {
      add(spans, open, line.length, SYN.comment);
      return { spans, state: true };
    }
    const stop = close + block[1].length;
    add(spans, open, stop, SYN.comment);
    i = stop;
  }
  return { spans, state };
}

function highlightBlockLine(line: string, lang: LangSpec, inBlock: boolean) {
  const block = lang.block!;
  const scan = blockScan(line, inBlock, block, lang.lineComments);
  return { spans: scan.spans, inBlock: scan.state, scan };
}

// ---------------------------------------------------------------------------
// C-like languages (JS / TS / Java)
// ---------------------------------------------------------------------------

const CODE_RE =
  /("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\[\s\S])*`)|(\/\/[^\n]*)|(\b0[xX][0-9a-fA-F_]+|\b\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?[fFdDlL]?\b)|(@[A-Za-z_][\w.$]*)|([A-Za-z_$][\w$]*)|([+\-*/%<>=!&|^~?:]+)/g;

function codeLine(line: string, lang: LangSpec, inBlock: boolean) {
  const { spans, inBlock: state, scan } = highlightBlockLine(line, lang, inBlock);
  const keywords = lang.id === "java" ? JAVA_KEYWORDS : JS_KEYWORDS;
  let declared = false;
  CODE_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = CODE_RE.exec(line))) {
    const index = match.index;
    if (inside(scan.spans, index)) continue;
    const token = match[0];

    if (match[1]) {
      add(spans, index, index + token.length, SYN.string);
      declared = false;
    } else if (match[2]) {
      add(spans, index, index + token.length, SYN.comment);
      break;
    } else if (match[3]) {
      add(spans, index, index + token.length, SYN.number);
      declared = false;
    } else if (match[4]) {
      add(spans, index, index + token.length, SYN.variable);
      declared = false;
    } else if (match[5]) {
      const word = token;
      const end = index + word.length;
      const after = line.slice(end);
      const before = line.slice(0, index);
      let color: string | undefined;
      if (keywords.has(word)) {
        color = SYN.keyword;
        declared = DECLARATION.has(word);
      } else if (CONSTANTS.has(word)) {
        color = SYN.constant;
        declared = false;
      } else if (/^\s*\(/.test(after)) {
        color = SYN.function;
        declared = false;
      } else if (declared) {
        color = SYN.variable;
        declared = false;
      } else if (before.endsWith(".")) {
        color = SYN.property;
        declared = false;
      } else if (/^[A-Z]/.test(word)) {
        color = SYN.type;
        declared = false;
      } else {
        declared = false;
      }
      if (color) add(spans, index, end, color);
    } else if (match[6]) {
      add(spans, index, index + token.length, SYN.operator);
      declared = false;
    }
  }
  return { spans, inBlock: state };
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

const JSON_RE =
  /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|\b(true|false|null)\b/g;

function jsonLine(line: string) {
  const spans: Span[] = [];
  JSON_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = JSON_RE.exec(line))) {
    const index = match.index;
    const token = match[0];
    if (match[1]) {
      if (match[2]) {
        add(spans, index, index + match[1].length, SYN.property);
        add(spans, index + match[1].length, index + token.length, SYN.operator);
      } else {
        add(spans, index, index + token.length, SYN.string);
      }
    } else if (match[3]) {
      add(spans, index, index + token.length, SYN.number);
    } else if (match[4]) {
      add(spans, index, index + token.length, SYN.constant);
    }
  }
  return { spans, inBlock: false };
}

// ---------------------------------------------------------------------------
// YAML
// ---------------------------------------------------------------------------

const YAML_KEY_RE = /^(\s*(?:-\s+)?)([^\s:#][^:#]*?)(\s*:)(?=\s|$)/;
const YAML_VALUE_RE =
  /("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|(\b\d+(?:\.\d+)?\b)|(\b(?:true|false|null|yes|no|on|off)\b)|(&[A-Za-z_]\w*|\*[A-Za-z_]\w*|![A-Za-z_]\w*)/g;

function yamlLine(line: string) {
  const spans: Span[] = [];
  let commentStart = -1;
  let quote: string | null = null;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      if (ch === "\\") i++;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "#" && (i === 0 || /\s/.test(line[i - 1]))) {
      commentStart = i;
      break;
    }
  }
  const head = commentStart >= 0 ? line.slice(0, commentStart) : line;

  const key = YAML_KEY_RE.exec(head);
  let valueStart = 0;
  if (key) {
    const keyStart = key[1].length;
    const keyEnd = keyStart + key[2].length;
    add(spans, keyStart, keyEnd, SYN.property);
    add(spans, keyEnd, key[3].length + keyEnd, SYN.operator);
    valueStart = key[0].length;
  } else if (/^\s*---\s*$/.test(head)) {
    add(spans, 0, head.length, SYN.comment);
  }

  YAML_VALUE_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = YAML_VALUE_RE.exec(head))) {
    if (match.index < valueStart) continue;
    const index = match.index;
    if (match[1]) add(spans, index, index + match[0].length, SYN.string);
    else if (match[2]) add(spans, index, index + match[0].length, SYN.number);
    else if (match[3]) add(spans, index, index + match[0].length, SYN.constant);
    else add(spans, index, index + match[0].length, SYN.variable);
  }

  if (commentStart >= 0) add(spans, commentStart, line.length, SYN.comment);
  return { spans, inBlock: false };
}

// ---------------------------------------------------------------------------
// .properties / .ini / .conf / .toml
// ---------------------------------------------------------------------------

const PROPS_VALUE_RE = /("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|(\b\d+(?:\.\d+)?\b)|(\b(?:true|false)\b)/g;

function propsLine(line: string) {
  const spans: Span[] = [];
  const trimmed = line.trimStart();
  const indent = line.length - trimmed.length;
  if (!trimmed) return { spans, inBlock: false };
  if (trimmed.startsWith("#") || trimmed.startsWith("!") || trimmed.startsWith(";")) {
    add(spans, indent, line.length, SYN.comment);
    return { spans, inBlock: false };
  }
  if (/^\[.+\]$/.test(trimmed)) {
    add(spans, indent, line.length, SYN.property);
    return { spans, inBlock: false };
  }

  let sep = -1;
  let quote: string | null = null;
  for (let i = indent; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      if (ch === "\\") i++;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "=" || ch === ":") {
      sep = i;
      break;
    }
  }
  if (sep < 0) return { spans, inBlock: false };

  const key = line.slice(indent, sep).trimEnd();
  if (key) add(spans, indent, indent + key.length, SYN.property);
  add(spans, sep, sep + 1, SYN.operator);

  PROPS_VALUE_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = PROPS_VALUE_RE.exec(line))) {
    if (match.index <= sep) continue;
    if (match[1]) add(spans, match.index, match.index + match[0].length, SYN.string);
    else if (match[2]) add(spans, match.index, match.index + match[0].length, SYN.number);
    else if (match[3]) add(spans, match.index, match.index + match[0].length, SYN.constant);
  }
  return { spans, inBlock: false };
}

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------

function shellLine(line: string) {
  const spans: Span[] = [];
  let i = 0;
  let command = true;
  while (i < line.length) {
    const ch = line[i];
    if (ch === " " || ch === "\t") {
      i++;
      continue;
    }
    if (ch === "#") {
      add(spans, i, line.length, SYN.comment);
      break;
    }
    if (ch === "'" || ch === '"') {
      const end = skipString(line, i, ch);
      add(spans, i, end, SYN.string);
      i = end;
      command = false;
      continue;
    }
    if (ch === "$") {
      const m = /^\$(?:\{[^}]*\}|[A-Za-z_]\w*|[0-9@*?#!$-])/.exec(line.slice(i));
      if (m) {
        add(spans, i, i + m[0].length, SYN.variable);
        i += m[0].length;
        command = false;
        continue;
      }
    }
    if (/[0-9]/.test(ch) && !/[\w]/.test(line[i - 1] ?? " ")) {
      const m = /^\d+(?:\.\d+)?/.exec(line.slice(i));
      if (m) {
        add(spans, i, i + m[0].length, SYN.number);
        i += m[0].length;
        command = false;
        continue;
      }
    }
    if (/[A-Za-z_]/.test(ch)) {
      const m = /^[A-Za-z_][\w.-]*/.exec(line.slice(i))!;
      const word = m[0];
      const end = i + word.length;
      if (SHELL_KEYWORDS.has(word)) add(spans, i, end, SYN.keyword);
      else if (command) add(spans, i, end, SYN.function);
      i = end;
      command = false;
      continue;
    }
    if ("|&;()".includes(ch)) {
      command = ch === "|" || ch === "&" || ch === ";" || ch === "(";
      add(spans, i, i + 1, SYN.operator);
      i++;
      continue;
    }
    if ("<>".includes(ch)) {
      add(spans, i, i + 1, SYN.operator);
      i++;
      continue;
    }
    i++;
  }
  return { spans, inBlock: false };
}

// ---------------------------------------------------------------------------
// Windows batch
// ---------------------------------------------------------------------------

function batchLine(line: string) {
  const spans: Span[] = [];
  const trimmed = line.trimStart();
  const indent = line.length - trimmed.length;
  if (/^::/.test(trimmed) || /^rem\b/i.test(trimmed)) {
    add(spans, indent, line.length, SYN.comment);
    return { spans, inBlock: false };
  }
  if (/^:/.test(trimmed)) {
    add(spans, indent, line.length, SYN.property);
    return { spans, inBlock: false };
  }

  let i = 0;
  let command = true;
  while (i < line.length) {
    const ch = line[i];
    if (ch === " " || ch === "\t") {
      i++;
      continue;
    }
    if (ch === "@") {
      i++;
      continue;
    }
    if (ch === '"') {
      const end = skipString(line, i, ch);
      add(spans, i, end, SYN.string);
      i = end;
      command = false;
      continue;
    }
    if (ch === "%" || ch === "!") {
      const close = line.indexOf(ch, i + 1);
      if (close > i) {
        add(spans, i, close + 1, SYN.variable);
        i = close + 1;
        command = false;
        continue;
      }
    }
    if (/[A-Za-z_]/.test(ch)) {
      const m = /^[A-Za-z_][\w.-]*/.exec(line.slice(i))!;
      const word = m[0];
      const end = i + word.length;
      if (BATCH_KEYWORDS.has(word.toLowerCase())) add(spans, i, end, SYN.keyword);
      else if (command) add(spans, i, end, SYN.function);
      i = end;
      command = word.toLowerCase() === "set" || word.toLowerCase() === "call";
      continue;
    }
    if (/[0-9]/.test(ch)) {
      const m = /^\d+/.exec(line.slice(i))!;
      add(spans, i, i + m[0].length, SYN.number);
      i += m[0].length;
      command = false;
      continue;
    }
    if ("=<>|&".includes(ch)) {
      add(spans, i, i + 1, SYN.operator);
      command = true;
      i++;
      continue;
    }
    i++;
  }
  return { spans, inBlock: false };
}

// ---------------------------------------------------------------------------
// HTML / XML
// ---------------------------------------------------------------------------

const MARKUP_RE =
  /(<!--[\s\S]*?-->)|(<\/?)([\w:.-]+)|(\/?>)|([\w:.-]+)(?=\s*=)|("(?:[^"]*)"|'(?:[^']*)')|(&[a-zA-Z#0-9]+;)/g;

function markupLine(line: string, lang: LangSpec, inBlock: boolean) {
  const { spans, inBlock: state, scan } = highlightBlockLine(line, lang, inBlock);
  MARKUP_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = MARKUP_RE.exec(line))) {
    if (inside(scan.spans, match.index)) continue;
    const index = match.index;
    const token = match[0];
    if (match[2]) {
      add(spans, index, index + match[2].length, SYN.operator);
      add(spans, index + match[2].length, index + token.length, SYN.tag);
    } else if (match[4]) {
      add(spans, index, index + token.length, SYN.operator);
    } else if (match[5]) {
      add(spans, index, index + token.length, SYN.attribute);
    } else if (match[6]) {
      add(spans, index, index + token.length, SYN.string);
    } else if (match[7]) {
      add(spans, index, index + token.length, SYN.number);
    }
  }
  return { spans, inBlock: state };
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

function markdownLine(line: string, inBlock: boolean) {
  const spans: Span[] = [];
  const fence = /^\s*```/.test(line);
  if (fence || inBlock) {
    if (fence) add(spans, 0, line.length, SYN.comment);
    return { spans, inBlock: fence ? !inBlock : inBlock };
  }
  if (/^\s{0,3}#{1,6}\s/.test(line)) {
    add(spans, 0, line.length, SYN.heading);
    return { spans, inBlock: false };
  }
  if (/^\s*---+\s*$/.test(line)) {
    add(spans, 0, line.length, SYN.comment);
    return { spans, inBlock: false };
  }
  const quote = /^(\s*)>/.exec(line);
  if (quote) add(spans, 0, quote[1].length + 1, SYN.operator);

  const inline = /(`[^`]*`)|(\*\*[^*]+\*\*)|(\[[^\]]*\])(\([^)]*\))|(^\s*(?:[-*+]|\d+\.)\s)/g;
  let match: RegExpExecArray | null;
  while ((match = inline.exec(line))) {
    const index = match.index;
    if (match[1]) add(spans, index, index + match[0].length, SYN.string);
    else if (match[2]) add(spans, index, index + match[0].length, SYN.type);
    else if (match[3]) add(spans, index, index + match[3].length, SYN.link);
    else if (match[4]) add(spans, index + match[3].length, index + match[3].length + match[4].length, SYN.comment);
    else if (match[5]) {
      const marker = match[5].trim();
      add(spans, index + match[5].indexOf(marker), index + match[5].indexOf(marker) + marker.length, SYN.keyword);
    }
  }
  return { spans, inBlock: false };
}

/**
 * Highlight one line (already tab-expanded).
 * `inBlock` is the multi-line state coming from the previous line.
 */
export function highlightLine(
  line: string,
  lang: LangSpec,
  inBlock = false
): { spans: Span[]; inBlock: boolean } {
  switch (lang.id) {
    case "ts":
    case "js":
    case "java":
      return codeLine(line, lang, inBlock);
    case "json":
      return jsonLine(line);
    case "yaml":
      return yamlLine(line);
    case "props":
      return propsLine(line);
    case "shell":
      return shellLine(line);
    case "batch":
      return batchLine(line);
    case "html":
      return markupLine(line, lang, inBlock);
    case "markdown":
      return markdownLine(line, inBlock);
    default:
      return { spans: [], inBlock };
  }
}

function escape(text: string): string {
  return text.replace(/[{}]/g, (ch) => (ch === "{" ? "{open}" : "{close}"));
}

function tag(color: string, text: string): string {
  return `{${color}-fg}${text}{/}`;
}

/**
 * Turn per-cell colors into blessed markup: adjacent cells of the same color
 * share one tag, the caret cell keeps its own selection background.
 */
export function paintLine(text: string, colors: string[], caret = -1): string {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    if (i === caret) {
      out += `{${PAL.selectBg}-bg}{${PAL.bright}-fg}${escape(text[i])}{/}{/}`;
      continue;
    }
    const color = colors[i] ?? SYN.plain;
    let j = i;
    while (j + 1 < text.length && j + 1 !== caret && (colors[j + 1] ?? SYN.plain) === color) j++;
    out += tag(color, escape(text.slice(i, j + 1)));
    i = j;
  }
  if (caret >= text.length) out += `{${PAL.selectBg}-bg} {/}`;
  return out;
}
