Second alpha — feedback welcome!

### Added

- **Restore original chapter list**: undoes the permanent fix (reader menu, or long-press in the file manager).

### Changed

- Backups for the permanent fix are now tiny: instead of keeping a full `.orig` copy of the book, only the original chapter-list files (a few KB) are stored in the book's KOReader settings. `.orig` backups made by 0.1.0-alpha are still recognized and used for restoring.
- Replacing the book file is now a single atomic rename, so there is no moment during the fix where the book is missing from disk.

### Fixed

- Crash when tapping "Fix book file permanently" in the file manager's tools menu (the menu now only shows book-specific actions while reading; in the file manager, long-press an EPUB instead).

### Installation

Download `chaptergen.koplugin.zip` below, extract it into `koreader/plugins/` and restart KOReader.
