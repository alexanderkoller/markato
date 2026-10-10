Vendored Comrak 0.55.0 from crates.io. Upstream MIT license is in COPYING.

The only source change is in src/parser/mod.rs: when reference definitions
are removed from paragraph content (including a subsequent setext heading),
advance sourcepos.start and discard the corresponding line_offsets before
inline parsing. Upstream retained the original definition coordinates, which
placed inline editor styling on the definition rather than on the paragraph.
Native/Comrak tests cover direct, multiline and container cases. This patch
does not perform a second parse or change Markdown rendering semantics.
