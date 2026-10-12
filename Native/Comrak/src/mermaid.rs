//! Browserless Mermaid rendering. SVG images isolate marker IDs and cannot
//! introduce active document markup into the preview's DOM.
use rusty_mermaid::{Theme, svg::SvgRenderer};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub(crate) const MAX_BYTES: usize = 64 * 1024;
pub(crate) const MAX_LINES: usize = 1000;

pub(crate) fn image(source: &str) -> Result<String, &'static str> {
    if source.len() > MAX_BYTES || source.lines().count() > MAX_LINES {
        return Err("Diagram exceeds the 64 KiB or 1,000 line rendering limit");
    }
    // Keep errors (including upstream panics) local to this fence. The outer
    // ABI panic guard would otherwise discard the entire Markdown document.
    catch_unwind(AssertUnwindSafe(|| {
        let theme = Theme::default();
        let scene = rusty_mermaid::render(source, &theme)
            .map_err(|_| "Diagram syntax is invalid or unsupported")?;
        let width = scene.width + theme.padding * 2.0;
        let height = scene.height + theme.padding * 2.0;
        if scene.is_empty() || !width.is_finite() || !height.is_finite()
            || width <= 0.0 || height <= 0.0
        {
            return Err("Diagram is empty or has invalid dimensions");
        }
        let svg = SvgRenderer::with_theme(&theme).render_themed(&scene, &theme);
        let mut html = format!(
            "<div class=\"mermaid-diagram\"><img alt=\"Mermaid diagram\" width=\"{width}\" height=\"{height}\" src=\"data:image/svg+xml,"
        );
        const HEX: &[u8; 16] = b"0123456789ABCDEF";
        for byte in svg.bytes() {
            if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
                html.push(byte as char);
            } else {
                html.push('%');
                html.push(HEX[(byte >> 4) as usize] as char);
                html.push(HEX[(byte & 15) as usize] as char);
            }
        }
        html.push_str("\" /></div>\n");
        Ok(html)
    }))
    .unwrap_or(Err("Diagram could not be rendered"))
}
