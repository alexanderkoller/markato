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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Outcome {
    subtree: bool,
    guarded: bool,
}

struct Case {
    name: &'static str,
    before: &'static str,
    needle: &'static str,
    replacement: &'static str,
    expected: Outcome,
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
            markdown: document.source[block.bytes.clone()].to_owned(),
            html: block.html.clone(),
            spans: block.spans.clone(),
        })
        .collect()
}

fn shifted(mut block: BlockSnapshot, amount: isize) -> BlockSnapshot {
    block.from = block.from.saturating_add_signed(amount);
    block.to = block.to.saturating_add_signed(amount);
    for span in &mut block.spans {
        span.from = span.from.saturating_add_signed(amount);
        span.to = span.to.saturating_add_signed(amount);
    }
    block
}

/// Models the proposed implementation using the data Astra retains today:
/// choose the old top-level block whose owned interval contains the edit,
/// optionally include adjacent guard blocks, parse that corresponding source
/// slice as a new Comrak document, and splice its records into the old result.
fn regionally_reparsed(before: &str, after: &str, edit: Edit, guards: usize) -> Vec<BlockSnapshot> {
    let old = parsed(before);
    assert!(!old.blocks.is_empty());

    // PreparedDocument assigns whitespace between blocks to the following
    // block. Use the same ownership rule when an edit lies in a separator.
    let first_owner = old
        .blocks
        .partition_point(|block| block.to <= edit.from)
        .min(old.blocks.len() - 1);
    let edit_end_owner = old
        .blocks
        .partition_point(|block| block.to < edit.to)
        .min(old.blocks.len() - 1);
    let first = first_owner.saturating_sub(guards);
    let last = edit_end_owner
        .max(first_owner)
        .saturating_add(guards)
        .min(old.blocks.len() - 1);

    let old_from = if first == 0 {
        0
    } else {
        old.blocks[first - 1].to
    };
    let old_to = if last + 1 == old.blocks.len() {
        old.length
    } else {
        old.blocks[last].to
    };
    let delta = edit.inserted as isize - (edit.to - edit.from) as isize;
    let new_from = if old_from <= edit.from {
        old_from
    } else {
        old_from.saturating_add_signed(delta)
    };
    let new_to = if old_to < edit.to {
        old_to
    } else {
        old_to.saturating_add_signed(delta)
    };
    let fragment = parsed(source_slice(after, new_from, new_to));

    let mut result = snapshots(&old)[..first].to_vec();
    result.extend(
        snapshots(&fragment)
            .into_iter()
            .map(|block| shifted(block, new_from as isize)),
    );
    result.extend(
        snapshots(&old)[last + 1..]
            .iter()
            .cloned()
            .map(|block| shifted(block, delta)),
    );
    result
}

fn outcome(case: &Case) -> Outcome {
    let (after, edit) = edit(case);
    let complete = snapshots(&parsed(&after));
    Outcome {
        subtree: regionally_reparsed(case.before, &after, edit, 0) == complete,
        guarded: regionally_reparsed(case.before, &after, edit, 1) == complete,
    }
}

fn minimum_guards(case: &Case) -> usize {
    let (after, edit) = edit(case);
    let complete = snapshots(&parsed(&after));
    let block_count = parsed(case.before).blocks.len();
    (0..block_count)
        .find(|&guards| regionally_reparsed(case.before, &after, edit, guards) == complete)
        .expect("a region expanded over every block must equal a full parse")
}

#[test]
fn regional_reparse_characterization_matrix() {
    let yes = Outcome {
        subtree: true,
        guarded: true,
    };
    let no = Outcome {
        subtree: false,
        guarded: false,
    };
    let guarded = Outcome {
        subtree: false,
        guarded: true,
    };
    let cases = [
        Case {
            name: "paragraph text",
            before: "Before.\n\nA paragraph with local text.\n\nAfter.\n",
            needle: "local",
            replacement: "nearby",
            expected: yes,
        },
        Case {
            name: "unicode paragraph text",
            before: "Before.\n\nA 😀 paragraph in Zürich.\n\nAfter.\n",
            needle: "Zürich",
            replacement: "東京",
            expected: yes,
        },
        Case {
            name: "CRLF and supplementary Unicode",
            before: "Before.\r\n\r\nA 😀 local paragraph.\r\n\r\nAfter.\r\n",
            needle: "local",
            replacement: "nearby",
            expected: yes,
        },
        Case {
            name: "inline emphasis structure",
            before: "Before.\n\nText with ordinary words.\n\nAfter.\n",
            needle: "ordinary",
            replacement: "**strong**",
            expected: yes,
        },
        Case {
            name: "ATX heading level",
            before: "Before.\n\n## Heading\n\nAfter.\n",
            needle: "## Heading",
            replacement: "#### Heading",
            expected: yes,
        },
        Case {
            name: "paragraph split",
            before: "Before.\n\nAlpha middle omega.\n\nAfter.\n",
            needle: " middle ",
            replacement: "\n\nMiddle.\n\n",
            expected: yes,
        },
        Case {
            name: "paragraph merge across separator",
            before: "Before.\n\nAlpha.\n \nBeta.\n\nAfter.\n",
            needle: "\n \n",
            replacement: " ",
            expected: guarded,
        },
        Case {
            name: "list item inline edit",
            before: "Before.\n\n- one\n- two with text\n- three\n\nAfter.\n",
            needle: "with text",
            replacement: "with **formatting**",
            expected: yes,
        },
        Case {
            name: "nested list indentation",
            before: "Before.\n\n- one\n  - nested\n  - sibling\n- last\n\nAfter.\n",
            needle: "  - nested",
            replacement: "- promoted",
            expected: yes,
        },
        Case {
            name: "blockquote inline edit",
            before: "Before.\n\n> quoted one\n> quoted two\n\nAfter.\n",
            needle: "quoted two",
            replacement: "quoted **second**",
            expected: yes,
        },
        Case {
            name: "blockquote structure split",
            before: "Before.\n\n> quoted one\n> quoted two\n\nAfter.\n",
            needle: "> quoted two",
            replacement: "outside quote",
            expected: yes,
        },
        Case {
            name: "table cell edit",
            before: "Before.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nAfter.\n",
            needle: "| 1 | 2 |",
            replacement: "| one | two |",
            expected: yes,
        },
        Case {
            name: "table delimiter removed",
            before: "Before.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nAfter.\n",
            needle: "|---|---|",
            replacement: "not a delimiter",
            expected: yes,
        },
        Case {
            name: "fenced code body",
            before: "Before.\n\n```swift\nlet value = 1\n```\n\nAfter.\n",
            needle: "value = 1",
            replacement: "value = 2",
            expected: yes,
        },
        Case {
            name: "indented code body",
            before: "Before.\n\n    alpha\n    beta\n\nAfter.\n",
            needle: "alpha",
            replacement: "changed",
            expected: guarded,
        },
        Case {
            name: "closing fence removed",
            before: "Before.\n\n````swift\nlet value = 1\n````  \n\nAfter one.\n\nAfter two.\n",
            needle: "````  ",
            replacement: "not a fence",
            expected: no,
        },
        Case {
            name: "opening fence inserted",
            before: "Before.\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird paragraph.\n",
            needle: "First paragraph.",
            replacement: "```\nFirst paragraph.",
            expected: no,
        },
        Case {
            name: "display math body",
            before: "Before.\n\n$$\na=b\n$$\n\nAfter.\n",
            needle: "a=b",
            replacement: "a=b+c",
            expected: yes,
        },
        Case {
            name: "HTML block body",
            before: "Before.\n\n<div>\nold\n</div>\n\nAfter.\n",
            needle: "old",
            replacement: "new",
            expected: yes,
        },
        Case {
            name: "HTML raw block opener inserted",
            before: "Before.\n\nFirst.\n\nMiddle.\n\n</script>\n\nAfter.\n",
            needle: "First.",
            replacement: "<script>\nFirst.",
            expected: no,
        },
        Case {
            name: "thematic break becomes setext underline",
            before: "Title paragraph\n \n---\n\nAfter.\n",
            needle: "\n \n",
            replacement: "\n",
            expected: guarded,
        },
        Case {
            name: "reference destination changes remote consumer",
            before: "A [remote reference][r].\n\nMiddle.\n\n[r]: https://one.example\n",
            needle: "https://one.example",
            replacement: "https://two.example",
            expected: no,
        },
        Case {
            name: "plain block becomes remote reference definition",
            before: "A [remote reference][r].\n\nMiddle.\n\nDefinition placeholder.\n",
            needle: "Definition placeholder.",
            replacement: "[r]: https://example.com",
            expected: no,
        },
        Case {
            name: "reference consumer lacks fragment context",
            before: "[r]: https://example.com\n\nMiddle.\n\nA [remote reference][r].\n",
            needle: "remote reference",
            replacement: "renamed reference",
            expected: no,
        },
        Case {
            name: "inline link destination",
            before: "Before.\n\nA [link](https://one.example).\n\nAfter.\n",
            needle: "https://one.example",
            replacement: "https://two.example",
            expected: yes,
        },
    ];

    let mut mismatches = Vec::new();
    for case in &cases {
        let actual = outcome(case);
        if actual != case.expected {
            mismatches.push(format!(
                "{}: expected {:?}, observed {:?}",
                case.name, case.expected, actual
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "regional reparse characterization changed:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn regional_reparse_matrix_covers_success_expansion_and_fallback() {
    // Guard against accidentally narrowing the study to only convenient local
    // edits. These three examples establish each important outcome class.
    let local = Case {
        name: "local",
        before: "A.\n\nLocal text.\n\nZ.\n",
        needle: "Local",
        replacement: "Changed",
        expected: Outcome {
            subtree: true,
            guarded: true,
        },
    };
    let expansion = Case {
        name: "expansion",
        before: "A.\n\nLeft.\n \nRight.\n\nZ.\n",
        needle: "\n \n",
        replacement: " ",
        expected: Outcome {
            subtree: false,
            guarded: true,
        },
    };
    let fallback = Case {
        name: "fallback",
        before: "A [link][r].\n\nMiddle.\n\n[r]: /one\n",
        needle: "/one",
        replacement: "/two",
        expected: Outcome {
            subtree: false,
            guarded: false,
        },
    };
    assert_eq!(outcome(&local), local.expected);
    assert_eq!(outcome(&expansion), expansion.expected);
    assert_eq!(outcome(&fallback), fallback.expected);
}

#[test]
fn adaptive_expansion_can_converge_locally_or_degenerate_to_the_whole_document() {
    let cases = [
        (
            Case {
                name: "local paragraph",
                before: "A.\n\nLocal text.\n\nZ.\n",
                needle: "Local",
                replacement: "Changed",
                expected: Outcome {
                    subtree: true,
                    guarded: true,
                },
            },
            0,
        ),
        (
            Case {
                name: "separator deletion",
                before: "A.\n\nLeft.\n \nRight.\n\nZ.\n",
                needle: "\n \n",
                replacement: " ",
                expected: Outcome {
                    subtree: false,
                    guarded: true,
                },
            },
            1,
        ),
        (
            Case {
                name: "unclosed fence",
                before: "A.\n\n````text\nbody\n````  \n\nOne.\n\nTwo.\n",
                needle: "````  ",
                replacement: "not a fence",
                expected: Outcome {
                    subtree: false,
                    guarded: false,
                },
            },
            2,
        ),
        (
            Case {
                name: "distant reference dependency",
                before: "A [link][r].\n\nM1.\n\nM2.\n\nM3.\n\nM4.\n\nM5.\n\n[r]: /one\n",
                needle: "/one",
                replacement: "/two",
                expected: Outcome {
                    subtree: false,
                    guarded: false,
                },
            },
            6,
        ),
    ];

    for (case, expected) in &cases {
        assert_eq!(
            minimum_guards(case),
            *expected,
            "{} expansion distance changed",
            case.name
        );
    }
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
fn production_regional_update_matches_full_parse_for_representative_local_edits() {
    let yes = Outcome {
        subtree: true,
        guarded: true,
    };
    for case in [
        Case {
            name: "heading benchmark edit",
            before: "# Heading\n\nMiddle.\n\nAfter.\n",
            needle: "Heading",
            replacement: "Changed heading",
            expected: yes,
        },
        Case {
            name: "Unicode paragraph",
            before: "Before.\n\nA 😀 paragraph.\n\nAfter.\n",
            needle: "paragraph",
            replacement: "段落",
            expected: yes,
        },
        Case {
            name: "nested list",
            before: "Before.\n\n- one\n  - two\n  - three\n\nAfter.\n",
            needle: "two",
            replacement: "**second**",
            expected: yes,
        },
        Case {
            name: "table",
            before: "Before.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nAfter.\n",
            needle: "| 1 | 2 |",
            replacement: "| one | two |",
            expected: yes,
        },
        Case {
            name: "indented code with lookahead",
            before: "Before.\n\n    alpha\n    beta\n\nAfter.\n",
            needle: "alpha",
            replacement: "changed",
            expected: Outcome {
                subtree: false,
                guarded: true,
            },
        },
    ] {
        let (updated, actual, expected) = run_production_candidate(&case);
        assert!(updated, "{} unexpectedly requested a full parse", case.name);
        assert_eq!(actual, expected, "{} diverged from a full parse", case.name);
    }
}

#[test]
fn production_region_rejects_propagating_and_global_edits_without_mutation() {
    let fence = Case {
        name: "unclosed fence",
        before: "Before.\n\n````text\nbody\n````  \n\nOne.\n\nTwo.\n",
        needle: "````  ",
        replacement: "not a fence",
        expected: Outcome {
            subtree: false,
            guarded: false,
        },
    };
    let original = snapshots(&parsed(fence.before));
    let (updated, actual, _) = run_production_candidate(&fence);
    assert!(!updated);
    assert_eq!(
        actual, original,
        "a rejected candidate must be transactional"
    );

    let reference = Case {
        name: "reference definition",
        before: "A [link][r].\n\nMiddle.\n\n[r]: /one\n",
        needle: "/one",
        replacement: "/two",
        expected: Outcome {
            subtree: false,
            guarded: false,
        },
    };
    let (_, edit) = edit(&reference);
    assert!(edit_region(&parsed(reference.before), &[edit]).is_none());
}
