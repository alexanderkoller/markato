use super::*;
use comrak::adapters::SyntaxHighlighterAdapter;

fn doc(source: &str) -> ParsedDocument {
    parse_source(source.into(), None, std::ptr::null_mut()).unwrap()
}
fn html(source: &str) -> String {
    doc(source).blocks.into_iter().map(|b| b.html).collect()
}
fn highlighted(language: &str, source: &str) -> String {
    let mut output = String::new();
    highlight::HIGHLIGHTER
        .write_highlighted(&mut output, Some(language), source)
        .unwrap();
    output
}

#[test]
fn bundled_languages_produce_token_spans() {
    let source = include_str!("../../../Tests/fixtures/highlighting/languages.md");
    let document = doc(source);
    let blocks: Vec<_> = document
        .blocks
        .iter()
        .filter(|b| b.kind == kind::FENCED_CODE)
        .collect();
    assert_eq!(blocks.len(), 12);
    for block in blocks {
        assert!(
            block.html.contains("<span class=\"syntax-"),
            "{}",
            block.html
        );
        assert!(block.html.contains("language-"));
        assert!(!block.html.contains("style=\""));
    }
}

#[test]
fn highlighting_preserves_multiline_state_but_never_shares_fence_state() {
    let source = "value = \"\"\"first\nsecond 😀\nthird\"\"\"\nprint(value)\n";
    let output = highlighted("python", source);
    let second = output.split("second 😀").next().unwrap();
    assert!(second.rfind("syntax-string").is_some());
    let fresh = highlighted("python", "print(42)\n");
    let _ = highlighted("python", "value = \"\"\"unclosed\n");
    assert_eq!(fresh, highlighted("python", "print(42)\n"));
}

#[test]
fn unknown_missing_and_plain_languages_stay_escaped_text() {
    let source = "<script>\"Hello 😀\" & goodbye</script>\n";
    let mut escaped = String::new();
    html::escape(&mut escaped, source).unwrap();
    for language in ["unknown-language", "", "text", "txt", "plain", "plaintext"] {
        assert_eq!(highlighted(language, source), escaped);
    }
    assert!(!highlighted("", "#!/bin/bash\necho hi").contains("<span"));
}

#[test]
fn markup_in_known_languages_is_never_executable_html() {
    let output = highlighted(
        "html",
        "<script>alert('x')</script>\n<img src=\"https://example.invalid\" onerror=\"alert(1)\">\n",
    );
    assert!(!output.contains("<script>") && !output.contains("<img"));
    assert!(output.contains("&lt;") && output.contains("&gt;"));
}

#[test]
fn nested_fences_and_dedicated_renderers_coexist() {
    let output = html(include_str!(
        "../../../Tests/fixtures/highlighting/edge-cases.md"
    ));
    assert!(output.contains("<blockquote>") && output.contains("<ol>"));
    assert!(output.contains("language-js"));
    assert!(output.contains("mermaid-diagram") && output.contains("data:image/svg+xml,"));
    assert!(!output.contains("language-mermaid\""));
    assert!(!output.contains("<script>") && !output.contains("<img src=\"https:"));
    assert!(output.contains("End of edge case fixture"));
}

#[test]
fn oversized_fences_keep_complete_escaped_source() {
    for source in [
        "<x>".repeat(highlight::MAX_BYTES / 3 + 1),
        "x = 1\n".repeat(highlight::MAX_LINES + 1),
    ] {
        let mut escaped = String::new();
        html::escape(&mut escaped, &source).unwrap();
        assert_eq!(highlighted("python", &source), escaped);
    }
}

#[test]
fn crlf_unicode_and_aliases_keep_original_source_ranges() {
    let source = "😀\r\n\r\n~~~py extra\r\nx = \"Grüße 😀\"\r\n~~~\r\n";
    let document = doc(source);
    let block = document
        .blocks
        .iter()
        .find(|b| b.kind == kind::FENCED_CODE)
        .unwrap();
    assert!(block.html.contains("syntax-string") && block.html.contains("Grüße 😀"));
    assert!(block.html.contains("language-py"));
    let units: Vec<_> = source.encode_utf16().collect();
    assert!(
        String::from_utf16(&units[block.from..block.to])
            .unwrap()
            .starts_with("~~~py")
    );
    assert!(block.spans.iter().any(|s| s.kind == kind::CODE_MARK));
}

#[test]
fn many_fences_and_repeated_parses_have_deterministic_output() {
    let source = include_str!("../../../Tests/fixtures/highlighting/stress.md");
    let first = html(source);
    assert_eq!(
        first
            .matches("<code class=\"syntax-code language-python\"")
            .count(),
        100
    );
    assert_eq!(first, html(source));
}

#[test]
fn extended_grammars_and_aliases_produce_language_tokens() {
    let source = include_str!("../../../Tests/fixtures/highlighting/extended.md");
    let document = doc(source);
    let fences: Vec<_> = document
        .blocks
        .iter()
        .filter(|b| b.kind == kind::FENCED_CODE)
        .collect();
    assert_eq!(fences.len(), 8);
    for block in fences {
        assert!(
            block.html.contains("<span class=\"syntax-"),
            "{}",
            block.html
        );
        assert!(!block.html.contains("<div className="));
    }
    for (language, code) in [
        ("swift", "let name: String = \"hello\"\n"),
        ("ts", "const name: string = \"hello\";\n"),
        ("tsx", "const view = <div>Hello</div>;\n"),
        ("kt", "val name: String = \"hello\"\n"),
        ("dart", "final String name = 'hello';\n"),
        ("toml", "[section]\nname = \"hello\"\n"),
        ("dockerfile", "FROM rust:1.96\n"),
        ("typst", "#let name = \"hello\"\n#name\n"),
        ("typ", "#let name = \"hello\"\n#name\n"),
    ] {
        assert!(
            highlighted(language, code).contains("syntax-"),
            "Missing grammar for {language}"
        );
    }
}
