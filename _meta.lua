local _ = require("gettext")
return {
    name = "chaptergen",
    fullname = _("ChapterGen"),
    description = _([[Fixes books whose chapters are nested below "Part" entries in the table of contents, so every chapter shows up in the progress bar and in chapter navigation. Can flatten the chapter list per book (reversibly) or rewrite the EPUB permanently.]]),
}
