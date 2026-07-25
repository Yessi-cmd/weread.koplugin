-- Underlines and thoughts inside an open WeRead book: showing or hiding the
-- marks baked into the cached EPUB, and turning a tap on an underline into a
-- thought popup.
--
-- Download and embedding happen elsewhere (lib/downloader.lua → lib/thoughts.lua
-- → lib/annotations.lua); by the time this module runs, the EPUB already carries
-- .wr-underline spans and #wrthought-… anchors. See
-- docs/weread-annotations-flow.md for the whole pipeline.
--
-- Three things here are subtle and easy to break:
--   * Visibility is applied as an appended stylesheet, never by editing the file.
--     The initial hidden state must be set from onReadSettings, before KOReader
--     renders: doing it from onReaderReady starts a partial rerender whose
--     seamless reload builds a new plugin instance and rerenders again, forever.
--   * crengine ignores CSS pointer-events when hit-testing links, so hiding the
--     marks is not enough — getLinkFromGes is wrapped to make our anchors
--     invisible to ReaderLink while annotations are off, letting the tap fall
--     through to a normal page turn.
--   * Everything scheduled for later carries the session generation. It is
--     bumped on every reader-ready and close, so a popup or highlight-clear
--     belonging to a previous book can never act on the current one.

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local Annotations = require("lib.annotations")
local Content = require("lib.content")
local I18n = require("lib.i18n")
local ThoughtDB = require("lib.thought_db")
local ThoughtPopup = require("ui.thought_popup")
local Thoughts = require("lib.thoughts")

local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"

-- Hard ceilings for the per-session thought caches (both cleared on book close).
-- On overflow the whole map is dropped; the next tap simply re-renders / re-reads.
local THOUGHT_HTML_CACHE_MAX = 300  -- distinct tapped underlines
local THOUGHT_JSON_CACHE_MAX = 10   -- distinct chapters with thoughts

-- Runtime CSS that hides underlines and thought stars baked into cached EPUBs.
-- Applied as an appended stylesheet (not persisted to the book sidecar) so it
-- acts as a global display preference without mutating downloaded files.
-- NOTE: only tweak visual/metric properties (border, padding, font-size). Never
-- use display/white-space here — changing those marks the built DOM stale and
-- makes ReaderRolling repeatedly prompt for a full document reload.
local ANNOTATION_HIDE_CSS =
    ".wr-underline{border-bottom:0 !important;padding-bottom:0 !important;} .wr-star{font-size:0 !important;} "
    .. ".wr-thought-link{pointer-events:none !important;text-decoration:none !important;color:inherit !important;}"

local function thought_perf(stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.dbg(LOG_MODULE, "thought_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed), ...)
end

local AnnotationsUI = {}
AnnotationsUI.__index = AnnotationsUI

function AnnotationsUI:new(plugin)
    return setmetatable({
        plugin = plugin,
        settings = plugin.settings,
        ui_host = plugin.ui_host,
        _reader_session_gen = 0,
    }, self)
end

-- Whether the user wants underlines and thoughts shown (the default).
function AnnotationsUI:isVisible()
    return self.settings:get("cache").show_annotations ~= false
end

-- Apply the initial hidden state before KOReader renders the document. Doing
-- this from onReaderReady starts partial rerendering; its seamless reload then
-- creates a new plugin instance and repeats the same rerender forever.
function AnnotationsUI:applyInitialVisibility()
    local ui = self.plugin.ui
    if not ui or not ui.document or not self.plugin:detectWeReadBook() then
        return
    end
    if self:isVisible() then
        return
    end
    local typeset = ui.typeset
    if not typeset or not typeset.css then
        logger.warn(LOG_MODULE, "onReadSettings: typeset stylesheet unavailable")
        return
    end
    local tweaks = ""
    local styletweak = ui.styletweak
    if styletweak and type(styletweak.getCssText) == "function" then
        tweaks = styletweak:getCssText() or ""
    end
    local ok, err = pcall(function()
        ui.document:setStyleSheet(typeset.css, tweaks .. "\n" .. ANNOTATION_HIDE_CSS)
    end)
    if not ok then
        logger.warn(LOG_MODULE, "initial annotation visibility failed:", err)
    end
end

-- Reapply the current annotation visibility preference to the open WeRead book.
-- Show=true reapplies the base stylesheet + user tweaks (revealing baked-in
-- underlines); show=false appends ANNOTATION_HIDE_CSS on top. Triggers a reflow.
function AnnotationsUI:applyVisibility()
    local ui = self.plugin.ui
    if not ui or not ui.document then
        return
    end
    if not self.plugin:detectWeReadBook() then
        return
    end
    local typeset = ui.typeset
    if not typeset or not typeset.css then
        logger.warn(LOG_MODULE, "applyAnnotationVisibility: typeset stylesheet unavailable")
        return
    end
    local show = self:isVisible()
    local tweaks = ""
    local styletweak = ui.styletweak
    if styletweak and type(styletweak.getCssText) == "function" then
        tweaks = styletweak:getCssText() or ""
    end
    if not show then
        tweaks = tweaks .. "\n" .. ANNOTATION_HIDE_CSS
    end
    local ok, err = pcall(function()
        ui.document:setStyleSheet(typeset.css, tweaks)
        ui:handleEvent(Event:new("UpdatePos"))
    end)
    if not ok then
        logger.warn(LOG_MODULE, "applyAnnotationVisibility failed:", err)
    end
end

-- Close a popup that is on screen, e.g. right after the user hides annotations.
function AnnotationsUI:closePopup()
    ThoughtPopup.closeVisible()
    self._thought_popup_open = nil
end

-- Hide our thought anchors from KOReader's link hit-testing while annotations
-- are hidden. crengine ignores CSS pointer-events for link detection, so without
-- this a tap on a hidden underline is swallowed by ReaderLink (it follows the
-- #wrthought anchor, a same-page jump) instead of turning the page. Returning nil
-- makes ReaderLink's tap_link handler find no link and decline, so the tap falls
-- through to KOReader's native page-turn (honoring the user's tap zones / RTL).
-- Only our own anchors are hidden, and only while annotations are off.
function AnnotationsUI:_installLinkFilter()
    local ui = self.plugin.ui
    if not ui or not ui.link or self._orig_getLinkFromGes then
        return
    end
    self._orig_getLinkFromGes = ui.link.getLinkFromGes
    local controller = self
    ui.link.getLinkFromGes = function(link_self, ges)
        local link = controller._orig_getLinkFromGes(link_self, ges)
        if link and controller.settings:get("cache").show_annotations == false then
            local href = controller:_linkHref(link)
            if type(href) == "string" and href:find("wrthought%-") then
                return nil
            end
        end
        return link
    end
end

function AnnotationsUI:_removeLinkFilter()
    local ui = self.plugin.ui
    if self._orig_getLinkFromGes and ui and ui.link then
        ui.link.getLinkFromGes = self._orig_getLinkFromGes
    end
    self._orig_getLinkFromGes = nil
end

function AnnotationsUI:_teardownThoughtInterception()
    local ui = self.plugin.ui
    if self._thought_interception_setup and ui then
        ui:unRegisterTouchZones({
            { id = "weread_thought_tap", overrides = { "tap_link" } },
        })
        self._thought_interception_setup = nil
    end
    self:_removeLinkFilter()
    ThoughtPopup.closeVisible()
    ThoughtPopup.cancelPrewarm()
    self._thought_popup_open = nil
    self._current_thought_popup = nil
    self._thought_html_cache = nil
    self._thought_html_cache_n = nil
    self._thought_json_cache = nil
    self._thought_json_cache_n = nil
    self._thought_highlight_active = nil
    self._current_weread_book_id = nil
end

function AnnotationsUI:_setupThoughtInterception()
    local Device = require("device")
    if not Device:isTouchDevice() then
        return
    end
    local ui = self.plugin.ui
    if not ui or self._thought_interception_setup then
        return
    end

    ui:registerTouchZones({
        {
            id = "weread_thought_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "tap_link" },
            handler = function(ges)
                return self:_onThoughtTap(ges)
            end,
        },
    })
    self:_installLinkFilter()
    self._thought_interception_setup = true
end

-- Start a new reader session: invalidate anything scheduled by the previous one
-- and set up tap interception when the new document is a WeRead book.
function AnnotationsUI:onReaderReady(weread_book_id)
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()

    -- Cache it so the per-tap handler (_onThoughtTap) does not have to re-scan
    -- the whole book table on every screen tap.
    self._current_weread_book_id = weread_book_id
    if not weread_book_id then
        return
    end

    -- Always register the tap interception: even when annotations are hidden
    -- we must intercept taps on thought links to suppress the native footnote
    -- popup. Visibility is decided inside _onThoughtTap / applyVisibility.
    self:_setupThoughtInterception()
    local show_annotations = self:isVisible()
    UIManager:nextTick(function()
        local ui = self.plugin.ui
        if not ui or not ui.document then
            return
        end
        if not show_annotations then
            return
        end
        local params = self:_getThoughtPopupLayoutParams()
        if not params then
            return
        end
        ThoughtPopup.preloadFonts(params.doc_font_name)
        ThoughtPopup.prewarm({
            doc_font_name = params.doc_font_name,
            doc_font_size = params.doc_font_size,
            doc_margins = params.doc_margins,
            height_ratio = params.height_ratio,
            dialog = self.plugin.dialog,
        })
    end)
end

function AnnotationsUI:onCloseDocument()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()
end

function AnnotationsUI:_clearThoughtHighlight(document)
    if not self._thought_highlight_active then
        return
    end
    pcall(function()
        document:highlightXPointer()
    end)
    self._thought_highlight_active = nil
    UIManager:setDirty(self.plugin.dialog, "ui")
end

function AnnotationsUI:_getThoughtPopupLayoutParams()
    local ui = self.plugin.ui
    if not ui or not ui.document then
        return nil
    end

    local Screen = require("device").screen
    local document = ui.document

    local font_face = ui.font and ui.font.font_face
    if not font_face then
        font_face = G_reader_settings:readSetting("cre_font")
    end

    local font_size = G_reader_settings:readSetting("footnote_popup_absolute_font_size")
    local font_size_scaled
    if font_size then
        font_size_scaled = Screen:scaleBySize(font_size)
    else
        local relative = G_reader_settings:readSetting("footnote_popup_relative_font_size") or -2
        local doc_font_size = (document.configurable and document.configurable.font_size) or 18
        font_size_scaled = Screen:scaleBySize(doc_font_size) + relative
    end

    return {
        doc_font_name = font_face,
        doc_font_size = font_size_scaled,
        doc_margins = document:getPageMargins(),
        height_ratio = 0.35,
    }
end

function AnnotationsUI:_showThoughtPopup(html, link, session_gen, tap_started)
    local show_started = time.now()
    if session_gen and session_gen ~= self._reader_session_gen then
        self._thought_popup_open = nil
        return
    end
    if type(html) ~= "string" or html == "" then
        self._thought_popup_open = nil
        return
    end

    local Screen = require("device").screen
    local document = self.plugin.ui.document
    if link.from_xpointer then
        local highlight_started = time.now()
        local ok = pcall(function()
            document:highlightXPointer()
            document:highlightXPointer(link.from_xpointer)
        end)
        thought_perf("highlight", highlight_started, "ok=", tostring(ok))
        if ok then
            self._thought_highlight_active = true
            UIManager:setDirty(self.plugin.dialog, "partial")
        end
    end

    local params_started = time.now()
    local params = self:_getThoughtPopupLayoutParams()
    thought_perf("layout_params", params_started)
    if not params then
        self._thought_popup_open = nil
        return
    end

    local fonts_started = time.now()
    ThoughtPopup.preloadFonts(params.doc_font_name)
    thought_perf("preload_fonts", fonts_started)

    local popup_started = time.now()
    local ok, popup = pcall(function()
        return ThoughtPopup.show({
            html = html,
            doc_font_name = params.doc_font_name,
            doc_font_size = params.doc_font_size,
            doc_margins = params.doc_margins,
            height_ratio = params.height_ratio,
            dialog = self.plugin.dialog,
            close_callback = function(footnote_height)
                self._thought_popup_open = nil
                self._current_thought_popup = nil
                if self._thought_highlight_active then
                    local highlight_page = document:getCurrentPage()
                    local clear_gen = self._reader_session_gen or 0
                    local clear_highlight = function()
                        if clear_gen ~= self._reader_session_gen then
                            return
                        end
                        document:highlightXPointer()
                        if document:getCurrentPage() == highlight_page then
                            UIManager:setDirty(self.plugin.dialog, "ui")
                        end
                    end
                    self._thought_highlight_active = nil
                    local footnote_top_y = Screen:getHeight() - footnote_height
                    if link.link_y and link.link_y > footnote_top_y then
                        UIManager:scheduleIn(0.5, clear_highlight)
                    else
                        clear_highlight()
                    end
                end
            end,
        })
    end)
    thought_perf("popup_show", popup_started, "ok=", tostring(ok),
        "html_bytes=", tostring(#html))

    if not ok then
        logger.warn(LOG_MODULE, "thought popup failed:", popup)
        self._thought_popup_open = nil
        self:_clearThoughtHighlight(document)
        return
    end

    self._current_thought_popup = popup
    thought_perf("show_pipeline", show_started, "html_bytes=", tostring(#html))
    if tap_started then
        thought_perf("tap_to_popup_return", tap_started, "html_bytes=", tostring(#html))
    end
end

-- Recursively pull a thought anchor href out of a KOReader link object.
-- The link's shape differs between engines and even between tap locations inside
-- the same anchor (tapping the star vs the underlined text can expose the href
-- under a different field), so scan common fields first, then a shallow crawl.
function AnnotationsUI:_linkHref(link)
    local seen = {}
    local function extract(value, depth)
        if depth > 4 or value == nil then
            return nil
        end
        if type(value) == "string" then
            return value:match("(#wrthought%-[%w%._%-]+)")
                or value:match("(wrthought%-[%w%._%-]+)")
        end
        if type(value) ~= "table" or seen[value] then
            return nil
        end
        seen[value] = true
        for _, key in ipairs({ "href", "url", "target", "link", "uri", "dest", "destination", "src" }) do
            local found = extract(value[key], depth + 1)
            if found then
                return found
            end
        end
        for _, child in pairs(value) do
            local found = extract(child, depth + 1)
            if found then
                return found
            end
        end
        return nil
    end
    return extract(link, 0)
end

-- Parse "#wrthought-<book>-<chapter>-<start>-<end>" into its parts. The last two
-- segments are numeric (range start/end); book/chapter must not contain dashes
-- (true for WeRead IDs in practice).
function AnnotationsUI:_parseThoughtHref(href)
    if type(href) ~= "string" then
        return nil
    end
    local anchor = href:match("#?(wrthought%-[%w%._%-]+)")
    if not anchor then
        return nil
    end
    local book_id, chapter_uid, start_pos, end_pos =
        anchor:match("^wrthought%-([^%-]+)%-([^%-]+)%-(%d+)%-(%d+)$")
    if not (book_id and chapter_uid and start_pos and end_pos) then
        logger.warn(LOG_MODULE, "unparseable thought anchor:", anchor)
        return nil
    end
    return {
        book_id = book_id,
        chapter_uid = chapter_uid,
        range = start_pos .. "-" .. end_pos,
    }
end

-- Load a chapter's cached thoughts, memoized per (book, chapter) so tapping
-- different underlines in the same chapter reads/decodes the JSON only once.
-- Returns the decoded reviews array, or false if the chapter has no cache.
function AnnotationsUI:_loadThoughtReviews(book_id, chapter_uid)
    self._thought_json_cache = self._thought_json_cache or {}
    local key = tostring(book_id) .. ":" .. tostring(chapter_uid)
    local cached = self._thought_json_cache[key]
    if cached ~= nil then
        return cached
    end
    local reviews = Thoughts.load_cache(self.settings, book_id, chapter_uid)
    if type(reviews) ~= "table" then
        reviews = false
    end
    self._thought_json_cache_n = (self._thought_json_cache_n or 0) + 1
    if self._thought_json_cache_n > THOUGHT_JSON_CACHE_MAX then
        self._thought_json_cache = {}
        self._thought_json_cache_n = 1
    end
    self._thought_json_cache[key] = reviews
    return reviews
end

-- Load the chapter's cached thoughts, match the tapped range, render popup HTML.
function AnnotationsUI:_buildThoughtHtmlFromHref(href)
    local info = self:_parseThoughtHref(href)
    if not info then
        return nil
    end

    -- 1. Try SQLite indexed lookup
    local books = self.settings:get("books", {})
    local book = books[info.book_id]
    if book then
        local book_dir = Content.book_resolved_dir(self.settings, info.book_id, book)
        local db = ThoughtDB.open(book_dir)
        if db then
            local sql_html = ThoughtDB.getReviewHTML(db, info.chapter_uid, info.range)
            ThoughtDB.close(db)
            if sql_html then
                return sql_html
            end
        end
    end

    -- 2. JSON fallback for legacy caches
    local reviews = self:_loadThoughtReviews(info.book_id, info.chapter_uid)
    if type(reviews) ~= "table" then
        self.ui_host:showInfo(_("Thought cache error. Please re-download this book with underlines and thoughts."))
        return nil
    end
    for _i, rv in ipairs(reviews) do
        if tostring(rv.range or "") == info.range then
            local html = Annotations.buildThoughtPopupHtml(rv)
            if type(html) == "string" and html ~= "" then
                return html
            end
            break
        end
    end
    self.ui_host:showInfo(_("No matching thought found for this underline."))
    return nil
end

function AnnotationsUI:_onThoughtTap(ges)
    local tap_started = time.now()
    local ui = self.plugin.ui
    if not ui or not ui.document or not ui.link then
        return false
    end
    -- The tap zone is only registered for WeRead books, so a cached flag is
    -- enough here; avoid re-scanning the book table on every tap.
    if not self._current_weread_book_id then
        return false
    end

    local link_started = time.now()
    local ok, link = pcall(function()
        return ui.link:getLinkFromGes(ges)
    end)
    thought_perf("link_lookup", link_started, "found=", tostring(ok and link ~= nil))
    -- No followable link here (e.g. hidden underline whose link is disabled via
    -- pointer-events:none) → return false so the tap falls through to KOReader's
    -- default page-turn, honoring the user's tap-zone / RTL settings.
    if not ok or not link then
        return false
    end

    local href = self:_linkHref(link)
    if type(href) ~= "string" or not href:find("wrthought%-") then
        -- Some other EPUB link (footnote, TOC, external) → let KOReader handle it.
        return false
    end

    -- Annotations hidden: _installLinkFilter already made getLinkFromGes return nil
    -- for our anchors, so we normally return above before reaching here. Kept as a
    -- defensive fall-through in case the filter is not active.
    if self.settings:get("cache").show_annotations == false then
        return false
    end

    -- Cache the rendered HTML by href (stable, page-independent).
    self._thought_html_cache = self._thought_html_cache or {}
    local html = self._thought_html_cache[href]
    if html == nil then
        -- SQLite lookup is sub-millisecond; JSON fallback is a single file read.
        -- No loading message needed.
        html = self:_buildThoughtHtmlFromHref(href) or false
        self._thought_html_cache_n = (self._thought_html_cache_n or 0) + 1
        if self._thought_html_cache_n > THOUGHT_HTML_CACHE_MAX then
            self._thought_html_cache = {}
            self._thought_html_cache_n = 1
        end
        self._thought_html_cache[href] = html
    end
    thought_perf("tap_resolve", tap_started, "cached=", tostring(html ~= nil),
        "html_bytes=", tostring(type(html) == "string" and #html or 0))
    if html == false or type(html) ~= "string" then
        -- Recognized our underline but have no content (already told the user why,
        -- e.g. deleted cache). Consume the tap so tap_link does not follow the
        -- now-pointless #wrthought anchor.
        return true
    end

    -- Guard against a stale flag: if we believe a popup is open but it is not
    -- actually on screen (e.g. it was closed through a path that skipped the
    -- close callback), reset instead of silently swallowing every tap forever.
    if self._thought_popup_open then
        if ThoughtPopup.isShowing() then
            return true
        end
        self._thought_popup_open = nil
    end
    self._thought_popup_open = true
    local session_gen = self._reader_session_gen or 0
    local scheduled_at = time.now()
    UIManager:nextTick(function()
        thought_perf("next_tick_delay", scheduled_at)
        if session_gen ~= self._reader_session_gen then
            self._thought_popup_open = nil
            return
        end
        if not self.plugin.ui or not self.plugin.ui.document then
            self._thought_popup_open = nil
            return
        end
        self:_showThoughtPopup(html, link, session_gen, tap_started)
    end)
    return true
end

return AnnotationsUI
