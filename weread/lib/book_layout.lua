-- EPUB layout normalization shared by single-chapter and full-book downloads.
-- It deliberately works from catalog metadata and chapter structure instead
-- of book-specific rules, so newly encountered books get the same fallbacks.

local BookLayout = {}

BookLayout.MODE_SMART = "smart"
BookLayout.MODE_ORIGINAL = "original"
BookLayout.MODE_CLEAN = "clean"

local VALID_MODES = {
    [BookLayout.MODE_SMART] = true,
    [BookLayout.MODE_ORIGINAL] = true,
    [BookLayout.MODE_CLEAN] = true,
}

local DEFAULT_CSS = [[
body { line-height: 1.7; margin: 5%; }
img { max-width: 100%; height: auto; }
]]

local SMART_CSS = [[
img, svg { max-width: 100%; height: auto; }
figure { max-width: 100%; margin: 1.5em auto; text-align: center; }
figcaption { margin-top: 0.6em; font-size: 0.88em; text-align: center; }
body.wr-chapter-image { text-align: center; }
body.wr-chapter-image img,
body.wr-chapter-image svg { display: block; margin: 0 auto; page-break-inside: avoid; }
.wr-generated-chapter-heading {
    display: block !important;
    visibility: visible !important;
    opacity: 1 !important;
    height: auto !important;
    max-height: none !important;
    overflow: visible !important;
    position: static !important;
    margin: 2.5em 0 5em;
    padding: 0;
    page-break-after: avoid;
    break-after: avoid;
}
.wr-generated-chapter-heading h1,
.wr-generated-chapter-heading h2,
.wr-generated-chapter-heading h3,
.wr-generated-chapter-heading h4,
.wr-generated-chapter-heading h5,
.wr-generated-chapter-heading h6 {
    display: block !important;
    visibility: visible !important;
    opacity: 1 !important;
    height: auto !important;
    margin: 0;
    padding: 0;
    font-size: 1.35em;
    font-weight: normal;
    line-height: 1.4;
    text-align: left;
}
]]

local CLEAN_CSS = [[
body.wr-mode-clean { line-height: 1.75; margin: 5%; }
body.wr-mode-clean p { margin: 0.85em 0; text-align: justify; }
body.wr-mode-clean blockquote { margin: 1.2em 1.5em; }
body.wr-mode-clean figure { margin: 1.8em auto; }
body.wr-mode-clean .wr-generated-chapter-heading { margin-top: 2.5em; margin-bottom: 5em; }
]]

local function html_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub('"', "&quot;")
    return value
end

local function body_contents(xhtml)
    xhtml = tostring(xhtml or "")
    local bodies = {}
    local pattern = "<[bB][oO][dD][yY][^>]*>(.-)</[bB][oO][dD][yY]>"
    for body in xhtml:gmatch(pattern) do
        bodies[#bodies + 1] = body
    end
    if #bodies > 0 then return table.concat(bodies, "\n") end
    xhtml = xhtml:gsub("<%?xml.-%?>", "")
    xhtml = xhtml:gsub("<![dD][oO][cC][tT][yY][pP][eE][^>]*>", "")
    xhtml = xhtml:gsub("<[hH][eE][aA][dD][^>]*>.-</[hH][eE][aA][dD]>", "")
    xhtml = xhtml:gsub("</?[hH][tT][mM][lL][^>]*>", "")
    xhtml = xhtml:gsub("</?[bB][oO][dD][yY][^>]*>", "")
    return xhtml
end

-- Downloaded chapter markup is third-party input. KOReader normally does not
-- execute EPUB JavaScript, but stripping active content here also protects any
-- other EPUB reader the generated file may later be opened with.
function BookLayout.sanitize_body(body)
    body = tostring(body or "")
    for _, tag in ipairs({ "script", "iframe", "object" }) do
        local chars = {}
        for index = 1, #tag do
            local char = tag:sub(index, index)
            chars[#chars + 1] = "[" .. char:lower() .. char:upper() .. "]"
        end
        local pattern = table.concat(chars)
        body = body:gsub("<%s*" .. pattern .. "[^>]*>.-</%s*" .. pattern .. "%s*>", "")
        body = body:gsub("<%s*" .. pattern .. "[^>]*/%s*>", "")
        body = body:gsub("<%s*" .. pattern .. "[^>]*>.*$", "")
    end
    body = body:gsub("<%s*[eE][mM][bB][eE][dD][^>]*>", "")
    body = body:gsub("</%s*[eE][mM][bB][eE][dD]%s*>", "")

    -- Remove quoted and unquoted event-handler attributes from HTML and SVG.
    body = body:gsub("%s+[oO][nN][%w_:%-]+%s*=%s*(['\"]).-%1", "")
    body = body:gsub("%s+[oO][nN][%w_:%-]+%s*=%s*[^%s>]+", "")

    local function neutralize_url(prefix, quote, value)
        local scheme = value:gsub("^[%s%c]+", ""):lower()
        if scheme:match("^javascript%s*:") or scheme:match("^vbscript%s*:")
            or scheme:match("^file%s*:")
            or scheme:match("^data%s*:%s*text/html")
            or scheme:match("^data%s*:%s*application/xhtml%+xml") then
            return prefix .. quote .. "#" .. quote
        end
        return prefix .. quote .. value .. quote
    end
    for _, attribute in ipairs({ "href", "src", "xlink:href", "formaction" }) do
        local attr_pattern = attribute:gsub("([%a])", function(char)
            return "[" .. char:lower() .. char:upper() .. "]"
        end)
        body = body:gsub("(%s+" .. attr_pattern .. "%s*=%s*)(['\"])(.-)%2",
            neutralize_url)
        body = body:gsub("(%s+" .. attr_pattern .. "%s*=%s*)([^%s>]+)",
            function(prefix, value)
                local scheme = value:gsub("^[%s%c]+", ""):lower()
                if scheme:match("^javascript%s*:") or scheme:match("^vbscript%s*:")
                    or scheme:match("^file%s*:") then
                    return prefix .. "#"
                end
                return prefix .. value
            end)
    end

    -- XML 1.0 only permits tab, LF and CR among C0 control characters.
    body = body:gsub("[%z\1-\8\11\12\14-\31]", "")
    return body
end

function BookLayout.extract_body(xhtml)
    return body_contents(xhtml)
end

local function plain_text(value)
    value = body_contents(value)
    value = value:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]>", "")
    value = value:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]>", "")
    value = value:gsub("<[^>]+>", " ")
    value = value:gsub("&nbsp;", " ")
    value = value:gsub("&#160;", " ")
    value = value:gsub("&lt;", "<"):gsub("&gt;", ">")
    value = value:gsub("&amp;", "&"):gsub("&quot;", '"')
    return value
end

local function compact_text(value)
    value = plain_text(value):lower()
    value = value:gsub("[%s%c%p]", "")
    value = value:gsub("[，。！？；：、“”‘’（）《》〈〉【】〔〕…—·]", "")
    return value
end

local function utf8_length(value)
    local _clean, continuation_bytes = tostring(value or ""):gsub("[\128-\191]", "")
    return #tostring(value or "") - continuation_bytes
end

local function image_count(xhtml)
    local body = body_contents(xhtml)
    local count = 0
    for _tag in body:gmatch("<%s*[iI][mM][gG][%s/>]") do count = count + 1 end
    for _tag in body:gmatch("<%s*[sS][vV][gG][%s/>]") do count = count + 1 end
    for _tag in body:gmatch("<%s*[iI][mM][aA][gG][eE][%s/>]") do count = count + 1 end
    return count
end

function BookLayout.normalize_mode(mode)
    mode = tostring(mode or ""):lower()
    if VALID_MODES[mode] then return mode end
    return BookLayout.MODE_SMART
end

function BookLayout.mode(settings)
    local cache = settings and type(settings.get) == "function"
        and settings:get("cache", {}) or {}
    return BookLayout.normalize_mode(cache and cache.book_layout_mode)
end

local function catalog_title(chapter)
    local title = tostring(chapter and chapter.title or "")
    return title:match("^%s*(.-)%s*$") or ""
end

local function chapter_ordinal(chapter, position, total)
    local uid = tonumber(chapter and (chapter.chapterUid or chapter.chapterId))
    if uid and uid == position and uid == math.floor(uid) then
        return uid
    end
    local value = tonumber(chapter and chapter.chapterIdx)
    if not value or value < 1 or value ~= math.floor(value) then
        value = tonumber(chapter and (chapter.chapterUid or chapter.chapterId))
    end
    -- WeRead chapter UIDs are sometimes large opaque numbers. Only use a UID
    -- that plausibly represents an ordinal; otherwise use the catalog position.
    if not value or value < 1 or value ~= math.floor(value)
        or value > math.max(20, (tonumber(total) or 0) * 4) then
        value = position
    end
    return math.floor(value)
end

function BookLayout.prepare_chapters(chapters, mode)
    mode = BookLayout.normalize_mode(mode)
    chapters = type(chapters) == "table" and chapters or {}
    local untitled = 0
    for _index, chapter in ipairs(chapters) do
        if catalog_title(chapter) == "" then untitled = untitled + 1 end
    end
    -- Some WeRead EPUB catalogs omit every numbered chapter title and leave
    -- the App to render "第N章" from its index. Infer that convention only when
    -- blank titles dominate the catalog, so an isolated malformed chapter in
    -- an otherwise named book is not assigned a misleading number.
    local infer_numbered_titles = mode ~= BookLayout.MODE_ORIGINAL
        and untitled >= 2 and untitled * 2 >= #chapters
    local prepared = {}
    for index, chapter in ipairs(chapters) do
        local copy = {}
        for key, value in pairs(chapter) do copy[key] = value end
        if infer_numbered_titles and catalog_title(copy) == "" then
            copy.title = "第" .. tostring(
                chapter_ordinal(copy, index, #chapters)) .. "章"
            copy._wr_inferred_title = true
        end
        prepared[index] = copy
    end
    return prepared
end

function BookLayout.prepare_chapter(chapter, catalog, mode)
    local prepared = BookLayout.prepare_chapters(catalog, mode)
    local wanted = tostring(chapter and
        (chapter.chapterUid or chapter.chapterId) or "")
    for index, candidate in ipairs(prepared) do
        local candidate_id = tostring(
            candidate.chapterUid or candidate.chapterId or "")
        if candidate == chapter or (wanted ~= "" and candidate_id == wanted) then
            return candidate
        end
    end
    local copy = {}
    for key, value in pairs(chapter or {}) do copy[key] = value end
    return copy
end

function BookLayout.classify_chapter(xhtml)
    xhtml = BookLayout.sanitize_body(xhtml)
    local images = image_count(xhtml)
    if images == 0 then return "text" end
    local text_length = utf8_length(compact_text(xhtml))
    if text_length <= math.max(24, images * 16) then return "image" end
    return "illustrated"
end

function BookLayout.classify_book(chapters, chapter_bodies)
    local counts = { text = 0, illustrated = 0, image = 0 }
    local total = 0
    for chapter_index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        local kind = BookLayout.classify_chapter(
            type(chapter_bodies) == "table" and chapter_bodies[uid] or "")
        counts[kind] = counts[kind] + 1
        total = total + 1
    end
    if total > 0 and counts.image * 2 >= total then return "image" end
    if counts.image > 0 or counts.illustrated > 0 then return "illustrated" end
    return "text"
end

local function heading_is_hidden(attributes)
    local attrs = tostring(attributes or ""):lower()
    if attrs:match("%s+hidden[%s=>]")
        or attrs:match("aria%-hidden%s*=%s*['\"]?true")
        or attrs:match("display%s*:%s*none")
        or attrs:match("visibility%s*:%s*hidden")
        or attrs:match([=[opacity%s*:%s*0[%s;'"]]=]) then
        return true
    end
    local classes = attrs:match('class%s*=%s*"([^"]*)"')
        or attrs:match("class%s*=%s*'([^']*)'") or ""
    classes = " " .. classes:gsub("%s+", " ") .. " "
    return classes:find(" hidden ", 1, true) ~= nil
        or classes:find(" visually-hidden ", 1, true) ~= nil
        or classes:find(" sr-only ", 1, true) ~= nil
end

function BookLayout.has_visible_title(xhtml, title)
    local expected = compact_text(title)
    if expected == "" then return false end
    local body = body_contents(xhtml)

    -- A decoded WeRead chapter may contain a title shell whose text is present
    -- in the DOM but hidden by the chapter stylesheet. Treat only an opening,
    -- visible semantic heading as an existing title; otherwise smart mode must
    -- add its own guaranteed-visible heading.
    for level = 1, 6 do
        local cursor = 1
        local pattern = "<[hH]" .. tostring(level)
            .. "([^>]*)>(.-)</[hH]" .. tostring(level) .. "%s*>"
        while true do
            local start_pos, end_pos, attributes, contents =
                body:find(pattern, cursor)
            if not start_pos then break end
            local preceding = compact_text(body:sub(1, start_pos - 1))
            if preceding == "" and not heading_is_hidden(attributes) then
                local heading = compact_text(contents)
                if heading:sub(1, #expected) == expected then
                    return true
                end
            end
            cursor = end_pos + 1
        end
    end
    return false
end

local function heading_level(chapter)
    local level = tonumber(chapter and chapter.level) or 1
    if level < 1 then return 1 end
    if level > 6 then return 6 end
    return math.floor(level)
end

function BookLayout.prepare_body(body, chapter, mode)
    mode = BookLayout.normalize_mode(mode)
    body = BookLayout.sanitize_body(body)
    local kind = BookLayout.classify_chapter(body)
    local title = tostring(chapter and chapter.title or "")
    local should_add_title = mode ~= BookLayout.MODE_ORIGINAL
        and kind ~= "image"
        and title ~= ""
        and not BookLayout.has_visible_title(body, title)
    if not should_add_title then
        return body, kind, false
    end
    local level = heading_level(chapter)
    local heading = '<header class="wr-generated-chapter-heading">'
        .. '<h' .. tostring(level) .. '>' .. html_escape(title)
        .. '</h' .. tostring(level) .. '></header>\n'
    return heading .. tostring(body or ""), kind, true
end

function BookLayout.body_classes(mode, book_kind, chapter_kind)
    return table.concat({
        "wr-mode-" .. BookLayout.normalize_mode(mode),
        "wr-book-" .. tostring(book_kind or "text"),
        "wr-chapter-" .. tostring(chapter_kind or "text"),
    }, " ")
end

function BookLayout.sanitize_css(css)
    css = tostring(css or "")
    css = css:gsub("@[iI][mM][pP][oO][rR][tT][^;{}]*;", "")
    css = css:gsub("[eE][xX][pP][rR][eE][sS][sS][iI][oO][nN]%s*%b()", "none")
    css = css:gsub("%-[mM][oO][zZ]%-[bB][iI][nN][dD][iI][nN][gG]%s*:[^;}]+", "")
    css = css:gsub("[bB][eE][hH][aA][vV][iI][oO][rR]%s*:[^;}]+", "")
    css = css:gsub("url%s*%((.-)%)", function(raw)
        local value = raw:match("^%s*(.-)%s*$") or raw
        local first = value:sub(1, 1)
        if (first == '"' or first == "'") and value:sub(-1) == first then
            value = value:sub(2, -2)
        end
        local lower = value:gsub("^[%s%c]+", ""):lower()
        if lower:match("^javascript%s*:") or lower:match("^vbscript%s*:")
            or lower:match("^file%s*:")
            or lower:match("^data%s*:%s*text/html")
            or lower:match("^data%s*:%s*application/xhtml%+xml") then
            return 'url("")'
        end
        return "url(" .. raw .. ")"
    end)
    return css:gsub("[%z\1-\8\11\12\14-\31]", "")
end

function BookLayout.compose_css(css, mode)
    mode = BookLayout.normalize_mode(mode)
    css = BookLayout.sanitize_css(css)
    if css == "" then css = DEFAULT_CSS end
    if mode == BookLayout.MODE_ORIGINAL then return css end
    css = css .. "\n" .. SMART_CSS
    if mode == BookLayout.MODE_CLEAN then
        css = css .. "\n" .. CLEAN_CSS
    end
    return css
end

return BookLayout
