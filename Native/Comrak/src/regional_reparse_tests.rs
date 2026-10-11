use super::*;

#[derive(Clone, Debug, PartialEq, Eq)]
struct BlockSnapshot {
    kind: String,
    from: usize,
    to: usize,
    markdown: String,
    html: String,
    spans: Vec<Span>,
}

struct Case {
    name: &'static str,
    before: &'static str,
    needle: &'static str,
    replacement: &'static str,
}

fn parsed(source: &str) -> Document {
    prepare(source.into(), None, &[], None, std::ptr::null_mut()).unwrap()
}

fn utf16_len(source: &str) -> usize {
    source.encode_utf16().count()
}

fn byte_offset(source: &str, utf16: usize) -> usize {
    let mut units = 0;
    for (byte, ch) in source.char_indices() {
        if units == utf16 {
            return byte;
        }
        units += ch.len_utf16();
        assert!(units <= utf16, "offset splits a surrogate pair");
    }
    assert_eq!(units, utf16, "UTF-16 offset is outside the source");
    source.len()
}

fn source_slice(source: &str, from: usize, to: usize) -> &str {
    &source[byte_offset(source, from)..byte_offset(source, to)]
}

fn edit(case: &Case) -> (String, Edit) {
    let byte = case
        .before
        .find(case.needle)
        .unwrap_or_else(|| panic!("{}: edit needle is missing", case.name));
    assert_eq!(
        case.before[byte + case.needle.len()..].find(case.needle),
        None,
        "{}: edit needle must be unique",
        case.name
    );
    let from = utf16_len(&case.before[..byte]);
    let to = from + utf16_len(case.needle);
    let mut after = case.before.to_owned();
    after.replace_range(byte..byte + case.needle.len(), case.replacement);
    (
        after,
        Edit {
            from,
            to,
            inserted: utf16_len(case.replacement),
        },
    )
}

fn snapshots(document: &Document) -> Vec<BlockSnapshot> {
    document
        .blocks
        .iter()
        .map(|block| BlockSnapshot {
            kind: block.kind.clone(),
            from: block.from,
            to: block.to,
            markdown: block.markdown.clone(),
            html: block.html.clone(),
            spans: block.spans.clone(),
        })
        .collect()
}

fn run_production_candidate(case: &Case) -> (bool, Vec<BlockSnapshot>, Vec<BlockSnapshot>) {
    let (after, edit) = edit(case);
    let mut document = parsed(case.before);
    let expected = snapshots(&parsed(&after));
    let Some(region) = edit_region(&document, &[edit]) else {
        return (false, snapshots(&document), expected);
    };
    let updated = update_region(
        &mut document,
        source_slice(&after, region.new_from, region.new_to).to_owned(),
        region.new_from,
        utf16_len(&after),
        &[edit],
        None,
        std::ptr::null_mut(),
    )
    .unwrap();
    (updated, snapshots(&document), expected)
}

#[test]
fn production_regional_update_matches_full_parse_or_falls_back_transactionally() {
    let cases = [
        Case {
            name: "paragraph text",
            before: "Before.\n\nA paragraph with local text.\n\nAfter.\n",
            needle: "local",
            replacement: "nearby",
        },
        Case {
            name: "unicode paragraph text",
            before: "Before.\n\nA 😀 paragraph in Zürich.\n\nAfter.\n",
            needle: "Zürich",
            replacement: "東京",
        },
        Case {
            name: "CRLF and supplementary Unicode",
            before: "Before.\r\n\r\nA 😀 local paragraph.\r\n\r\nAfter.\r\n",
            needle: "local",
            replacement: "nearby",
        },
        Case {
            name: "inline emphasis structure",
            before: "Before.\n\nText with ordinary words.\n\nAfter.\n",
            needle: "ordinary",
            replacement: "**strong**",
        },
        Case {
            name: "ATX heading level",
            before: "Before.\n\n## Heading\n\nAfter.\n",
            needle: "## Heading",
            replacement: "#### Heading",
        },
        Case {
            name: "paragraph split",
            before: "Before.\n\nAlpha middle omega.\n\nAfter.\n",
            needle: " middle ",
            replacement: "\n\nMiddle.\n\n",
        },
        Case {
            name: "paragraph merge across separator",
            before: "Before.\n\nAlpha.\n \nBeta.\n\nAfter.\n",
            needle: "\n \n",
            replacement: " ",
        },
        Case {
            name: "list item inline edit",
            before: "Before.\n\n- one\n- two with text\n- three\n\nAfter.\n",
            needle: "with text",
            replacement: "with **formatting**",
        },
        Case {
            name: "nested list indentation",
            before: "Before.\n\n- one\n  - nested\n  - sibling\n- last\n\nAfter.\n",
            needle: "  - nested",
            replacement: "- promoted",
        },
        Case {
            name: "blockquote inline edit",
            before: "Before.\n\n> quoted one\n> quoted two\n\nAfter.\n",
            needle: "quoted two",
            replacement: "quoted **second**",
        },
        Case {
            name: "blockquote structure split",
            before: "Before.\n\n> quoted one\n> quoted two\n\nAfter.\n",
            needle: "> quoted two",
            replacement: "outside quote",
        },
        Case {
            name: "table cell edit",
            before: "Before.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nAfter.\n",
            needle: "| 1 | 2 |",
            replacement: "| one | two |",
        },
        Case {
            name: "table delimiter removed",
            before: "Before.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nAfter.\n",
            needle: "|---|---|",
            replacement: "not a delimiter",
        },
        Case {
            name: "fenced code body",
            before: "Before.\n\n```swift\nlet value = 1\n```\n\nAfter.\n",
            needle: "value = 1",
            replacement: "value = 2",
        },
        Case {
            name: "indented code body",
            before: "Before.\n\n    alpha\n    beta\n\nAfter.\n",
            needle: "alpha",
            replacement: "changed",
        },
        Case {
            name: "closing fence removed",
            before: "Before.\n\n````swift\nlet value = 1\n````  \n\nAfter one.\n\nAfter two.\n",
            needle: "````  ",
            replacement: "not a fence",
        },
        Case {
            name: "opening fence inserted",
            before: "Before.\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird paragraph.\n",
            needle: "First paragraph.",
            replacement: "```\nFirst paragraph.",
        },
        Case {
            name: "display math body",
            before: "Before.\n\n$$\na=b\n$$\n\nAfter.\n",
            needle: "a=b",
            replacement: "a=b+c",
        },
        Case {
            name: "HTML block body",
            before: "Before.\n\n<div>\nold\n</div>\n\nAfter.\n",
            needle: "old",
            replacement: "new",
        },
        Case {
            name: "HTML raw block opener inserted",
            before: "Before.\n\nFirst.\n\nMiddle.\n\n</script>\n\nAfter.\n",
            needle: "First.",
            replacement: "<script>\nFirst.",
        },
        Case {
            name: "thematic break becomes setext underline",
            before: "Title paragraph\n \n---\n\nAfter.\n",
            needle: "\n \n",
            replacement: "\n",
        },
        Case {
            name: "reference destination changes remote consumer",
            before: "A [remote reference][r].\n\nMiddle.\n\n[r]: https://one.example\n",
            needle: "https://one.example",
            replacement: "https://two.example",
        },
        Case {
            name: "plain block becomes remote reference definition",
            before: "A [remote reference][r].\n\nMiddle.\n\nDefinition placeholder.\n",
            needle: "Definition placeholder.",
            replacement: "[r]: https://example.com",
        },
        Case {
            name: "reference consumer lacks fragment context",
            before: "[r]: https://example.com\n\nMiddle.\n\nA [remote reference][r].\n",
            needle: "remote reference",
            replacement: "renamed reference",
        },
        Case {
            name: "inline link destination",
            before: "Before.\n\nA [link](https://one.example).\n\nAfter.\n",
            needle: "https://one.example",
            replacement: "https://two.example",
        },
    ];

    for case in &cases {
        let original = snapshots(&parsed(case.before));
        let (updated, actual, expected) = run_production_candidate(case);
        if updated {
            assert_eq!(actual, expected, "{} diverged from a full parse", case.name);
        } else {
            assert_eq!(
                actual, original,
                "{} changed state before fallback",
                case.name
            );
        }
    }
}

#[test]
fn production_regional_update_respects_insertion_boundary_affinity() {
    let before = "# One\n\nTwo.\n";
    for (name, at, inserted, after) in [
        ("BOF", 0, "Intro.\n\n", "Intro.\n\n# One\n\nTwo.\n"),
        (
            "block boundary",
            utf16_len("# One\n\n"),
            "Middle.\n\n",
            "# One\n\nMiddle.\n\nTwo.\n",
        ),
        (
            "EOF",
            utf16_len(before),
            "\nThree.\n",
            "# One\n\nTwo.\n\nThree.\n",
        ),
    ] {
        let edit = Edit {
            from: at,
            to: at,
            inserted: utf16_len(inserted),
        };
        let mut document = parsed(before);
        let region = edit_region(&document, &[edit])
            .unwrap_or_else(|| panic!("{name} insertion should be regional"));

        assert!(
            update_region(
                &mut document,
                source_slice(after, region.new_from, region.new_to).to_owned(),
                region.new_from,
                utf16_len(after),
                &[edit],
                None,
                std::ptr::null_mut(),
            )
            .unwrap()
        );
        assert_eq!(snapshots(&document), snapshots(&parsed(after)), "{name}");
    }
}
