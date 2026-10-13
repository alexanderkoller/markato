//! One full Comrak parse and one HTML traversal produce both panes' records.
//! The arena never crosses the ABI: only owned, immutable prepared data does.
use comrak::{
    Arena, Options,
    html::{self, ChildRendering, Context, format_document_with_formatter, format_node_default},
    nodes::{ListType, Node, NodeValue},
    options::Plugins,
    parse_document,
};
use std::{
    cell::RefCell,
    ffi::{CStr, CString, c_char, c_void},
    fmt::{self, Write},
    panic::{AssertUnwindSafe, catch_unwind},
    rc::Rc,
    slice,
};

mod highlight;
#[cfg(test)]
mod highlight_tests;
mod mermaid;
#[cfg(test)]
mod mermaid_tests;

type MathRenderer =
    Option<unsafe extern "C" fn(*mut c_void, *const u8, usize, bool) -> *mut c_char>;
unsafe extern "C" {
    fn free(pointer: *mut c_void);
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Span {
    kind: u8,
    from: usize,
    to: usize,
}

struct Block {
    kind: u8,
    from: usize,
    to: usize,
    html: String,
    heading_title: String,
    spans: Vec<Span>,
}
struct CapturedBlock {
    block: Block,
    bytes: std::ops::Range<usize>,
}
struct ParsedDocument {
    length: usize,
    has_references: bool,
    blocks: Vec<Block>,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct StringView {
    bytes: *const u8,
    length: usize,
}
#[repr(C)]
pub struct BlockRecord {
    id: usize,
    kind: u8,
    from: usize,
    to: usize,
    span_start: usize,
    span_count: usize,
    html: StringView,
    heading_title: StringView,
}
#[repr(C)]
pub struct SpanRecord {
    kind: u8,
    from: usize,
    to: usize,
}
#[repr(C)]
pub struct ResultView {
    revision: i64,
    from: usize,
    to: usize,
    has_references: bool,
    blocks: *const BlockRecord,
    block_count: usize,
    spans: *const SpanRecord,
    span_count: usize,
}
pub struct AstraComrakResult {
    revision: i64,
    from: usize,
    to: usize,
    has_references: bool,
    blocks: Vec<BlockRecord>,
    spans: Vec<SpanRecord>,
    // StringViews point into these output strings. Moving String headers does
    // not move their heap allocations; parser-only block/span state is dropped.
    _html: Vec<String>,
    _heading_titles: Vec<String>,
}

fn string_view(text: &str) -> StringView {
    StringView {
        bytes: text.as_ptr(),
        length: text.len(),
    }
}

mod kind {
    pub const PARAGRAPH: u8 = 1;
    pub const MATH_BLOCK: u8 = 14;
    pub const ORDERED_LIST: u8 = 15;
    pub const BULLET_LIST: u8 = 16;
    pub const BLOCKQUOTE: u8 = 17;
    pub const TABLE: u8 = 18;
    pub const FENCED_CODE: u8 = 19;
    pub const CODE_BLOCK: u8 = 20;
    pub const HORIZONTAL_RULE: u8 = 21;
    pub const HTML_BLOCK: u8 = 22;
    pub const LINK_REFERENCE: u8 = 23;
    pub const EMPTY: u8 = 24;
    pub const HEADER_MARK: u8 = 25;
    pub const STRONG: u8 = 26;
    pub const EMPHASIS: u8 = 27;
    pub const EMPHASIS_MARK: u8 = 28;
    pub const LINK: u8 = 29;
    pub const LINK_MARK: u8 = 30;
    pub const URL: u8 = 31;
    pub const CODE_MARK: u8 = 32;
    pub const MATH_INLINE: u8 = 33;
    pub const LIST_MARK: u8 = 34;
    pub const QUOTE_MARK: u8 = 35;
    pub const STRIKETHROUGH: u8 = 36;
    pub const STRIKETHROUGH_MARK: u8 = 37;
    pub fn heading(setext: bool, level: u8) -> u8 {
        (if setext { 8 } else { 2 }) + level.saturating_sub(1).min(5)
    }
}

fn parse_records(
    source: String,
    base: usize,
    revision: i64,
    callback: MathRenderer,
    opaque: *mut c_void,
) -> Result<AstraComrakResult, String> {
    let document = parse_source(source, callback, opaque)?;
    let span_count = document.blocks.iter().map(|block| block.spans.len()).sum();
    let mut block_records = Vec::with_capacity(document.blocks.len());
    let mut span_records = Vec::with_capacity(span_count);
    let mut html = Vec::with_capacity(document.blocks.len());
    let mut heading_titles = Vec::with_capacity(document.blocks.len());
    for (index, block) in document.blocks.into_iter().enumerate() {
        let span_start = span_records.len();
        for span in block.spans {
            span_records.push(SpanRecord {
                kind: span.kind,
                from: base + span.from,
                to: base + span.to,
            });
        }
        let html_view = string_view(&block.html);
        let heading_title_view = string_view(&block.heading_title);
        html.push(block.html);
        heading_titles.push(block.heading_title);
        block_records.push(BlockRecord {
            id: index + 1,
            kind: block.kind,
            from: base + block.from,
            to: base + block.to,
            span_start,
            span_count: span_records.len() - span_start,
            html: html_view,
            heading_title: heading_title_view,
        });
    }
    Ok(AstraComrakResult {
        revision,
        from: base,
        to: base + document.length,
        has_references: document.has_references,
        blocks: block_records,
        spans: span_records,
        _html: html,
        _heading_titles: heading_titles,
    })
}

fn has_reference_syntax(source: &str) -> bool {
    source.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with('[') && line.contains("]:")
    }) || source.contains("][")
        || source.contains("][]")
}

/// Line starts and Unicode width changes avoid a dense eight-byte-per-byte map.
struct Index {
    lines: Vec<usize>,
    unicode: Vec<(usize, usize)>,
    length: usize,
}
impl Index {
    fn new(source: &str) -> Self {
        let mut unicode = Vec::new();
        let mut extra = 0;
        for (offset, ch) in source.char_indices() {
            if !ch.is_ascii() {
                extra += ch.len_utf8() - ch.len_utf16();
                unicode.push((offset + ch.len_utf8(), extra));
            }
        }
        let bytes = source.as_bytes();
        let mut lines = vec![0];
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'\r' {
                i += 1;
                if bytes.get(i) == Some(&b'\n') {
                    i += 1;
                }
                lines.push(i);
            } else if bytes[i] == b'\n' {
                i += 1;
                lines.push(i);
            } else {
                i += 1;
            }
        }
        Self {
            lines,
            unicode,
            length: bytes.len(),
        }
    }
    fn utf16(&self, byte: usize) -> usize {
        let n = self.unicode.partition_point(|&(end, _)| end <= byte);
        byte - if n == 0 { 0 } else { self.unicode[n - 1].1 }
    }
    fn offset(&self, line: usize, column: usize, end: bool) -> usize {
        let start = self
            .lines
            .get(line.saturating_sub(1))
            .copied()
            .unwrap_or(self.length);
        (start + column.saturating_sub(if end { 0 } else { 1 })).min(self.length)
    }
    fn range(&self, node: Node<'_>, source: &str) -> std::ops::Range<usize> {
        let pos = node.data().sourcepos;
        let mut from = self.offset(pos.start.line, pos.start.column, false);
        let mut to = self.offset(pos.end.line, pos.end.column, true).max(from);
        while from > 0 && !source.is_char_boundary(from) {
            from -= 1;
        }
        while to < source.len() && !source.is_char_boundary(to) {
            to += 1;
        }
        from..to
    }
}

#[derive(Default)]
struct Capture {
    html: String,
}
#[derive(Clone)]
struct Output(Rc<RefCell<Capture>>);
impl Write for Output {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        self.0.borrow_mut().html.push_str(text);
        Ok(())
    }
}
struct Render<'s> {
    source: &'s str,
    index: Index,
    blocks: Vec<CapturedBlock>,
    spans: Vec<Span>,
    output: Output,
    math: MathRenderer,
    context: *mut c_void,
}

fn display_paragraph(node: Node<'_>) -> bool {
    let mut math = false;
    for ch in node.children() {
        match ch.data().value {
            NodeValue::Math(ref m) if m.display_math => math = true,
            NodeValue::SoftBreak | NodeValue::LineBreak => (),
            _ => return false,
        }
    }
    math
}
fn block_kind(node: Node<'_>) -> u8 {
    match &node.data().value {
        NodeValue::Heading(h) => kind::heading(h.setext, h.level),
        NodeValue::Paragraph if display_paragraph(node) => kind::MATH_BLOCK,
        NodeValue::Paragraph => kind::PARAGRAPH,
        NodeValue::List(l) => {
            if l.list_type == ListType::Ordered {
                kind::ORDERED_LIST
            } else {
                kind::BULLET_LIST
            }
        }
        NodeValue::BlockQuote => kind::BLOCKQUOTE,
        NodeValue::Table(_) => kind::TABLE,
        NodeValue::CodeBlock(c) if c.info == "math" => kind::MATH_BLOCK,
        NodeValue::CodeBlock(c) => {
            if c.fenced {
                kind::FENCED_CODE
            } else {
                kind::CODE_BLOCK
            }
        }
        NodeValue::ThematicBreak => kind::HORIZONTAL_RULE,
        NodeValue::HtmlBlock(_) => kind::HTML_BLOCK,
        _ => kind::PARAGRAPH,
    }
}

/// Produce a compact navigation label from the parser's inline tree. This is
/// deliberately separate from rendered HTML so callers never have to strip
/// tags or reparse Markdown to build an outline.
fn heading_title(node: Node<'_>) -> String {
    if !matches!(node.data().value, NodeValue::Heading(_)) {
        return String::new();
    }
    let mut title = String::new();
    for child in node.descendants().skip(1) {
        match &child.data().value {
            NodeValue::Text(text) => title.push_str(text),
            NodeValue::Code(code) => title.push_str(&code.literal),
            NodeValue::Math(math) => title.push_str(&math.literal),
            NodeValue::SoftBreak | NodeValue::LineBreak => title.push(' '),
            _ => (),
        }
    }
    title.split_whitespace().collect::<Vec<_>>().join(" ")
}
impl Render<'_> {
    fn span(&mut self, kind: u8, range: std::ops::Range<usize>) {
        if range.start < range.end {
            self.spans.push(Span {
                kind,
                from: self.index.utf16(range.start),
                to: self.index.utf16(range.end),
            });
        }
    }
    fn observe(&mut self, node: Node<'_>) {
        let range = self.index.range(node, self.source);
        let raw = &self.source[range.clone()];
        match &node.data().value {
            NodeValue::Heading(h) => {
                self.span(kind::heading(h.setext, h.level), range.clone());
                if h.setext {
                    let start = raw.rfind('\n').map_or(range.start, |i| range.start + i + 1);
                    self.span(kind::HEADER_MARK, start..range.end);
                } else {
                    let count = raw.bytes().take_while(|&b| b == b'#').count();
                    self.span(kind::HEADER_MARK, range.start..range.start + count);
                    if h.closed {
                        let trimmed = raw.trim_end();
                        let count = trimmed.bytes().rev().take_while(|&b| b == b'#').count();
                        self.span(
                            kind::HEADER_MARK,
                            range.start + trimmed.len() - count..range.start + trimmed.len(),
                        );
                    }
                }
            }
            NodeValue::Strong | NodeValue::Emph => {
                let strong = matches!(node.data().value, NodeValue::Strong);
                self.span(
                    if strong { kind::STRONG } else { kind::EMPHASIS },
                    range.clone(),
                );
                let width = if strong { 2 } else { 1 };
                if raw.len() >= width * 2 {
                    self.span(kind::EMPHASIS_MARK, range.start..range.start + width);
                    self.span(kind::EMPHASIS_MARK, range.end - width..range.end);
                }
            }
            NodeValue::Strikethrough => {
                self.span(kind::STRIKETHROUGH, range.clone());
                if raw.len() >= 4 {
                    self.span(kind::STRIKETHROUGH_MARK, range.start..range.start + 2);
                    self.span(kind::STRIKETHROUGH_MARK, range.end - 2..range.end);
                }
            }
            NodeValue::Link(_) | NodeValue::Image(_) => {
                self.span(kind::LINK, range.clone());
                for (offset, ch) in raw.char_indices() {
                    if matches!(ch, '[' | ']' | '(' | ')' | '!') {
                        self.span(
                            kind::LINK_MARK,
                            range.start + offset..range.start + offset + 1,
                        );
                    }
                }
                if let Some(start) = raw.rfind("](") {
                    let a = start + 2;
                    let b = raw[a..]
                        .find(|c: char| c.is_whitespace() || c == ')')
                        .map_or(raw.len(), |n| a + n);
                    self.span(kind::URL, range.start + a..range.start + b);
                }
            }
            NodeValue::Code(_) => {
                let width = raw.bytes().take_while(|&b| b == b'`').count();
                if width > 0 && raw.len() >= width * 2 {
                    self.span(kind::CODE_MARK, range.start..range.start + width);
                    self.span(kind::CODE_MARK, range.end - width..range.end);
                }
            }
            NodeValue::Math(m) => self.span(
                if m.display_math {
                    kind::MATH_BLOCK
                } else {
                    kind::MATH_INLINE
                },
                range,
            ),
            NodeValue::CodeBlock(c) => {
                if c.info == "math" {
                    self.span(kind::MATH_BLOCK, range.clone());
                }
                if c.fenced {
                    let first = raw.find(['\r', '\n']).unwrap_or(raw.len());
                    self.span(kind::CODE_MARK, range.start..range.start + first);
                    if c.closed {
                        let last = raw.rfind('\n').map_or(0, |i| i + 1);
                        self.span(kind::CODE_MARK, range.start + last..range.end);
                    }
                }
            }
            NodeValue::Item(_) => {
                let count = raw
                    .bytes()
                    .take_while(|b| {
                        b.is_ascii_digit() || matches!(b, b'.' | b')' | b'*' | b'-' | b'+')
                    })
                    .count();
                self.span(kind::LIST_MARK, range.start..range.start + count);
            }
            NodeValue::BlockQuote => {
                // Parser-recognized quote prefixes only; no Markdown reparse.
                let mut offset = range.start;
                for line in raw.split_inclusive('\n') {
                    let white = line
                        .bytes()
                        .take_while(|b| matches!(b, b' ' | b'\t'))
                        .count();
                    if line.as_bytes().get(white) == Some(&b'>') {
                        self.span(kind::QUOTE_MARK, offset + white..offset + white + 1);
                    }
                    offset += line.len();
                }
            }
            _ => (),
        }
    }
}

fn allowed_url(url: &str) -> bool {
    url.to_ascii_lowercase().starts_with("file:") || !html::dangerous_url(url)
}
fn image_url(url: &str) -> String {
    if url.to_ascii_lowercase().starts_with("data:")
        || url.to_ascii_lowercase().starts_with("astra-asset:")
    {
        return url.into();
    }
    let mut out = "astra-asset://image/?source=".to_owned();
    for byte in url.bytes() {
        if byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&byte) {
            out.push(byte as char);
        } else {
            write!(out, "%{byte:02X}").unwrap();
        }
    }
    out
}
fn math(
    context: &mut Context<Render<'_>>,
    node: Node<'_>,
    tex: &str,
    display: bool,
) -> Result<ChildRendering, fmt::Error> {
    if let Some(render) = context.user.math {
        let pointer = unsafe { render(context.user.context, tex.as_ptr(), tex.len(), display) };
        if pointer.is_null() {
            return Err(fmt::Error);
        }
        let rendered = unsafe { CStr::from_ptr(pointer) }.to_string_lossy();
        let result = context.write_str(&rendered);
        unsafe {
            free(pointer.cast());
        }
        result?;
        Ok(ChildRendering::Skip)
    } else {
        format_node_default(context, node, true)
    }
}
fn format_node(
    context: &mut Context<Render<'_>>,
    node: Node<'_>,
    entering: bool,
) -> Result<ChildRendering, fmt::Error> {
    let top = node
        .parent()
        .is_some_and(|p| matches!(p.data().value, NodeValue::Document));
    if entering {
        if top {
            let bytes = context.user.index.range(node, context.user.source);
            let from = context.user.index.utf16(bytes.start);
            let to = context.user.index.utf16(bytes.end);
            context.user.blocks.push(CapturedBlock {
                bytes,
                block: Block {
                    kind: block_kind(node),
                    from,
                    to,
                    html: String::new(),
                    heading_title: heading_title(node),
                    spans: vec![],
                },
            });
        }
        context.user.observe(node);
        if matches!(node.data().value, NodeValue::Image(_)) {
            // Image alt children use Plain rendering and bypass the formatter.
            for child in node.descendants().skip(1) {
                context.user.observe(child);
            }
        }
    }
    let result = match &node.data().value {
        NodeValue::Paragraph if display_paragraph(node) => Ok(ChildRendering::HTML),
        NodeValue::Math(m) if entering => math(context, node, &m.literal, m.display_math),
        NodeValue::Math(_) => Ok(ChildRendering::Skip),
        NodeValue::CodeBlock(c) if c.info == "math" && entering => {
            math(context, node, &c.literal, true)
        }
        NodeValue::CodeBlock(c) if c.info == "math" => Ok(ChildRendering::Skip),
        NodeValue::CodeBlock(c)
            if c.fenced && c.info.split_whitespace().next() == Some("mermaid") =>
        {
            if entering {
                match mermaid::image(&c.literal) {
                    Ok(html) => context.write_str(&html)?,
                    Err(message) => {
                        context.write_str("<div class=\"mermaid-error\"><p>")?;
                        context.escape(message)?;
                        context.write_str("</p><pre><code class=\"language-mermaid\">")?;
                        context.escape(&c.literal)?;
                        context.write_str("</code></pre></div>\n")?;
                    }
                }
            }
            Ok(ChildRendering::Skip)
        }
        NodeValue::Link(link) => {
            if entering {
                context.write_str("<a href=\"")?;
                if allowed_url(&link.url) {
                    context.escape_href(&link.url)?;
                }
                if !link.title.is_empty() {
                    context.write_str("\" title=\"")?;
                    context.escape(&link.title)?;
                }
                context.write_str("\">")?;
            } else {
                context.write_str("</a>")?;
            }
            Ok(ChildRendering::HTML)
        }
        NodeValue::Image(link) => {
            if entering {
                context.write_str("<img src=\"")?;
                if allowed_url(&link.url) {
                    context.escape_href(&image_url(&link.url))?;
                }
                context.write_str("\" alt=\"")?;
                Ok(ChildRendering::Plain)
            } else {
                if !link.title.is_empty() {
                    context.write_str("\" title=\"")?;
                    context.escape(&link.title)?;
                }
                context.write_str("\" loading=\"eager\" />")?;
                Ok(ChildRendering::HTML)
            }
        }
        _ => format_node_default(context, node, entering),
    }?;
    if top && !entering {
        let html = std::mem::take(&mut context.user.output.0.borrow_mut().html);
        let spans = std::mem::take(&mut context.user.spans);
        let block = &mut context.user.blocks.last_mut().unwrap().block;
        block.html = html;
        block.spans = spans;
    }
    Ok(result)
}

fn parse_source(
    source: String,
    callback: MathRenderer,
    opaque: *mut c_void,
) -> Result<ParsedDocument, String> {
    let has_references = has_reference_syntax(&source);
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.strikethrough = true;
    options.extension.math_dollars = true;
    options.extension.math_latex = true;
    options.extension.math_code = true;
    options.render.r#unsafe = true;
    let arena = Arena::new();
    let root = parse_document(&arena, &source, &options);
    let index = Index::new(&source);
    let length = index.utf16(source.len());
    let mut output = Output(Rc::new(RefCell::new(Capture::default())));
    let state = Render {
        source: &source,
        index,
        blocks: vec![],
        spans: vec![],
        output: output.clone(),
        math: callback,
        context: opaque,
    };
    let mut plugins = Plugins::default();
    plugins.render.codefence_syntax_highlighter = Some(&highlight::HIGHLIGHTER);
    let state =
        format_document_with_formatter(root, &options, &mut output, &plugins, format_node, state)
            .map_err(|_| "Markdown or math rendering failed".to_owned())?;
    let index = state.index;
    let mut blocks = Vec::new();
    let mut position = 0;
    // Comrak removes reference definitions from its AST. Preserve their source
    // intervals as zero-output blocks so identities cover editing/navigation.
    for captured in state.blocks {
        if captured.bytes.start > position {
            let gap = &source[position..captured.bytes.start];
            if !gap.trim().is_empty() {
                blocks.push(Block {
                    kind: kind::LINK_REFERENCE,
                    from: index.utf16(position),
                    to: index.utf16(captured.bytes.start),
                    html: String::new(),
                    heading_title: String::new(),
                    spans: vec![],
                });
            }
        }
        position = captured.bytes.end;
        blocks.push(captured.block);
    }
    if position < source.len() && !source[position..].trim().is_empty() {
        blocks.push(Block {
            kind: kind::LINK_REFERENCE,
            from: index.utf16(position),
            to: length,
            html: String::new(),
            heading_title: String::new(),
            spans: vec![],
        });
    }
    if blocks.is_empty() && length > 0 {
        blocks.push(Block {
            kind: kind::EMPTY,
            from: 0,
            to: length,
            html: String::new(),
            heading_title: String::new(),
            spans: vec![],
        });
    }
    Ok(ParsedDocument {
        length,
        has_references,
        blocks,
    })
}

thread_local! { static ERROR: RefCell<String> = const {RefCell::new(String::new())}; }
fn fail(error: &str) {
    ERROR.with(|e| *e.borrow_mut() = error.into());
}

/// Parse one owned source slice into flat records. The returned allocation owns
/// all record arrays and byte slices, but no parser or document state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn astra_comrak_parse_records(
    source: *const u16,
    length: usize,
    base: usize,
    revision: i64,
    math: MathRenderer,
    context: *mut c_void,
) -> *mut AstraComrakResult {
    if length > 0 && source.is_null() {
        return std::ptr::null_mut();
    }
    let units = if length == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(source, length) }
    };
    match catch_unwind(AssertUnwindSafe(|| {
        parse_records(
            String::from_utf16_lossy(units),
            base,
            revision,
            math,
            context,
        )
    })) {
        Ok(Ok(result)) => Box::into_raw(Box::new(result)),
        Ok(Err(error)) => {
            fail(&error);
            std::ptr::null_mut()
        }
        Err(_) => {
            fail("Comrak stateless parse panicked");
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// Result must be a live pointer returned by astra_comrak_parse_records. View
/// remains valid only until astra_comrak_result_free is called.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn astra_comrak_result_view(
    result: *const AstraComrakResult,
    view: *mut ResultView,
) -> bool {
    let (Some(result), Some(view)) = (unsafe { result.as_ref() }, unsafe { view.as_mut() }) else {
        return false;
    };
    *view = ResultView {
        revision: result.revision,
        from: result.from,
        to: result.to,
        has_references: result.has_references,
        blocks: result.blocks.as_ptr(),
        block_count: result.blocks.len(),
        spans: result.spans.as_ptr(),
        span_count: result.spans.len(),
    };
    true
}

/// # Safety
/// Result must be null or an unreleased pointer returned by
/// astra_comrak_parse_records.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn astra_comrak_result_free(result: *mut AstraComrakResult) {
    if !result.is_null() {
        drop(unsafe { Box::from_raw(result) });
    }
}
/// # Safety
/// The pointer must be null or an unreleased string returned by this API.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn astra_comrak_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn astra_comrak_error() -> *mut c_char {
    ERROR.with(|e| CString::new(e.borrow().as_str()).unwrap().into_raw())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn doc(source: &str) -> ParsedDocument {
        parse_source(source.into(), None, std::ptr::null_mut()).unwrap()
    }
    #[test]
    fn native_html_styles_and_utf16_share_one_tree() {
        let source = "# 😀 *Heading* with [`code`](https://example.com) and $x^2$\r\n\r\nA **bold** and *italic* [link](https://example.com).\r\n";
        let d = doc(source);
        assert_eq!(d.length, source.encode_utf16().count());
        assert!(d.blocks[0].html.contains("<h1>"));
        assert_eq!(d.blocks[0].heading_title, "😀 Heading with code and x^2");
        let strong = d.blocks[1]
            .spans
            .iter()
            .find(|s| s.kind == kind::STRONG)
            .unwrap();
        let units: Vec<_> = source.encode_utf16().collect();
        assert_eq!(
            String::from_utf16(&units[strong.from..strong.to]).unwrap(),
            "**bold**"
        );
    }
    #[test]
    fn one_table_one_container_and_safe_assets() {
        let d = doc(
            "> 1. First\n>    - Nested **bold**\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n![local](file:///tmp/image.png)\n\n[bad](javascript:alert(1))\n",
        );
        assert_eq!(d.blocks[0].kind, kind::BLOCKQUOTE);
        assert!(d.blocks[0].html.contains("<ol>") && d.blocks[0].html.contains("<ul>"));
        assert_eq!(d.blocks[1].kind, kind::TABLE);
        assert!(
            d.blocks[2]
                .html
                .contains("astra-asset://image/?source=file%3A%2F%2F%2Ftmp%2Fimage.png")
        );
        assert!(!d.blocks[3].html.contains("href=\"javascript:"));
    }
    #[test]
    fn definitions_before_paragraphs_preserve_inline_source_positions() {
        for source in [
            "[r]: https://example.com\nA 😀 **bold** [reference][r].\n",
            "[r]: https://example.com\r\n  \"title\"\r\nA 😀 **bold** [reference][r].\r\n",
            "> [r]: https://example.com\n> A 😀 **bold** [reference][r].\n",
            "- [r]: https://example.com\n  A 😀 **bold** [reference][r].\n",
            "[r]: https://example.com\nA 😀 **bold** [reference][r].\n===\n",
        ] {
            let d = doc(source);
            let units: Vec<_> = source.encode_utf16().collect();
            let strong = d
                .blocks
                .iter()
                .flat_map(|b| &b.spans)
                .find(|s| s.kind == kind::STRONG)
                .unwrap();
            assert_eq!(
                String::from_utf16(&units[strong.from..strong.to]).unwrap(),
                "**bold**"
            );
            let link = d
                .blocks
                .iter()
                .flat_map(|b| &b.spans)
                .find(|s| s.kind == kind::LINK)
                .unwrap();
            assert_eq!(
                String::from_utf16(&units[link.from..link.to]).unwrap(),
                "[reference][r]"
            );
        }
    }
}
