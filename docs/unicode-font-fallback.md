# Unicode font fallback

## Current implementation

Applications register fonts through Alicorn's Runtime-owned font-file and face
registry. `font_file_load_bytes` copies and deduplicates SFNT/TTC bytes;
`font_face_load` retains a stable `Font_Face_ID` and a stable-address Runa face
for the Runtime lifetime. Each text role can hold an ordered list of these
faces. Registry storage is bounded to 64 MiB, 64 unique files, and 32 faces per
Runtime.

Runa chooses a single face for each extended grapheme cluster. A candidate must
have cmap entries for each non-ignorable scalar in that cluster; combining
sequences, variation selectors, modifiers, keycaps, flags, and ZWJ text are not
split across faces. Adjacent clusters with compatible face, script, and style
are shaped together, so contextual shaping such as Arabic joining is retained.
This is cmap coverage, not proof that the font has a color-glyph substitution
for every emoji sequence. When no candidate covers a cluster, the primary face
shapes it as one unit and the retained text run records unresolved coverage.

Adding a fallback face advances that font role's separate fallback generation.
Only retained runs for that role that previously had unresolved coverage are
reshaped; Latin-only runs and unresolved text in the other role do not acquire
a new fallback dependency. Normal font replacement still uses the existing
full font generation.

On Windows, native startup uses DirectWrite `IDWriteFontFallback::MapCharacters`
to resolve a bounded set of locale-aware CJK, Arabic, and emoji samples. The
mapped local SFNT/TTC faces are copied into the Runtime and made available to
both UI and monospace roles. This deliberately avoids font discovery and file
I/O during typing, scrolling, and IME composition. It accepts only DirectWrite
local-file loaders; remote/cloud-backed mappings are skipped so copying a face
cannot trigger a synchronous font download. Mappings whose DirectWrite em
scale is not 1 are also skipped because the current face-stack API does not yet
carry per-face scaling. The provider is a startup-seeded fallback stack, not a
general asynchronous resolver for arbitrary later scripts or document
languages.

The seeding lives in `alicorn:host/fonts`; `load_default_fonts` is the single
entry point that installs bundled defaults and then the optional platform
fallbacks. The SDL_GPU reference host, `ui.run`'s native path, and the hosted
SDL3/WebGPU path (`ui/webgpu.run`) all call it, so both desktop backends load an
identical stack. The browser `ui/webgpu.run` path still loads bundled defaults
only: a browser cannot read local font files, and a DOM/network font source is a
separate feature.

### The U+22EF midline-ellipsis case

The bundled Atkinson faces do not cover U+22EF HORIZONTAL MIDLINE ELLIPSIS.
Before the shared seeding, the hosted WebGPU host loaded bundled defaults only
and shaped it as `.notdef` (glyph 0), while the reference host resolved it
through an optional system face (on the validation machine, `NotoSansJP-VF.ttf`)
and reported a real glyph. That was an initialization-parity gap, not a Runa
coverage bug: the same codepoint resolves identically once both hosts build the
same stack. The inspector now records `faces=[...] unresolved=...` on text runs
and `text fallback glyphs: ... face=N gid=N` for fallback glyphs, so a capture
bundle proves the choice without a screenshot.

That fix is not a promise that every system covers the codepoint. `segoeui.ttf`
does not contain U+22EF either, so a machine without a covering optional face
still boxes a text glyph. Controls whose meaning is "more actions" should not
depend on font coverage at all: use the semantic `More_Horizontal` icon
(`icon_button(ui, "More actions", .More_Horizontal, ...)`) instead of the
character. General system-font coverage remains follow-up work; it is not
solved by bundling a second font here.

Scratchpad continues to own the selected editor font preference. Alicorn owns
font-file/face lifetimes, fallback registration, and retained text invalidation.
Runa owns grapheme selection, script/style run shaping, glyph metrics, and
rasterization.

## Color glyph formats

Runa rasterizes COLRv0 and its implemented subset of COLRv1 paint graphs into
RGBA atlas pages. Alicorn's GPU text path keeps those atlas RGB values intact
while applying paint opacity. Monochrome glyph masks continue to receive the
syntax/UI text color.

Runa can inspect table presence for `COLR`, `CPAL`, `sbix`, `CBDT`, and `CBLC`,
but table detection does not imply raster support. `sbix` bitmap strikes and
`CBDT`/`CBLC` bitmap glyph data are not decoded yet. On Windows, DirectWrite
fallback can use system emoji when the selected face uses supported COLR data.
On macOS and Linux, native system-font discovery and color emoji rendering
remain unimplemented in this work. Finding Apple Color Emoji or Noto Color
Emoji does not make its `sbix` or `CBDT`/`CBLC` glyphs drawable by Runa.

### Bitmap-font implementation investigation

The two bitmap families need bounded parsers and image-to-glyph placement;
they are not interchangeable with COLR paint graphs:

- `sbix` stores per-glyph image records in pixel-size strikes, with origin
  offsets and image tags such as PNG, JPEG, and TIFF. It also has `dupe` and
  `mask` records, whose references and blend modes need explicit handling.
  Apple Color Emoji uses this table; see the [Apple `sbix` reference](https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6sbix.html).
- `CBDT` data is located by `CBLC` strike/index subtables. It can store
  premultiplied BGRA pixels or PNG glyph images and carries strike-specific
  glyph metrics. Google's Noto Color Emoji uses CBDT/CBLC; see the [OpenType
  CBDT specification](https://learn.microsoft.com/en-us/typography/opentype/spec/cbdt).

Runa's existing `Color_Bitmap` and Alicorn RGBA atlas already provide a bounded
CPU-raster-to-GPU path, so this does not call for a new shader or platform
glyph renderer. A future Runa patch should parse glyph records with strict
table, offset, strike, decoded-dimension, and allocation bounds; choose the
closest usable strike; and return bitmap bearings alongside RGBA pixels.
Noto's premultiplied BGRA data must be converted to the straight-alpha format
used by Runa's color atlas compositor (or the atlas blend contract must be
changed consistently). PNG decoding can reuse an existing decoder if its
format and allocation limits fit Runa's dependency contract. A sensible first
increment is PNG-backed CBDT/CBLC plus `sbix` PNG and `dupe`; defer JPEG/TIFF,
`sbix` masks and PDF records until their decoding and blend semantics are
needed. Glyphs without a matching bitmap strike should continue through the
existing outline/COLR paths. The atlas key must continue to include face ID,
glyph ID, and raster size so bitmap strikes and vector glyphs cannot collide.

## Validation and remaining work

- Runa unit tests cover CJK, combining sequences, text/emoji variation
  selectors, modifiers, ZWJ, keycap, flag, unsupported-cluster behavior,
  UTF-8 source byte boundaries, and adjacent Arabic script runs.
- Alicorn tests cover targeted refresh when registered fallback coverage is
  added. Windows native tests verify DirectWrite CJK selection and color emoji
  atlas output when the OS provides a compatible COLR face.
- `host/fonts` tests verify that both desktop host initializations build the
  same face stack and resolve U+22EF to the same face and glyph (or record
  unresolved `.notdef` coverage when the machine has no covering system face).
  Runtime tests pin the inspector's `faces=`/`unresolved=` and fallback-glyph
  provenance, and the icon tests pin the font-independent `More_Horizontal`
  control.
- Native Windows launch/build and visual checks still need to be recorded on
  supported Windows versions. Verify the emoji RGBA colors, alpha, syntax-color
  interaction, wrapping, caret/source-byte behavior, and detached windows.
- CoreText and Fontconfig provider support, document-language-aware Han
  preference, dynamic asynchronous lookup, non-unit DirectWrite scaling, and
  `sbix`/`CBDT`/`CBLC` rasterization remain follow-up work.
