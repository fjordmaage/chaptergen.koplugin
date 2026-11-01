First release — feedback welcome!

### Added

- **Flatten chapter hierarchy** toggle (per book or for all books): makes every chapter count for progress-bar ticks and "skip to next chapter", without modifying the book file. Reversible, saved per book, and available as a gesture action.
- **Fix book file permanently**: rewrites the EPUB (EPUB 2 NCX and/or EPUB 3 nav) so the chapter list is flat in any reading app. Keeps a `.orig` backup. Also available by long-pressing an EPUB in the file manager.
- **Restore original book file**: puts the `.orig` backup back, undoing the permanent fix (reader menu, or long-press in the file manager).

### Installation

Download `chaptergen.koplugin.zip` below, extract it into `koreader/plugins/` and restart KOReader.
