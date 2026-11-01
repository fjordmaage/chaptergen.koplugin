--[[--
Pure-Lua helpers to flatten the table-of-contents hierarchy inside an EPUB.

Some EPUBs nest their chapters below "Part"/"Book" entries in the TOC
(depth 2+). Several readers (and some KOReader configurations) only use
top-level TOC entries for progress-bar chapter ticks and chapter
navigation, so almost all chapters go missing. Flattening the navMap
(EPUB 2 NCX) and/or the toc nav (EPUB 3 nav document) promotes every
entry to the top level, in reading order.

This module has no KOReader dependencies so it can be unit-tested with
any plain Lua interpreter.
]]

local EpubToc = {}

--- Decode %XX escapes in a URL/href.
function EpubToc.urldecode(s)
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

--- Normalize a zip-internal path: resolve "." and "..".
function EpubToc.normalizePath(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

--- Directory part of a zip-internal path (nil when in the root).
function EpubToc.dirname(path)
    return path:match("^(.*)/[^/]-$")
end

--- Join a base directory and a relative href, normalized.
function EpubToc.joinPath(dir, rel)
    if not dir or dir == "" then
        return EpubToc.normalizePath(rel)
    end
    return EpubToc.normalizePath(dir .. "/" .. rel)
end

-- Match attr="value" or attr='value' inside a single tag string.
local function getAttr(tag, name)
    name = name:gsub("%-", "%%-")
    return tag:match("%f[%w]" .. name .. [[%s*=%s*"([^"]*)"]])
        or tag:match("%f[%w]" .. name .. [[%s*=%s*'([^']*)']])
end

--- Find the OPF (package document) path in META-INF/container.xml.
function EpubToc.findOpfPath(container_xml)
    for tag in container_xml:gmatch("<rootfile%s[^>]->") do
        local path = getAttr(tag, "full-path")
        if path then
            return path
        end
    end
end

--- Find TOC document hrefs in the OPF manifest.
-- @return ncx_href (EPUB 2), nav_href (EPUB 3), either may be nil
function EpubToc.findTocHrefs(opf)
    local ncx_href, nav_href
    local spine_toc
    local spine_tag = opf:match("<spine%s[^>]->")
    if spine_tag then
        spine_toc = getAttr(spine_tag, "toc")
    end
    local ncx_by_id
    for tag in opf:gmatch("<item%s[^>]->") do
        local href = getAttr(tag, "href")
        if href then
            if not ncx_href and getAttr(tag, "media-type") == "application/x-dtbncx+xml" then
                ncx_href = href
            end
            if not ncx_by_id and spine_toc and getAttr(tag, "id") == spine_toc then
                ncx_by_id = href
            end
            if not nav_href then
                local props = getAttr(tag, "properties")
                if props and (" " .. props .. " "):find(" nav ", 1, true) then
                    nav_href = href
                end
            end
        end
    end
    return ncx_href or ncx_by_id, nav_href
end

--- Parse the navPoints of an NCX navMap body into a flat, ordered list.
-- @return entries: array of {label=, src=, depth=}, and the max depth seen
function EpubToc.parseNcxNavPoints(body)
    local entries = {}
    local depth, max_depth = 0, 0
    local pos = 1
    while true do
        local open_s, open_e = body:find("<navPoint[^>]*>", pos)
        local close_s, close_e = body:find("</navPoint%s*>", pos)
        local is_open
        if open_s and (not close_s or open_s < close_s) then
            is_open = true
        elseif close_s then
            is_open = false
        else
            break
        end
        if is_open then
            depth = depth + 1
            if depth > max_depth then
                max_depth = depth
            end
            -- navLabel/content come before any child navPoint, so look only
            -- at the segment up to the next navPoint token.
            local n1 = body:find("<navPoint[^>]*>", open_e + 1)
            local n2 = body:find("</navPoint%s*>", open_e + 1)
            local seg_end = #body
            if n1 and (not n2 or n1 < n2) then
                seg_end = n1 - 1
            elseif n2 then
                seg_end = n2 - 1
            end
            local seg = body:sub(open_e + 1, seg_end)
            local label = seg:match("<text[^>]*>(.-)</text%s*>")
            local content_tag = seg:match("<content%s[^>]->")
            local src = content_tag and getAttr(content_tag, "src")
            if src then
                entries[#entries + 1] = { label = label or "", src = src, depth = depth }
            end
            pos = open_e + 1
        else
            if depth > 0 then
                depth = depth - 1
            end
            pos = close_e + 1
        end
    end
    return entries, max_depth
end

--- Flatten the navMap of an EPUB 2 NCX document.
-- @return new NCX content and {entries=n, max_depth=d} on success;
--         nil and an error string otherwise ("already_flat" when nothing to do)
function EpubToc.flattenNcx(content)
    local map_s, map_tag_e = content:find("<navMap[^>]*>")
    if not map_s then
        return nil, "no <navMap> found"
    end
    local close_s, close_e = content:find("</navMap%s*>", map_tag_e)
    if not close_s then
        return nil, "no </navMap> found"
    end
    local body = content:sub(map_tag_e + 1, close_s - 1)
    local entries, max_depth = EpubToc.parseNcxNavPoints(body)
    if #entries == 0 then
        return nil, "no TOC entries found"
    end
    if max_depth <= 1 then
        return nil, "already_flat"
    end
    local out = {}
    for i, entry in ipairs(entries) do
        out[#out + 1] = string.format([[    <navPoint id="navPoint-%d" playOrder="%d">
      <navLabel>
        <text>%s</text>
      </navLabel>
      <content src="%s"/>
    </navPoint>]], i, i, entry.label, entry.src)
    end
    local new_content = content:sub(1, map_s - 1)
        .. "<navMap>\n" .. table.concat(out, "\n") .. "\n  </navMap>"
        .. content:sub(close_e + 1)
    -- The declared depth is now 1.
    new_content = new_content:gsub("<meta%s[^>]-dtb:depth[^>]->",
        [[<meta name="dtb:depth" content="1"/>]], 1)
    return new_content, { entries = #entries, max_depth = max_depth }
end

--- Flatten the toc <nav> element of an EPUB 3 navigation document.
-- @return new content and {entries=n} on success;
--         nil and an error string otherwise ("already_flat" when nothing to do)
function EpubToc.flattenNav(content)
    local nav_s, nav_tag_e = content:find("<nav[^>]-type%s*=%s*[\"']toc[\"'][^>]*>")
    if not nav_s then
        return nil, "no toc <nav> found"
    end
    local close_s = content:find("</nav%s*>", nav_tag_e)
    if not close_s then
        return nil, "no </nav> found"
    end
    local body = content:sub(nav_tag_e + 1, close_s - 1)
    local _, ol_count = body:gsub("<ol[%s>]", "")
    if ol_count <= 1 then
        return nil, "already_flat"
    end
    local heading = body:match("^%s*(<h%d[^>]*>.-</h%d%s*>)")
    local entries = {}
    for attrs, label in body:gmatch("<a%s([^>]-)>(.-)</a%s*>") do
        local href = getAttr("<a " .. attrs .. ">", "href")
        if href then
            label = label:gsub("<[^>]->", "") -- strip inner markup
            entries[#entries + 1] = { src = href, label = label }
        end
    end
    if #entries == 0 then
        return nil, "no TOC entries found"
    end
    local out = {}
    for _, entry in ipairs(entries) do
        out[#out + 1] = string.format('      <li><a href="%s">%s</a></li>', entry.src, entry.label)
    end
    local new_body = "\n"
    if heading then
        new_body = new_body .. "    " .. heading .. "\n"
    end
    new_body = new_body .. "    <ol>\n" .. table.concat(out, "\n") .. "\n    </ol>\n  "
    local new_content = content:sub(1, nav_tag_e) .. new_body .. content:sub(close_s)
    return new_content, { entries = #entries }
end

return EpubToc
