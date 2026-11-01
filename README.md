# chaptergen.koplugin

A KOReader plugin that fixes books where most chapters are missing from the
progress bar and from "skip to next chapter".

Some EPUBs nest their chapters under *Part One* / *Part Two* entries in the
table of contents. KOReader may then only count the parts as chapters, so you
get a couple of chapter ticks at the start and end of the book and almost
nothing in between. This plugin flattens the chapter hierarchy so every
chapter counts again.

## Usage

While reading, open the tools menu → **ChapterGen: chapter marks fix**:

- **Flatten chapter hierarchy for this book** — instant fix, nothing is
  written to the file, and you can toggle it off again. There's also a switch
  to apply it to all books by default, and a gesture action if you want it on
  a tap or swipe.
- **Fix book file permanently (rewrite EPUB)** — rewrites the book itself so
  the fix works in any reading app. A backup is kept next to the book as
  `.orig`.

You can also long-press any EPUB in the file manager and pick **Flatten
chapter list (ChapterGen)** to fix a file without opening it.

Heads-up: with the fix active, the table of contents is shown as a flat list
(parts and chapters on the same level) — that's the point. 🙂

## Installation

Copy this folder into `koreader/plugins/` as `chaptergen.koplugin` and restart
KOReader.

The permanent EPUB rewrite needs a KOReader from 2024 or newer; on older
versions the toggle still works.

## Development

The TOC rewriting lives in `epubtoc.lua` (plain Lua, no KOReader
dependencies). Run the tests with `lua tests/run.lua`.
