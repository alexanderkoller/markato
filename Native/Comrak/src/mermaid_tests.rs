use super::*;

const FAMILIES: &str = include_str!("../../../Tests/fixtures/mermaid/families.md");
const LAYOUT: &str = include_str!("../../../Tests/fixtures/mermaid/layout.md");
const ERRORS: &str = include_str!("../../../Tests/fixtures/mermaid/errors.md");
const STRESS: &str = include_str!("../../../Tests/fixtures/mermaid/stress.md");

fn doc(source: &str) -> ParsedDocument {
    parse_source(source.into(), None, std::ptr::null_mut()).unwrap()
}
fn html(doc: &ParsedDocument) -> String {
    doc.blocks.iter().map(|b| b.html.as_str()).collect()
}
fn decode_svg(html: &str) -> String {
    let data = html
        .split("data:image/svg+xml,")
        .nth(1)
        .unwrap()
        .split('"')
        .next()
        .unwrap();
    let mut bytes = Vec::new();
    let mut index = 0;
    while index < data.len() {
        if data.as_bytes()[index] == b'%' {
            bytes.push(u8::from_str_radix(&data[index + 1..index + 3], 16).unwrap());
            index += 3;
        } else {
            bytes.push(data.as_bytes()[index]);
            index += 1;
        }
    }
    String::from_utf8(bytes).unwrap()
}

#[test]
fn representative_families_render_complete_svg_images() {
    let document = doc(FAMILIES);
    let diagrams: Vec<_> = document
        .blocks
        .iter()
        .filter(|b| b.kind == kind::FENCED_CODE)
        .collect();
    assert_eq!(diagrams.len(), 14);
    for block in diagrams {
        let source =
            String::from_utf16(&FAMILIES.encode_utf16().collect::<Vec<_>>()[block.from..block.to])
                .unwrap();
        assert!(
            block.html.contains("class=\"mermaid-diagram\""),
            "{source}: {}",
            block.html
        );
        let svg = decode_svg(&block.html);
        assert!(svg.starts_with("<svg xmlns="));
        assert!(svg.contains("viewBox="));
        assert!(svg.trim_end().ends_with("</svg>"));
        assert!(svg.contains("<text"), "Diagram must have labels: {source}");
    }
}

#[test]
fn nested_fences_and_other_markdown_keep_their_context() {
    let document = doc(LAYOUT);
    let output = html(&document);
    assert_eq!(output.matches("class=\"mermaid-diagram\"").count(), 8);
    assert!(!output.contains("mermaid-error"));
    assert!(output.contains("<blockquote>") && output.contains("<ol>"));
    assert!(output.contains("language-swift") && output.contains("language-mermaid-example"));
    assert!(output.contains("<strong>bold</strong>") && output.contains("<table>"));
    assert!(output.contains("End of layout fixture"));
}

#[test]
fn failures_stay_local_and_source_is_escaped() {
    let output = html(&doc(ERRORS));
    assert_eq!(output.matches("class=\"mermaid-error\"").count(), 5);
    assert_eq!(output.matches("class=\"mermaid-diagram\"").count(), 1);
    assert!(output.contains("&lt;script&gt;"));
    assert!(!output.contains("<script>") && !output.contains("<img src=\"https:"));
    assert!(output.contains("<strong>End of error fixture.</strong>"));
}

#[test]
fn images_isolate_marker_ids_and_escape_unicode_labels() {
    let output = html(&doc(
        "```mermaid\nflowchart LR\n A[\"Grüße 😀 & <script>\"] --> B[Done]\n```\n\n```mermaid\nflowchart LR\n A --> B\n```\n",
    ));
    assert_eq!(output.matches("data:image/svg+xml,").count(), 2);
    assert!(!output.contains("<svg") && !output.contains("<script>"));
    let svg = decode_svg(&output);
    assert!(svg.contains("Grüße 😀 &amp; "), "{svg}");
    assert!(!svg.contains("<script>"));
    assert!(svg.contains("marker-end="));
}

#[test]
fn mermaid_keeps_fence_kind_and_utf16_source_coverage() {
    let source = "😀 before\r\n\r\n~~~mermaid extra\r\ngraph TD\r\n A[😀] --> B[Done]\r\n~~~\r\n\r\nAfter.\r\n";
    let document = doc(source);
    assert_eq!(document.length, source.encode_utf16().count());
    let block = document
        .blocks
        .iter()
        .find(|b| b.html.contains("mermaid-diagram"))
        .unwrap();
    assert_eq!(block.kind, kind::FENCED_CODE);
    let units: Vec<_> = source.encode_utf16().collect();
    let range = String::from_utf16(&units[block.from..block.to]).unwrap();
    assert!(range.starts_with("~~~mermaid") && range.contains("A[😀]"));
    assert!(block.spans.iter().any(|s| s.kind == kind::CODE_MARK));
    assert!(
        block
            .spans
            .iter()
            .all(|s| s.from >= block.from && s.to <= block.to)
    );
}

#[test]
fn input_limits_have_local_fallbacks() {
    for source in [
        format!("graph TD\n A[{}] --> B", "x".repeat(mermaid::MAX_BYTES)),
        format!("graph TD\n{}", "%% comment\n".repeat(mermaid::MAX_LINES)),
    ] {
        let output = html(&doc(&format!(
            "```mermaid\n{source}\n```\n\nAfter **limit**.\n"
        )));
        assert!(output.contains("rendering limit"));
        assert!(output.contains("After <strong>limit</strong>"));
    }
}

#[test]
fn many_diagrams_have_complete_ordered_source_coverage() {
    let document = doc(STRESS);
    assert_eq!(
        html(&document).matches("class=\"mermaid-diagram\"").count(),
        100
    );
    assert!(!html(&document).contains("mermaid-error"));
    for pair in document.blocks.windows(2) {
        assert!(pair[0].to <= pair[1].from);
    }
    let end = document.blocks.last().unwrap().to;
    assert!(
        String::from_utf16(&STRESS.encode_utf16().collect::<Vec<_>>()[end..])
            .unwrap()
            .trim()
            .is_empty()
    );
}

#[test]
fn only_exact_mermaid_fence_language_is_interpreted() {
    for language in ["Mermaid", "mermaid-example", "text", ""] {
        let output = html(&doc(&format!("```{language}\ngraph TD\n A --> B\n```\n")));
        assert!(output.contains("<pre") && output.contains("<code"));
        assert!(!output.contains("mermaid-diagram"));
    }
    assert!(html(&doc("```mermaid\ngraph TD\n A --> B\n")).contains("mermaid-diagram"));
}
