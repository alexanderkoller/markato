//! Reproducible release benchmark; no process launch inside timed samples.
use astra_comrak::{astra_comrak_parse_records, astra_comrak_result_free};
use std::{
    hint::black_box,
    time::{Duration, Instant},
};

fn records(source: &[u16]) {
    // The adapter copies/decodes UTF-16, parses Markdown, renders diagrams,
    // encodes SVG image URLs, allocates records, and frees the result.
    let result = unsafe {
        astra_comrak_parse_records(
            source.as_ptr(),
            source.len(),
            0,
            1,
            None,
            std::ptr::null_mut(),
        )
    };
    assert!(!result.is_null());
    black_box(result);
    unsafe { astra_comrak_result_free(result) };
}
fn measure(name: &str, stage: &str, bytes: usize, samples: usize, mut run: impl FnMut()) {
    let warmup = Instant::now();
    while warmup.elapsed() < Duration::from_millis(200) {
        run();
    }
    let mut times = Vec::with_capacity(samples);
    for _ in 0..samples {
        let start = Instant::now();
        run();
        times.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    times.sort_by(f64::total_cmp);
    println!(
        "{name},{stage},{bytes},{samples},{:.6},{:.6},{:.6}",
        times[samples / 2],
        times[(samples * 95 / 100).min(samples - 1)],
        times[samples - 1]
    );
}
fn diagram(name: &str, source: &str, samples: usize) {
    measure(name, "svg", source.len(), samples, || {
        black_box(rusty_mermaid::to_svg(source, &rusty_mermaid::Theme::default()).unwrap());
    });
    let markdown = format!("```mermaid\n{source}\n```\n");
    let units: Vec<_> = markdown.encode_utf16().collect();
    measure(name, "records", markdown.len(), samples, || records(&units));
    let baseline = markdown.replacen("```mermaid", "```text", 1);
    let units: Vec<_> = baseline.encode_utf16().collect();
    measure(name, "code_baseline", baseline.len(), samples, || {
        records(&units)
    });
}
fn main() {
    let samples = std::env::args()
        .nth(1)
        .map(|s| s.parse::<usize>().unwrap())
        .unwrap_or(101);
    assert!(samples > 0);
    println!("case,stage,input_bytes,samples,median_ms,p95_ms,max_ms");
    for nodes in [10, 50, 200] {
        let mut source = String::from("flowchart LR\n");
        for i in 0..nodes - 1 {
            source.push_str(&format!(" N{i}[Node {i}] --> N{}[Node {}]\n", i + 1, i + 1));
        }
        diagram(&format!("flowchart_{nodes}"), &source, samples);
    }
    diagram(
        "sequence",
        "sequenceDiagram\n Alice->>Bob: Hello\n Bob-->>Alice: Ready",
        samples,
    );
    for (name, source) in [
        (
            "families",
            include_str!("../../../Tests/fixtures/mermaid/families.md").to_owned(),
        ),
        (
            "stress_100",
            include_str!("../../../Tests/fixtures/mermaid/stress.md").to_owned(),
        ),
        (
            "errors",
            include_str!("../../../Tests/fixtures/mermaid/errors.md").to_owned(),
        ),
        ("prose_64k", "A plain Markdown paragraph.\n\n".repeat(2341)),
        ("prose_1m", "A plain Markdown paragraph.\n\n".repeat(37449)),
    ] {
        let units: Vec<_> = source.encode_utf16().collect();
        measure(name, "records", source.len(), samples, || records(&units));
        if name == "families" || name == "stress_100" {
            let baseline = source.replace("```mermaid", "```text");
            let units: Vec<_> = baseline.encode_utf16().collect();
            measure(name, "code_baseline", baseline.len(), samples, || {
                records(&units)
            });
        }
    }
}
