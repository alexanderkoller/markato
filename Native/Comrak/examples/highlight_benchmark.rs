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
fn main() {
    let samples = std::env::args()
        .nth(1)
        .map(|s| s.parse::<usize>().unwrap())
        .unwrap_or(101);
    assert!(samples > 0);
    println!("case,stage,input_bytes,samples,median_ms,p95_ms,max_ms");
    let cold = "```python\nmessage = \"Hello\"\nprint(message)\n```\n";
    let units: Vec<_> = cold.encode_utf16().collect();
    let start = Instant::now();
    records(&units);
    let ms = start.elapsed().as_secs_f64() * 1000.0;
    println!("first_python,cold,{},1,{ms:.6},{ms:.6},{ms:.6}", cold.len());
    for (name, source) in [
        (
            "languages",
            include_str!("../../../Tests/fixtures/highlighting/languages.md").to_owned(),
        ),
        (
            "extended",
            include_str!("../../../Tests/fixtures/highlighting/extended.md").to_owned(),
        ),
        (
            "stress_100",
            include_str!("../../../Tests/fixtures/highlighting/stress.md").to_owned(),
        ),
        (
            "python_100_lines",
            format!(
                "```python\n{}```\n",
                "value = \"Grüße\" # comment\n".repeat(100)
            ),
        ),
        (
            "python_1000_lines",
            format!(
                "```python\n{}```\n",
                "value = \"Grüße\" # comment\n".repeat(1000)
            ),
        ),
        (
            "over_line_limit",
            format!("```python\n{}```\n", "print(1)\n".repeat(5001)),
        ),
        ("prose_64k", "A plain Markdown paragraph.\n\n".repeat(2341)),
    ] {
        let units: Vec<_> = source.encode_utf16().collect();
        measure(name, "records", source.len(), samples, || records(&units));
        if name != "prose_64k" {
            let baseline = source
                .lines()
                .map(|line| {
                    if line.starts_with("```") && line.len() > 3 {
                        "```text"
                    } else {
                        line
                    }
                })
                .collect::<Vec<_>>()
                .join("\n");
            let units: Vec<_> = baseline.encode_utf16().collect();
            measure(name, "plain_baseline", baseline.len(), samples, || {
                records(&units)
            });
        }
    }
}
