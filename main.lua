--[[--
ChapterGen: fix incomplete chapter marks caused by nested TOC hierarchies.

Many EPUBs nest their chapters below "Part" entries in the table of
contents. Depending on version and settings, KOReader may then only use
the top-level entries (the parts) for the progress-bar chapter ticks and
for chapter-based navigation ("skip to next chapter"), so almost all
chapters disappear.

This plugin offers two complementary fixes:

1. A per-book (or global) toggle that flattens the chapter hierarchy
   in KOReader's in-memory TOC, without touching the file: every TOC
   entry is promoted to the top level, so every chapter gets a tick on
   the progress bar and is reachable with chapter navigation.
   This works for any document format and is instantly reversible.

2. A permanent fix that rewrites the EPUB itself: the navMap of the
   NCX (EPUB 2) and/or the toc nav of the navigation document (EPUB 3)
   are flattened, in reading order. This fixes the book for every
   reader, not only KOReader. Available from the reader menu for the
   current book, and from the long-press file dialog in the file
   manager.

Since only the TOC files inside the EPUB are modified, the backup for
the permanent fix is tiny: the original TOC files are stored in the
book's KOReader settings (sidecar), from which the book can be restored
at any time. No full copy of the book is kept around.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local EpubToc = require("epubtoc")

local ChapterGen = WidgetContainer:extend{
    name = "chaptergen",
    is_doc_only = false,
}

-- Message to show once the reader has been reloaded after a permanent fix
-- (survives the ReaderUI teardown/reload cycle as it lives on the class).
ChapterGen.pending_message = nil

-- Key in the book's sidecar settings holding the original TOC files.
local BACKUP_SETTING = "chaptergen_backup"

function ChapterGen:onDispatcherRegisterActions()
    Dispatcher:registerAction("chaptergen_toggle_flatten", {
        category = "none",
        event = "ChapterGenToggleFlatten",
        title = _("Toggle flat chapter list (ChapterGen)"),
        reader = true,
    })
end

function ChapterGen:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.toc then
        self:hookToc()
        if self:isFlattenEnabled() and self.ui.toc.toc then
            -- The ToC was already built before we were loaded: rebuild it
            -- lazily so the flattening hook gets applied.
            self.ui.toc:resetToc()
        end
    end
    if self.ui.addFileDialogButtons then
        self:addFileManagerButtons()
    end
    if ChapterGen.pending_message then
        local msg = ChapterGen.pending_message
        ChapterGen.pending_message = nil
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{ text = msg })
        end)
    end
end

-- Soft fix: flatten KOReader's in-memory TOC {{{

function ChapterGen:isFlattenEnabled()
    if not self.ui or not self.ui.doc_settings then
        return false
    end
    local per_book = self.ui.doc_settings:readSetting("chaptergen_flatten")
    if per_book ~= nil then
        return per_book
    end
    return G_reader_settings:isTrue("chaptergen_flatten_all")
end

function ChapterGen:hookToc()
    local toc = self.ui.toc
    if toc._chaptergen_orig_fillToc then
        return
    end
    local plugin = self
    toc._chaptergen_orig_fillToc = toc.fillToc
    toc.fillToc = function(toc_self, ...)
        toc_self._chaptergen_orig_fillToc(toc_self, ...)
        plugin:applyFlatten(toc_self)
    end
end

function ChapterGen:applyFlatten(toc_self)
    local toc = toc_self.toc
    if not toc then
        return
    end
    if self:isFlattenEnabled() then
        local changed = false
        for i = 1, #toc do
            local item = toc[i]
            if item.depth and item.depth ~= 1 then
                item.orig_depth_chaptergen = item.orig_depth_chaptergen or item.depth
                item.depth = 1
                changed = true
            end
        end
        if changed then
            toc_self.toc_depth = 1
        end
    else
        -- Make sure a stale flattened table is restored when toggled off.
        local restored = false
        for i = 1, #toc do
            local item = toc[i]
            if item.orig_depth_chaptergen then
                item.depth = item.orig_depth_chaptergen
                item.orig_depth_chaptergen = nil
                restored = true
            end
        end
        if restored then
            toc_self.toc_depth = nil -- have getMaxDepth() recompute it
        end
    end
end

function ChapterGen:refreshToc()
    if not self.ui.toc then
        return
    end
    -- Resets the cached ToC and ticks, and emits "TocReset" so the footer
    -- rebuilds its progress-bar chapter markers.
    self.ui.toc:onUpdateToc()
end

function ChapterGen:toggleFlatten()
    if not self.ui.doc_settings then
        return
    end
    self.ui.doc_settings:saveSetting("chaptergen_flatten", not self:isFlattenEnabled())
    self:refreshToc()
end

function ChapterGen:onChapterGenToggleFlatten()
    self:toggleFlatten()
    local enabled = self:isFlattenEnabled()
    UIManager:show(InfoMessage:new{
        text = enabled and _("ChapterGen: flat chapter list enabled.")
            or _("ChapterGen: flat chapter list disabled."),
        timeout = 2,
    })
    return true
end

-- }}}

-- Permanent fix: rewrite the EPUB file {{{

local function isEpub(filepath)
    return filepath and filepath:lower():match("%.epub$") ~= nil
end

function ChapterGen:canFixCurrentBook()
    return self.ui.document ~= nil and isEpub(self.ui.document.file)
end

-- Backup bookkeeping: the original TOC files live in the book's sidecar
-- settings. Standalone reads/writes (DocSettings:open) are only done when
-- the book is not open in the reader; for the open book, its own
-- doc_settings instance is used for reading, and writes happen between
-- document close and reopen (see fixCurrentBook/restoreFileConfirm).

local function readBackupStandalone(filepath)
    return DocSettings:open(filepath):readSetting(BACKUP_SETTING)
end

local function saveBackupStandalone(filepath, files)
    local ds = DocSettings:open(filepath)
    ds:saveSetting(BACKUP_SETTING, {
        version = 1,
        date = os.date("%Y-%m-%d %H:%M:%S"),
        files = files,
    })
    ds:flush()
end

local function clearBackupStandalone(filepath)
    local ds = DocSettings:open(filepath)
    ds:delSetting(BACKUP_SETTING)
    ds:flush()
end

function ChapterGen:readBackup(filepath)
    if self.ui.document and self.ui.document.file == filepath and self.ui.doc_settings then
        return self.ui.doc_settings:readSetting(BACKUP_SETTING)
    end
    return readBackupStandalone(filepath)
end

function ChapterGen:hasBackup(filepath)
    if not filepath then
        return false
    end
    if lfs.attributes(filepath .. ".orig", "mode") == "file" then
        return true -- legacy full-copy backup from 0.1.0-alpha
    end
    local backup = self:readBackup(filepath)
    return type(backup) == "table" and type(backup.files) == "table"
        and next(backup.files) ~= nil
end

local function getArchiver()
    local ok, Archiver = pcall(require, "ffi/archiver")
    if ok and Archiver and Archiver.Reader and Archiver.Writer then
        return Archiver
    end
    return nil, _("This KOReader version is too old for the permanent fix (no libarchive support). The flatten toggle still works.")
end

-- Rewrite the EPUB zip with some entries' content replaced.
-- @param replacements map of zip entry path -> new content
-- @return tmp_path on success; nil, error_text otherwise
function ChapterGen:rebuildEpub(filepath, replacements)
    local Archiver, archiver_err = getArchiver()
    if not Archiver then
        return nil, archiver_err
    end
    local reader = Archiver.Reader:new()
    if not reader:open(filepath) then
        return nil, T(_("Could not open %1"), filepath)
    end
    local tmp_path = filepath .. ".chaptergen.tmp"
    os.remove(tmp_path)
    local writer = Archiver.Writer:new()
    if not writer:open(tmp_path, "zip") then
        reader:close()
        return nil, _("Could not create the temporary file for the book.")
    end
    local write_err
    -- Per the EPUB spec the mimetype entry must come first, uncompressed.
    if not writer:setZipCompression("store")
        or not writer:addFileFromMemory("mimetype", "application/epub+zip")
        or not writer:setZipCompression("deflate") then
        write_err = writer.err or "write error"
    else
        for entry in reader:iterate() do
            if entry.mode == "file" and entry.path ~= "mimetype" then
                local data
                if replacements[entry.path] then
                    data = replacements[entry.path]
                elseif entry.size == 0 then
                    data = ""
                else
                    data = reader:extractToMemory(entry.path)
                end
                if not data then
                    write_err = T(_("Could not read %1 from the book."), entry.path)
                    break
                end
                if not writer:addFileFromMemory(entry.path, data) then
                    write_err = writer.err or "write error"
                    break
                end
            end
        end
    end
    writer:close()
    reader:close()
    if write_err then
        os.remove(tmp_path)
        return nil, T(_("Could not write the book: %1"), tostring(write_err))
    end
    return tmp_path
end

-- Find and flatten the TOC documents of an EPUB.
-- @return replacements (path -> flattened content),
--         originals (path -> original content),
--         info_text on success; nil, error_text otherwise
function ChapterGen:analyzeEpub(filepath)
    local Archiver, archiver_err = getArchiver()
    if not Archiver then
        return nil, archiver_err
    end
    local reader = Archiver.Reader:new()
    if not reader:open(filepath) then
        return nil, T(_("Could not open %1"), filepath)
    end
    local function fail(msg)
        reader:close()
        return nil, msg
    end
    -- Index all entries first (Reader:seek only knows already-seen entries).
    for __ in reader:iterate() do
        -- luacheck: ignore
    end
    -- Resolve a (possibly URL-encoded) path to an actual zip entry path.
    local function readEntry(path)
        local entry_path
        if reader.entries[path] then
            entry_path = path
        else
            local decoded = EpubToc.urldecode(path)
            if reader.entries[decoded] then
                entry_path = decoded
            end
        end
        if not entry_path then
            return
        end
        return reader:extractToMemory(entry_path), entry_path
    end

    local container = readEntry("META-INF/container.xml")
    if not container then
        return fail(_("Not a valid EPUB: no META-INF/container.xml found."))
    end
    local opf_path = EpubToc.findOpfPath(container)
    local opf = opf_path and readEntry(opf_path)
    if not opf then
        return fail(_("Not a valid EPUB: package document (OPF) not found."))
    end
    local opf_dir = EpubToc.dirname(opf_path)
    local ncx_href, nav_href = EpubToc.findTocHrefs(opf)

    local replacements, originals = {}, {}
    local n_entries, was_flat = 0, false
    if ncx_href then
        local ncx, ncx_path = readEntry(EpubToc.joinPath(opf_dir, ncx_href:gsub("#.*$", "")))
        if ncx then
            local new_ncx, res = EpubToc.flattenNcx(ncx)
            if new_ncx then
                replacements[ncx_path] = new_ncx
                originals[ncx_path] = ncx
                n_entries = math.max(n_entries, res.entries)
            elseif res == "already_flat" then
                was_flat = true
            else
                logger.warn("ChapterGen: could not flatten NCX:", res)
            end
        end
    end
    if nav_href then
        local nav, nav_path = readEntry(EpubToc.joinPath(opf_dir, nav_href:gsub("#.*$", "")))
        if nav then
            local new_nav, res = EpubToc.flattenNav(nav)
            if new_nav then
                replacements[nav_path] = new_nav
                originals[nav_path] = nav
                n_entries = math.max(n_entries, res.entries)
            elseif res == "already_flat" then
                was_flat = true
            else
                logger.warn("ChapterGen: could not flatten nav document:", res)
            end
        end
    end
    reader:close()
    if next(replacements) == nil then
        if was_flat then
            return nil, _("This book's table of contents is already flat — nothing to fix.")
        end
        return nil, _("No table of contents found in this book.")
    end
    return replacements, originals,
        T(_("Chapter list flattened: %1 chapters are now top-level entries."), n_entries)
end

-- Atomically replace the book with the rewritten copy.
-- @return true on success; nil, error_text otherwise
function ChapterGen:replaceFile(filepath, tmp_path)
    local ok, err = os.rename(tmp_path, filepath)
    if not ok then
        os.remove(tmp_path)
        return nil, T(_("Could not replace the book file: %1"), tostring(err))
    end
    return true
end

function ChapterGen:fixFileConfirm(filepath, is_current_book)
    local filename = filepath:match("([^/]+)$") or filepath
    UIManager:show(ConfirmBox:new{
        text = T(_("Flatten the chapter hierarchy inside this EPUB?\n\n%1\n\nEvery chapter becomes a top-level entry, so all chapters show up in the progress bar and in chapter navigation — in KOReader and any other reader. The original chapter list is backed up in the book's settings and can be restored at any time."),
            filename),
        ok_text = _("Fix book"),
        ok_callback = function()
            if is_current_book then
                self:fixCurrentBook()
            else
                self:fixFile(filepath)
            end
        end,
    })
end

function ChapterGen:fixFile(filepath)
    local replacements, originals, msg = self:analyzeEpub(filepath)
    if not replacements then
        UIManager:show(InfoMessage:new{ text = originals }) -- the error text
        return
    end
    local tmp_path, err = self:rebuildEpub(filepath, replacements)
    if not tmp_path then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local ok, replace_err = self:replaceFile(filepath, tmp_path)
    if ok then
        saveBackupStandalone(filepath, originals)
    end
    UIManager:show(InfoMessage:new{ text = ok and msg or replace_err })
end

function ChapterGen:fixCurrentBook()
    local filepath = self.ui.document.file
    -- Build the fixed copy while the book is still open (reading is safe),
    -- then swap the files in between closing and reopening the document.
    local replacements, originals, msg = self:analyzeEpub(filepath)
    if not replacements then
        UIManager:show(InfoMessage:new{ text = originals }) -- the error text
        return
    end
    local tmp_path, err = self:rebuildEpub(filepath, replacements)
    if not tmp_path then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if self.ui.reloadDocument then
        local plugin = self
        self.ui:reloadDocument(function()
            -- The reader has closed the book and flushed its sidecar; swap
            -- the file and record the backup before the book is reopened.
            local ok, replace_err = plugin:replaceFile(filepath, tmp_path)
            if ok then
                saveBackupStandalone(filepath, originals)
            end
            -- Shown by the plugin instance of the reloaded ReaderUI.
            ChapterGen.pending_message = ok and msg or replace_err
        end)
    else
        local ok, replace_err = self:replaceFile(filepath, tmp_path)
        if ok then
            saveBackupStandalone(filepath, originals)
            if self.ui.doc_settings then
                -- Keep the open book's settings in sync, so its flush on
                -- close doesn't drop the backup again.
                self.ui.doc_settings:saveSetting(BACKUP_SETTING, readBackupStandalone(filepath))
            end
        end
        UIManager:show(InfoMessage:new{
            text = ok and (msg .. "\n\n" .. _("Please close and reopen the book to see the fixed chapter list."))
                or replace_err,
        })
    end
end

-- Undo the permanent fix: put the original TOC back.
-- Prefers a legacy .orig full-file backup (byte-identical original) when one
-- exists; otherwise rebuilds the book from the TOC files stored in the
-- book's settings.
-- @return true on success; nil, error_text otherwise
function ChapterGen:restoreFile(filepath)
    local legacy = filepath .. ".orig"
    if lfs.attributes(legacy, "mode") == "file" then
        local ok, err = os.remove(filepath)
        if not ok then
            return nil, T(_("Could not remove the fixed book file: %1"), tostring(err))
        end
        ok, err = os.rename(legacy, filepath)
        if not ok then
            return nil, T(_("Could not restore the backup: %1"), tostring(err))
        end
        clearBackupStandalone(filepath)
        return true
    end
    local backup = readBackupStandalone(filepath)
    if type(backup) ~= "table" or type(backup.files) ~= "table"
        or next(backup.files) == nil then
        return nil, _("No backup found for this book.")
    end
    local tmp_path, err = self:rebuildEpub(filepath, backup.files)
    if not tmp_path then
        return nil, err
    end
    local ok, replace_err = self:replaceFile(filepath, tmp_path)
    if not ok then
        return nil, replace_err
    end
    clearBackupStandalone(filepath)
    return true
end

function ChapterGen:restoreFileConfirm(filepath, is_current_book)
    local filename = filepath:match("([^/]+)$") or filepath
    UIManager:show(ConfirmBox:new{
        text = T(_("Restore the original chapter list of this book?\n\n%1\n\nThe book gets its original (nested) table of contents back. Your reading position and highlights are kept."), filename),
        ok_text = _("Restore original"),
        ok_callback = function()
            if is_current_book and self.ui.reloadDocument then
                local plugin = self
                self.ui:reloadDocument(function()
                    local ok, err = plugin:restoreFile(filepath)
                    ChapterGen.pending_message = ok and _("Original chapter list restored.") or err
                end)
            else
                local ok, err = self:restoreFile(filepath)
                local msg = ok and _("Original chapter list restored.") or err
                if ok and is_current_book then
                    if self.ui.doc_settings then
                        -- Keep the open book's settings in sync, so its
                        -- flush on close doesn't resurrect the backup.
                        self.ui.doc_settings:delSetting(BACKUP_SETTING)
                    end
                    msg = msg .. "\n\n" .. _("Please close and reopen the book.")
                end
                UIManager:show(InfoMessage:new{ text = msg })
            end
        end,
    })
end

-- }}}

-- File manager long-press dialog button {{{

function ChapterGen:addFileManagerButtons()
    local plugin = self
    self.ui:addFileDialogButtons("chaptergen", function(file, is_file, book_props)
        if not is_file or not isEpub(file) then
            return
        end
        local function closeFileDialog()
            -- The file dialog lives on the menu widget.
            local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
            if ok_fm and FileManager then
                local menu
                if FileManager.getMenuInstance then
                    local ok_menu, m = pcall(FileManager.getMenuInstance)
                    if ok_menu then
                        menu = m
                    end
                end
                menu = menu or FileManager.instance and FileManager.instance.file_chooser
                if menu and menu.file_dialog then
                    UIManager:close(menu.file_dialog)
                end
            end
        end
        local row = {
            {
                text = _("Flatten chapter list (ChapterGen)"),
                callback = function()
                    closeFileDialog()
                    plugin:fixFileConfirm(file, false)
                end,
            },
        }
        if plugin:hasBackup(file) then
            table.insert(row, {
                text = _("Restore original (ChapterGen)"),
                callback = function()
                    closeFileDialog()
                    plugin:restoreFileConfirm(file, false)
                end,
            })
        end
        return row
    end)
end

-- }}}

function ChapterGen:addToMainMenu(menu_items)
    local help_item = {
        text = _("Help"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _([[Some books nest their chapters below "Part" entries in the table of contents. KOReader may then only use the part entries for progress-bar chapter ticks and chapter navigation, so most chapters seem to be missing.

ChapterGen fixes this in two ways:

• Flatten chapter hierarchy (per book or for all books): changes only how KOReader sees the table of contents. Instant and reversible.

• Fix book file permanently: rewrites the EPUB so every chapter is a top-level entry, fixing the book in any reader. The original chapter list is backed up in the book's settings and can be restored from the same menu. In the file manager, long-press an EPUB to fix or restore it without opening it.]]),
            })
        end,
    }
    local all_books_item = {
        text = _("Flatten chapter hierarchy in all books"),
        help_text = _("Apply the flattening to every book by default. Books with their own per-book setting keep it."),
        checked_func = function()
            return G_reader_settings:isTrue("chaptergen_flatten_all")
        end,
        callback = function()
            G_reader_settings:saveSetting("chaptergen_flatten_all",
                not G_reader_settings:isTrue("chaptergen_flatten_all"))
            self:refreshToc()
        end,
        separator = true,
    }
    local sub_item_table
    if self.ui.toc then
        -- Reader: full menu for the current book.
        sub_item_table = {
            {
                text = _("Flatten chapter hierarchy for this book"),
                help_text = _("Treat every table-of-contents entry of this book as a top-level chapter, so all chapters get a tick on the progress bar and are reachable with chapter navigation. Only changes how KOReader sees the book; the file is not modified."),
                checked_func = function()
                    return self:isFlattenEnabled()
                end,
                callback = function()
                    self:toggleFlatten()
                end,
            },
            all_books_item,
            {
                text = _("Fix book file permanently (rewrite EPUB)"),
                help_text = _("Rewrite the EPUB so the chapter hierarchy is flattened inside the file itself. This fixes the chapter list for any reading app. The original chapter list is backed up in the book's settings."),
                enabled_func = function()
                    return self:canFixCurrentBook()
                end,
                callback = function()
                    if self:canFixCurrentBook() then
                        self:fixFileConfirm(self.ui.document.file, true)
                    end
                end,
            },
            {
                text = _("Restore original chapter list"),
                help_text = _("Undo the permanent fix: put the backed-up original table of contents back into the book."),
                enabled_func = function()
                    return self:canFixCurrentBook() and self:hasBackup(self.ui.document.file)
                end,
                callback = function()
                    if self:canFixCurrentBook() and self:hasBackup(self.ui.document.file) then
                        self:restoreFileConfirm(self.ui.document.file, true)
                    end
                end,
            },
            help_item,
        }
    else
        -- File manager: only the global toggle and help; fixing a specific
        -- file is done by long-pressing it in the file browser.
        sub_item_table = {
            all_books_item,
            help_item,
        }
    end
    menu_items.chaptergen = {
        text = _("ChapterGen: chapter marks fix"),
        sorting_hint = "more_tools",
        sub_item_table = sub_item_table,
    }
end

return ChapterGen
