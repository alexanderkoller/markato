//! One full Comrak parse and one HTML traversal produce both panes' records.
//! The arena never crosses the ABI: only owned, immutable prepared data does.
use comrak::{
    Arena, Options,
    html::{self, ChildRendering, Context, format_document_with_formatter, format_node_default},
    nodes::{ListType, Node, NodeValue},
    options::Plugins,
    parse_document,
};
use serde::Serialize;
use std::{
    cell::RefCell,
    collections::{HashMap, VecDeque},
    ffi::{CStr, CString, c_char, c_void},
    fmt::{self, Write},
    panic::{AssertUnwindSafe, catch_unwind},
    rc::Rc,
    slice,
};

type MathRenderer =
    Option<unsafe extern "C" fn(*mut c_void, *const u8, usize, bool) -> *mut c_char>;
unsafe extern "C" {
    fn free(pointer: *mut c_void);
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Edit {
    from: usize,
    to: usize,
    inserted: usize,
}

#[derive(Clone, Serialize, Debug, PartialEq, Eq)]
struct Span {
    kind: String,
    from: usize,
    to: usize,
}

struct Block {
    id: u64,
    kind: String,
    from: usize,
    to: usize,
    bytes: std::ops::Range<usize>,
    html: String,
    spans: Vec<Span>,
}
pub struct Document {
    source: String,
    length: usize,
    blocks: Vec<Block>,
    next_id: u64,
    change: Option<BlockChange>,
}

struct BlockChange {
    prefix: usize,
    suffix: usize,
    shift: isize,
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
    blocks: Vec<Block>,
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
fn block_kind(node: Node<'_>) -> String {
    match &node.data().value {
        NodeValue::Heading(h) => format!(
            "{}{}",
            if h.setext {
                "SetextHeading"
            } else {
                "ATXHeading"
            },
            h.level
        ),
        NodeValue::Paragraph if display_paragraph(node) => "MathBlock".into(),
        NodeValue::Paragraph => "Paragraph".into(),
        NodeValue::List(l) => if l.list_type == ListType::Ordered {
            "OrderedList"
        } else {
            "BulletList"
        }
        .into(),
        NodeValue::BlockQuote => "Blockquote".into(),
        NodeValue::Table(_) => "Table".into(),
        NodeValue::CodeBlock(c) if c.info == "math" => "MathBlock".into(),
        NodeValue::CodeBlock(c) => if c.fenced { "FencedCode" } else { "CodeBlock" }.into(),
        NodeValue::ThematicBreak => "HorizontalRule".into(),
        NodeValue::HtmlBlock(_) => "HTMLBlock".into(),
        _ => "Paragraph".into(),
    }
}
impl Render<'_> {
    fn span(&mut self, kind: &str, range: std::ops::Range<usize>) {
        if range.start < range.end {
            self.spans.push(Span {
                kind: kind.into(),
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
                self.span(
                    &format!(
                        "{}{}",
                        if h.setext {
                            "SetextHeading"
                        } else {
                            "ATXHeading"
                        },
                        h.level
                    ),
                    range.clone(),
                );
                if h.setext {
                    let start = raw.rfind('\n').map_or(range.start, |i| range.start + i + 1);
                    self.span("HeaderMark", start..range.end);
                } else {
                    let count = raw.bytes().take_while(|&b| b == b'#').count();
                    self.span("HeaderMark", range.start..range.start + count);
                    if h.closed {
                        let trimmed = raw.trim_end();
                        let count = trimmed.bytes().rev().take_while(|&b| b == b'#').count();
                        self.span(
                            "HeaderMark",
                            range.start + trimmed.len() - count..range.start + trimmed.len(),
                        );
                    }
                }
            }
            NodeValue::Strong | NodeValue::Emph => {
                let strong = matches!(node.data().value, NodeValue::Strong);
                self.span(
                    if strong { "StrongEmphasis" } else { "Emphasis" },
                    range.clone(),
                );
                let width = if strong { 2 } else { 1 };
                if raw.len() >= width * 2 {
                    self.span("EmphasisMark", range.start..range.start + width);
                    self.span("EmphasisMark", range.end - width..range.end);
                }
            }
            NodeValue::Link(_) | NodeValue::Image(_) => {
                self.span("Link", range.clone());
                for (offset, ch) in raw.char_indices() {
                    if matches!(ch, '[' | ']' | '(' | ')' | '!') {
                        self.span("LinkMark", range.start + offset..range.start + offset + 1);
                    }
                }
                if let Some(start) = raw.rfind("](") {
                    let a = start + 2;
                    let b = raw[a..]
                        .find(|c: char| c.is_whitespace() || c == ')')
                        .map_or(raw.len(), |n| a + n);
                    self.span("URL", range.start + a..range.start + b);
                }
            }
            NodeValue::Code(_) => {
                let width = raw.bytes().take_while(|&b| b == b'`').count();
                if width > 0 && raw.len() >= width * 2 {
                    self.span("CodeMark", range.start..range.start + width);
                    self.span("CodeMark", range.end - width..range.end);
                }
            }
            NodeValue::Math(m) => self.span(
                if m.display_math {
                    "MathBlock"
                } else {
                    "MathInline"
                },
                range,
            ),
            NodeValue::CodeBlock(c) => {
                if c.info == "math" {
                    self.span("MathBlock", range.clone());
                }
                if c.fenced {
                    let first = raw.find(['\r', '\n']).unwrap_or(raw.len());
                    self.span("CodeMark", range.start..range.start + first);
                    if c.closed {
                        let last = raw.rfind('\n').map_or(0, |i| i + 1);
                        self.span("CodeMark", range.start + last..range.end);
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
                self.span("ListMark", range.start..range.start + count);
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
                        self.span("QuoteMark", offset + white..offset + white + 1);
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
            context.user.blocks.push(Block {
                id: 0,
                kind: block_kind(node),
                from,
                to,
                bytes,
                html: String::new(),
                spans: vec![],
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
        NodeValue::HtmlBlock(_) if entering => {
            context.write_str("<pre>")?;
            let range = context.user.index.range(node, context.user.source);
            let text = context.user.source[range].to_owned();
            context.escape(&text)?;
            context.write_str("</pre>\n")?;
            Ok(ChildRendering::Skip)
        }
        NodeValue::HtmlBlock(_) => Ok(ChildRendering::Skip),
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
        let block = context.user.blocks.last_mut().unwrap();
        block.html = html;
        block.spans = spans;
    }
    Ok(result)
}

fn prepare(
    source: String,
    previous: Option<&Document>,
    edits: &[Edit],
    callback: MathRenderer,
    opaque: *mut c_void,
) -> Result<Document, String> {
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.math_dollars = true;
    options.extension.math_latex = true;
    options.extension.math_code = true;
    options.render.escape = true;
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
    let state = format_document_with_formatter(
        root,
        &options,
        &mut output,
        &Plugins::default(),
        format_node,
        state,
    )
    .map_err(|_| "Markdown or math rendering failed".to_owned())?;
    let index = state.index;
    let mut blocks = Vec::new();
    let mut position = 0;
    // Comrak removes reference definitions from its AST. Preserve their source
    // intervals as zero-output blocks so identities cover editing/navigation.
    for block in state.blocks {
        if block.bytes.start > position {
            let gap = &source[position..block.bytes.start];
            if !gap.trim().is_empty() {
                blocks.push(Block {
                    id: 0,
                    kind: "LinkReference".into(),
                    from: index.utf16(position),
                    to: index.utf16(block.bytes.start),
                    bytes: position..block.bytes.start,
                    html: String::new(),
                    spans: vec![],
                });
            }
        }
        position = block.bytes.end;
        blocks.push(block);
    }
    if position < source.len() && !source[position..].trim().is_empty() {
        blocks.push(Block {
            id: 0,
            kind: "LinkReference".into(),
            from: index.utf16(position),
            to: length,
            bytes: position..source.len(),
            html: String::new(),
            spans: vec![],
        });
    }
    if blocks.is_empty() && length > 0 {
        blocks.push(Block {
            id: 0,
            kind: "Empty".into(),
            from: 0,
            to: length,
            bytes: 0..source.len(),
            html: String::new(),
            spans: vec![],
        });
    }
    let mut next_id = previous.map_or(0, |d| d.next_id);
    let mut positioned = HashMap::new();
    let mut contents: HashMap<(&str, &str, &str), VecDeque<usize>> = HashMap::new();
    if let Some(old) = previous {
        for (i, block) in old.blocks.iter().enumerate() {
            // Content matching is only needed when adopting a separately
            // parsed copy of the same document. On an edit, coordinates plus
            // the edit list identify every retainable block. Hashing every
            // old source and HTML string here made the first keystroke scan
            // and hash the complete document a second time.
            if edits.is_empty() {
                contents
                    .entry((&block.kind, &old.source[block.bytes.clone()], &block.html))
                    .or_default()
                    .push_back(i);
            }
            let (mut from, mut to, mut valid) = (block.from, block.to, true);
            for edit in edits {
                if edit.to <= from {
                    let delta = edit.inserted as isize - (edit.to - edit.from) as isize;
                    from = from.saturating_add_signed(delta);
                    to = to.saturating_add_signed(delta);
                } else if edit.from < to {
                    valid = false;
                    break;
                }
            }
            if valid {
                positioned.insert(from, (i, to));
            }
        }
        let mut used = vec![false; old.blocks.len()];
        for block in &mut blocks {
            let key = (&*block.kind, &source[block.bytes.clone()], &*block.html);
            let mut retained = None;
            if let Some(&(i, to)) = positioned.get(&block.from) {
                let prior = &old.blocks[i];
                if to == block.to
                    && !used[i]
                    && prior.kind == block.kind
                    && prior.html == block.html
                    && old.source[prior.bytes.clone()] == source[block.bytes.clone()]
                {
                    retained = Some(i);
                }
            }
            if retained.is_none()
                && edits.is_empty()
                && let Some(items) = contents.get_mut(&key)
            {
                while let Some(i) = items.pop_front() {
                    if !used[i] {
                        retained = Some(i);
                        break;
                    }
                }
            }
            if let Some(i) = retained {
                used[i] = true;
                block.id = old.blocks[i].id;
            } else {
                next_id += 1;
                block.id = next_id;
            }
        }
    } else {
        for block in &mut blocks {
            next_id += 1;
            block.id = next_id;
        }
    }
    let change = previous.map(|old| {
        let mut prefix = 0;
        while prefix < old.blocks.len() && prefix < blocks.len() {
            let a = &old.blocks[prefix];
            let b = &blocks[prefix];
            if a.id != b.id || a.from != b.from || a.to != b.to {
                break;
            }
            prefix += 1;
        }
        let shift = length as isize - old.length as isize;
        let mut suffix = 0;
        while suffix < old.blocks.len().saturating_sub(prefix)
            && suffix < blocks.len().saturating_sub(prefix)
        {
            let a = &old.blocks[old.blocks.len() - 1 - suffix];
            let b = &blocks[blocks.len() - 1 - suffix];
            if a.id != b.id
                || a.from.saturating_add_signed(shift) != b.from
                || a.to.saturating_add_signed(shift) != b.to
            {
                break;
            }
            suffix += 1;
        }
        BlockChange { prefix, suffix, shift }
    });
    Ok(Document {
        source,
        length,
        blocks,
        next_id,
        change,
    })
}

#[derive(Serialize)]
struct Manifest<'a> {
    id: String,
    kind: &'a str,
    from: usize,
    to: usize,
}
#[derive(Serialize)]
struct Fragment<'a> {
    id: String,
    kind: &'a str,
    from: usize,
    to: usize,
    markdown: &'a str,
    html: Option<&'a str>,
}
#[derive(Serialize)]
struct Response<'a> {
    revision: i64,
    complete: bool,
    spans: Vec<Span>,
    fragments: Vec<Fragment<'a>>,
    blocks: Option<Vec<Manifest<'a>>>,
    #[serde(rename = "blockChange")]
    block_change: Option<ManifestChange<'a>>,
}
#[derive(Serialize)]
struct ManifestChange<'a> {
    prefix: usize,
    suffix: usize,
    shift: isize,
    blocks: Vec<Manifest<'a>>,
}
fn query(
    document: &Document,
    revision: i64,
    from: usize,
    to: usize,
    manifest: u8,
    html: bool,
    fragments: bool,
) -> String {
    let (from, to) = (from.min(document.length), to.min(document.length));
    let first = document.blocks.partition_point(|b| b.to <= from);
    // Whitespace before/between blocks belongs to the following block.
    let first = if first == document.blocks.len() && to > from {
        first.saturating_sub(1)
    } else {
        first
    };
    let selected: Vec<_> = document
        .blocks
        .iter()
        .enumerate()
        .skip(first)
        .take_while(|(i, _)| *i == 0 || document.blocks[*i - 1].to < to)
        .map(|(_, b)| b)
        .collect();
    let spans = selected
        .iter()
        .flat_map(|b| b.spans.iter())
        .filter_map(|s| {
            let a = s.from.max(from);
            let b = s.to.min(to);
            (a < b).then(|| Span {
                kind: s.kind.clone(),
                from: a,
                to: b,
            })
        })
        .collect();
    let fragments = if fragments {
        selected
            .iter()
            .map(|b| Fragment {
                id: b.id.to_string(),
                kind: &b.kind,
                from: b.from,
                to: b.to,
                markdown: &document.source[b.bytes.clone()],
                html: html.then_some(&b.html),
            })
            .collect()
    } else {
        vec![]
    };
    let blocks = (manifest == 1).then(|| {
        document
            .blocks
            .iter()
            .map(|b| Manifest {
                id: b.id.to_string(),
                kind: &b.kind,
                from: b.from,
                to: b.to,
            })
            .collect()
    });
    let block_change = (manifest == 2).then(|| {
        let change = document.change.as_ref().expect("delta manifest requires a previous document");
        let end = document.blocks.len().saturating_sub(change.suffix);
        ManifestChange {
            prefix: change.prefix,
            suffix: change.suffix,
            shift: change.shift,
            blocks: document.blocks[change.prefix..end].iter().map(|b| Manifest {
                id: b.id.to_string(), kind: &b.kind, from: b.from, to: b.to,
            }).collect(),
        }
    });
    serde_json::to_string(&Response {
        revision,
        complete: false,
        spans,
        fragments,
        blocks,
        block_change,
    })
    .unwrap()
}

thread_local! { static ERROR: RefCell<String> = const {RefCell::new(String::new())}; }
fn fail(error: &str) {
    ERROR.with(|e| *e.borrow_mut() = error.into());
}
/// # Safety
/// The source and edit arrays must be valid for their stated lengths. Previous must be null or a live document from this API. The callback must return a malloc-owned NUL-terminated string and context must remain live during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn astra_comrak_parse(
    source: *const u16,
    length: usize,
    previous: *const Document,
    edits: *const Edit,
    edit_count: usize,
    math: MathRenderer,
    context: *mut c_void,
) -> *mut Document {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let units = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(source, length) }
        };
        let edits = if edit_count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(edits, edit_count) }
        };
        prepare(
            String::from_utf16_lossy(units),
            unsafe { previous.as_ref() },
            edits,
            math,
            context,
        )
    }));
    match result {
        Ok(Ok(doc)) => Box::into_raw(Box::new(doc)),
        Ok(Err(e)) => {
            fail(&e);
            std::ptr::null_mut()
        }
        Err(_) => {
            fail("Comrak parser panicked");
            std::ptr::null_mut()
        }
    }
}
/// # Safety
/// The pointer must be null or a live document returned by this API, with no concurrent users. It must be freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn astra_comrak_document_free(doc: *mut Document) {
    if !doc.is_null() {
        drop(unsafe { Box::from_raw(doc) });
    }
}
/// # Safety
/// The document must be a live pointer returned by this API and remain live throughout the call. The returned string must be released with astra_comrak_string_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn astra_comrak_query(
    doc: *const Document,
    revision: i64,
    from: usize,
    to: usize,
    manifest: u8,
    html: bool,
    fragments: bool,
) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        query(
            unsafe { &*doc },
            revision,
            from,
            to,
            manifest,
            html,
            fragments,
        )
    }));
    match result {
        Ok(json) => CString::new(json).unwrap().into_raw(),
        Err(_) => {
            fail("Comrak record serialization failed");
            std::ptr::null_mut()
        }
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
    fn doc(source: &str) -> Document {
        prepare(source.into(), None, &[], None, std::ptr::null_mut()).unwrap()
    }
    #[test]
    fn native_html_styles_and_utf16_share_one_tree() {
        let d = doc("# 😀 Heading\r\n\r\nA **bold** and *italic* [link](https://example.com).\r\n");
        assert_eq!(d.length, d.source.encode_utf16().count());
        assert!(d.blocks[0].html.contains("<h1>😀 Heading</h1>"));
        let strong = d.blocks[1]
            .spans
            .iter()
            .find(|s| s.kind == "StrongEmphasis")
            .unwrap();
        let units: Vec<_> = d.source.encode_utf16().collect();
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
        assert_eq!(d.blocks[0].kind, "Blockquote");
        assert!(d.blocks[0].html.contains("<ol>") && d.blocks[0].html.contains("<ul>"));
        assert_eq!(d.blocks[1].kind, "Table");
        assert!(
            d.blocks[2]
                .html
                .contains("astra-asset://image/?source=file%3A%2F%2F%2Ftmp%2Fimage.png")
        );
        assert!(!d.blocks[3].html.contains("href=\"javascript:"));
    }
    #[test]
    fn reference_edits_invalidate_remote_consumers() {
        let a = doc("A [reference][r].\n\nUnchanged.\n\n[r]: https://one.example\n");
        let b = prepare(
            "A [reference][r].\n\nUnchanged.\n\n[r]: https://two.example\n".into(),
            Some(&a),
            &[],
            None,
            std::ptr::null_mut(),
        )
        .unwrap();
        assert_ne!(a.blocks[0].id, b.blocks[0].id);
        assert_eq!(a.blocks[1].id, b.blocks[1].id);
        assert!(b.blocks[0].html.contains("https://two.example"));
    }
    #[test]
    fn duplicate_blocks_retain_ids_after_an_edit() {
        let source = "Identical **paragraph**.\n\n".repeat(100);
        let a = doc(&source);
        let at = a.blocks[50].from;
        let mut units: Vec<_> = source.encode_utf16().collect();
        units.splice(at..at + 9, "Changed".encode_utf16());
        let edit = Edit {
            from: at,
            to: at + 9,
            inserted: 7,
        };
        let b = prepare(
            String::from_utf16(&units).unwrap(),
            Some(&a),
            &[edit],
            None,
            std::ptr::null_mut(),
        )
        .unwrap();
        for i in 0..100 {
            if i == 50 {
                assert_ne!(a.blocks[i].id, b.blocks[i].id);
            } else {
                assert_eq!(a.blocks[i].id, b.blocks[i].id);
            }
        }
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
            let units: Vec<_> = d.source.encode_utf16().collect();
            let strong = d
                .blocks
                .iter()
                .flat_map(|b| &b.spans)
                .find(|s| s.kind == "StrongEmphasis")
                .unwrap();
            assert_eq!(
                String::from_utf16(&units[strong.from..strong.to]).unwrap(),
                "**bold**"
            );
            let link = d
                .blocks
                .iter()
                .flat_map(|b| &b.spans)
                .find(|s| s.kind == "Link")
                .unwrap();
            assert_eq!(
                String::from_utf16(&units[link.from..link.to]).unwrap(),
                "[reference][r]"
            );
        }
    }
}
