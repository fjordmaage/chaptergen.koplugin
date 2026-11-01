# ChapterGen — KOReader plugin: fix missing chapter marks

Some EPUBs nest their chapters below *Part* entries in the table of contents
(e.g. `PART ONE → chapters 1–17`, `PART TWO → chapters 18–31`). Depending on
KOReader version and settings, only the **top-level** TOC entries are then used
for the progress-bar chapter ticks and for chapter navigation ("skip to next
chapter", skim widget, …) — so almost all chapters seem to be missing: you get
a couple of ticks at the very start (cover, title page), one in the middle
(PART TWO) and a couple at the end (acknowledgements, about the author),
while books with a flat TOC work fine.

ChapterGen fixes this, either per book without touching the file (like
patch-style plugins do it) or permanently inside the EPUB itself.

## What it does

**1. Flatten chapter hierarchy (soft fix, reversible)**
A per-book toggle (plus an optional "all books" default) that promotes every
TOC entry to the top level in KOReader's in-memory table of contents. The book
file is untouched. Progress-bar ticks, "skip to next/previous chapter",
chapter progress in the footer and the skim widget immediately see every
chapter. Works for any document format KOReader can open, and switching the
toggle off instantly restores the original hierarchy. The setting is saved per
book in its sidecar.

**2. Fix book file permanently (rewrite EPUB)**
Rewrites the EPUB so the chapter hierarchy is flattened *inside the file*:

- EPUB 2: the `navMap` of the NCX is flattened (all `navPoint`s become
  top-level, in reading order; `dtb:depth` is set to 1).
- EPUB 3: the `toc` nav of the navigation document is flattened to a single
  `<ol>`.
- Everything else in the book (text, images, styles, metadata, reading
  position, highlights) is untouched.
- A backup of the original file is kept next to it as `<book>.epub.orig`.

This fixes the book for every reading app, not just KOReader.

## Usage

- **While reading** (tools menu ⚙ → *ChapterGen: chapter marks fix*):
  - *Flatten chapter hierarchy for this book* — the soft toggle.
  - *Flatten chapter hierarchy in all books* — make it the default.
  - *Fix book file permanently (rewrite EPUB)* — rewrites the current book
    and reloads it in place.
- **In the file manager**: long-press an EPUB → *Flatten chapter list
  (ChapterGen)* — permanently fixes that file without opening it.
- A gesture/dispatcher action *Toggle flat chapter list (ChapterGen)* is also
  available.

Note: with the flatten toggle active, the TOC list is shown without
indentation (parts and chapters on one level) — that is exactly what makes
every chapter count as a chapter.

## Installation

1. Copy the `chaptergen.koplugin` folder into the `plugins` directory of your
   KOReader installation (e.g. `koreader/plugins/chaptergen.koplugin` — next
   to `hello.koplugin` etc.).
2. Restart KOReader.

The soft fix works on any reasonably recent KOReader. The permanent EPUB
rewrite needs a KOReader new enough to ship libarchive (`ffi/archiver`,
releases from 2024 on); on older versions the plugin tells you so and the soft
fix still works.

## Why this happens (background)

In a nested NCX the chapters live at depth 2:

```xml
<navPoint id="navPoint-3" playOrder="3">        <!-- PART ONE (depth 1) -->
  <navLabel><text>PART ONE</text></navLabel>
  <content src="Text/Section0002.xhtml"/>
  <navPoint id="navPoint-4" playOrder="4">      <!-- chapter 1 (depth 2) -->
    <navLabel><text>1</text></navLabel>
    <content src="Text/Section0003.xhtml"/>
  </navPoint>
  ...
</navPoint>
```

Chapter ticks/navigation that only consider depth 1 see just the parts.
After flattening, every entry is a depth-1 `navPoint` in reading order, which
is exactly how books that behave correctly (flat TOC) are structured.

## Development

The TOC transformation lives in `chaptergen.koplugin/epubtoc.lua` and is pure
Lua with no KOReader dependencies. Run the tests from the repository root:

```sh
lua tests/run.lua
```

The fixtures include the real nested/flat NCX structures that motivated the
plugin.

## License

See [LICENSE](LICENSE).
