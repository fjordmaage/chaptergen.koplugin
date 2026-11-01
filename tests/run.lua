-- Unit tests for chaptergen.koplugin/epubtoc.lua
-- Run from the repository root with any Lua 5.1+ interpreter:
--   lua tests/run.lua

package.path = "chaptergen.koplugin/?.lua;" .. package.path
local EpubToc = require("epubtoc")

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local content = f:read("*a")
    f:close()
    return content
end

-- Path helpers ---------------------------------------------------------------

check(EpubToc.urldecode("Text/My%20Book.xhtml") == "Text/My Book.xhtml", "urldecode decodes %20")
check(EpubToc.urldecode("plain.xhtml") == "plain.xhtml", "urldecode leaves plain paths alone")
check(EpubToc.normalizePath("OEBPS/./Text/../toc.ncx") == "OEBPS/toc.ncx", "normalizePath resolves . and ..")
check(EpubToc.dirname("OEBPS/content.opf") == "OEBPS", "dirname returns the directory")
check(EpubToc.dirname("content.opf") == nil, "dirname is nil in the root")
check(EpubToc.joinPath("OEBPS", "Text/ch1.xhtml") == "OEBPS/Text/ch1.xhtml", "joinPath joins")
check(EpubToc.joinPath(nil, "toc.ncx") == "toc.ncx", "joinPath without a dir")
check(EpubToc.joinPath("OEBPS/Text", "../toc.ncx") == "OEBPS/toc.ncx", "joinPath resolves ..")

-- container.xml / OPF --------------------------------------------------------

local container = readFile("tests/fixtures/container.xml")
check(EpubToc.findOpfPath(container) == "OEBPS/content.opf", "findOpfPath finds the OPF")

local opf = readFile("tests/fixtures/content.opf")
local ncx_href, nav_href = EpubToc.findTocHrefs(opf)
check(ncx_href == "toc.ncx", "findTocHrefs finds the NCX (got: " .. tostring(ncx_href) .. ")")
check(nav_href == nil, "findTocHrefs finds no nav document in an EPUB 2 OPF")

-- NCX flattening -------------------------------------------------------------

local nested_ncx = readFile("tests/fixtures/nested_toc.ncx")
local entries, max_depth = EpubToc.parseNcxNavPoints(
    nested_ncx:match("<navMap[^>]*>(.*)</navMap>"))
check(#entries == 37, "nested NCX has 37 entries (got: " .. #entries .. ")")
check(max_depth == 2, "nested NCX has depth 2 (got: " .. max_depth .. ")")
check(entries[3].label == "PART ONE" and entries[3].depth == 1, "part entry parsed at depth 1")
check(entries[4].label == "1" and entries[4].depth == 2
    and entries[4].src == "Text/Section0003.xhtml", "first chapter parsed at depth 2")
check(entries[37].label == "About the Author", "last entry parsed")

local new_ncx, info = EpubToc.flattenNcx(nested_ncx)
check(new_ncx ~= nil, "flattenNcx succeeds on a nested NCX")
check(info and info.entries == 37 and info.max_depth == 2, "flattenNcx reports 37 entries, depth 2")
local reparsed, redepth = EpubToc.parseNcxNavPoints(new_ncx:match("<navMap[^>]*>(.*)</navMap>"))
check(#reparsed == 37, "flattened NCX keeps all 37 entries (got: " .. #reparsed .. ")")
check(redepth == 1, "flattened NCX has depth 1 (got: " .. redepth .. ")")
check(new_ncx:match('<meta name="dtb:depth" content="(%d+)"') == "1", "dtb:depth updated to 1")
for i = 1, #reparsed do
    if reparsed[i].label ~= entries[i].label or reparsed[i].src ~= entries[i].src then
        check(false, "entry " .. i .. " preserved in order")
        break
    end
    if i == #reparsed then
        check(true, "all entries preserved in reading order")
    end
end
check(new_ncx:find("<docTitle>", 1, true) ~= nil, "document head preserved")

local flat_ncx = readFile("tests/fixtures/flat_toc.ncx")
local none, err = EpubToc.flattenNcx(flat_ncx)
check(none == nil and err == "already_flat", "flattenNcx refuses an already flat NCX")

-- Flattening twice is a no-op.
local again, err2 = EpubToc.flattenNcx(new_ncx)
check(again == nil and err2 == "already_flat", "flattenNcx is idempotent")

-- EPUB 3 nav flattening ------------------------------------------------------

local nested_nav = readFile("tests/fixtures/nested_nav.xhtml")
local new_nav, nav_info = EpubToc.flattenNav(nested_nav)
check(new_nav ~= nil, "flattenNav succeeds on a nested nav")
check(nav_info and nav_info.entries == 6, "flattenNav keeps 6 linked entries (got: "
    .. tostring(nav_info and nav_info.entries) .. ")")
check(new_nav:find('<a href="ch01.xhtml">Chapter 1</a>', 1, true) ~= nil,
    "inner markup stripped from labels")
check(new_nav:find('<a href="part2.xhtml">Part Two</a>', 1, true) ~= nil,
    "part entries with links are kept")
check(new_nav:find("<h1>Contents</h1>", 1, true) ~= nil, "nav heading preserved")
check(new_nav:find('epub:type="landmarks"', 1, true) ~= nil, "landmarks nav untouched")
local toc_nav_body = new_nav:match("<nav[^>]-type%s*=%s*[\"']toc[\"'][^>]*>(.-)</nav>")
local __, ol_count = toc_nav_body:gsub("<ol[%s>]", "")
check(ol_count == 1, "flattened nav has a single <ol> (got: " .. ol_count .. ")")

local nav_none, nav_err = EpubToc.flattenNav(new_nav)
check(nav_none == nil and nav_err == "already_flat", "flattenNav is idempotent")

-- Result ---------------------------------------------------------------------

print("")
if failures > 0 then
    print(failures .. " test(s) FAILED")
    os.exit(1)
else
    print("all tests passed")
end
