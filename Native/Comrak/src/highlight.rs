//! Shared immutable grammars, per-fence parsing state, and escaped fallbacks.
use comrak::{adapters::SyntaxHighlighterAdapter, html};
use std::{
    borrow::Cow,
    collections::HashMap,
    fmt,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::OnceLock,
};
use syntect::{
    html::{ClassStyle, ClassedHTMLGenerator},
    parsing::SyntaxSet,
    util::LinesWithEndings,
};

pub(crate) const MAX_BYTES: usize = 256 * 1024;
pub(crate) const MAX_LINES: usize = 5000;
pub(crate) struct Highlighter;
pub(crate) static HIGHLIGHTER: Highlighter = Highlighter;
static SYNTAXES: OnceLock<SyntaxSet> = OnceLock::new();

fn highlighted(language: &str, code: &str) -> Option<String> {
    if language.is_empty()
        || matches!(language, "text" | "txt" | "plain" | "plaintext")
        || code.len() > MAX_BYTES
        || code.lines().count() > MAX_LINES
    {
        return None;
    }
    let syntaxes = SYNTAXES.get_or_init(two_face::syntax::extra_newlines);
    let syntax = syntaxes.find_syntax_by_token(language)?;
    if std::ptr::eq(syntax, syntaxes.find_syntax_plain_text()) {
        return None;
    }
    let mut generator = ClassedHTMLGenerator::new_with_class_style(
        syntax,
        syntaxes,
        ClassStyle::SpacedPrefixed { prefix: "syntax-" },
    );
    for line in LinesWithEndings::from(code) {
        generator
            .parse_html_for_line_which_includes_newline(line)
            .ok()?;
    }
    Some(generator.finalize())
}

impl SyntaxHighlighterAdapter for Highlighter {
    fn write_highlighted(
        &self,
        output: &mut dyn fmt::Write,
        language: Option<&str>,
        code: &str,
    ) -> fmt::Result {
        // Never publish partially highlighted or unescaped output on failure.
        match catch_unwind(AssertUnwindSafe(|| {
            highlighted(language.unwrap_or(""), code)
        })) {
            Ok(Some(highlighted)) => output.write_str(&highlighted),
            _ => html::escape(output, code),
        }
    }
    fn write_pre_tag(
        &self,
        output: &mut dyn fmt::Write,
        attributes: HashMap<&'static str, Cow<'_, str>>,
    ) -> fmt::Result {
        opening(output, "pre", attributes)
    }
    fn write_code_tag(
        &self,
        output: &mut dyn fmt::Write,
        attributes: HashMap<&'static str, Cow<'_, str>>,
    ) -> fmt::Result {
        opening(output, "code", attributes)
    }
}
fn opening(
    output: &mut dyn fmt::Write,
    tag: &str,
    mut attributes: HashMap<&'static str, Cow<'_, str>>,
) -> fmt::Result {
    let classes = attributes.remove("class").unwrap_or_default();
    attributes.insert(
        "class",
        format!("syntax-code {classes}")
            .trim_end()
            .to_owned()
            .into(),
    );
    // Deterministic HTML is necessary for regional guard equality and reuse.
    let mut attributes: Vec<_> = attributes.into_iter().collect();
    attributes.sort_by_key(|(key, _)| *key);
    html::write_opening_tag(output, tag, attributes)
}
