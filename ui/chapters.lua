-- Chapters of a WeRead book: loading the catalog, listing it, opening a chapter
-- (cached or freshly downloaded), and what happens when one is finished.
--
-- The catalog is not stored with the book record; it lives in an on-disk cache
-- written by lib/content.lua, so a book loaded from settings normally arrives
-- with book.chapters == nil and has to be filled in first — hence
-- ensureChaptersLoaded() and the cache-then-network path in loadChapters().
--
-- End-of-book handling hooks ReaderStatus:onEndOfBook while a WeRead book is
-- open (installed from onReaderReady, removed on close). The original handler is
-- always kept and restored, and is still used as the fallback whenever our own
-- dialog cannot be built.

local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template

local BookIndex = require("lib.book_index")
local Content = require("lib.content")
local EndOfBookDialog = require("ui.end_of_book_dialog")
local I18n = require("lib.i18n")
local Util = require("lib.util")

local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"

local log_error = Util.log_error
local display_error = Util.display_error

local Chapters = {}
Chapters.__index = Chapters

function Chapters:new(plugin)
    return setmetatable({
        plugin = plugin,
        settings = plugin.settings,
        client = plugin.client,
        ui_host = plugin.ui_host,
    }, self)
end

function Chapters:loadChapters(book, callback, force_refresh)
    if not force_refresh then
        if book.chapters and #book.chapters > 0 then
            callback(book.chapters)
            return
        end
        local cached = Content.load_catalog_cache(self.client, self.settings, book)
        if cached then
            callback(cached)
            return
        end
    end
    if not self.plugin.account:requireLogin(true, false) then
        return
    end
    self.ui_host:runOnlineTask(_("Loading chapter list..."), function()
        self.ui_host:showBusy(_("Loading chapter list..."))
        local ok, chapters_or_err = pcall(function()
            Content.ensure_reader_state(self.client, book)
            return Content.fetch_catalog(self.client, book)
        end)
        self.ui_host:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load chapters failed:", log_error(chapters_or_err))
            self.ui_host:showInfo(T(_("Load chapters failed:\n%1"), display_error(chapters_or_err)))
            return
        end
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters_or_err)
        if not cache_ok then
            logger.warn(LOG_MODULE, "save chapter catalog cache failed:", log_error(cache_err))
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        callback(chapters_or_err)
    end)
end

function Chapters:showChapterList(book)
    local menu
    local function buildItems(chapters)
        local items = {{
            text = "↻ " .. _("Refresh chapter list"),
            separator = true,
            callback = self.ui_host:safeCallback(_("Refresh chapter list"), function()
                self:loadChapters(book, function(refreshed_chapters)
                    if menu then
                        menu:switchItemTable(nil, buildItems(refreshed_chapters))
                    end
                    self.ui_host:showTransientInfo(T(_("Chapter list refreshed: %1 chapters"),
                        tostring(#refreshed_chapters)), 2)
                end, true)
            end),
        }}
        for _i, chapter in ipairs(chapters) do
            local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
            table.insert(items, {
                text = chapter.title or T(_("Chapter %1"), tostring(chapter.chapterUid)),
                post_text = cached and _("Cached") or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                callback = self.ui_host:safeCallback(chapter.title or _("Chapter"), function()
                    self:openChapter(book, chapter)
                end),
            })
        end
        return items
    end
    self:loadChapters(book, function(chapters)
        menu = self.ui_host:showList(book.title or _("Chapter list"), buildItems(chapters), _("No chapters."))
    end)
end

function Chapters:openCachedBook(book)
    self.ui_host:openFile(book.cached_file)
end

-- Open a chapter, preferring its cached file and falling back to a download.
function Chapters:openChapter(book, chapter)
    local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
    if cached then
        self.ui_host:openFile(cached)
    else
        self:downloadChapterAndRead(book, chapter)
    end
end

function Chapters:downloadChapterAndRead(book, chapter)
    self:confirmAndDownloadChapters(book, { chapter }, "chapter", {
        single_chapter = true,
    })
end

function Chapters:confirmDownloadAllChapters(book)
    self:loadChapters(book, function(chapters)
        self:confirmAndDownloadChapters(book, chapters, "full", {
            confirmation_text = T(_("Download all %1 chapters as one EPUB?"), tostring(#chapters)),
        })
    end)
end

-- Show the annotation cost warning consistently for every download entry.
-- With annotations disabled, single/partial downloads start immediately;
-- callers with their own confirmation text (the full-book action) keep only
-- that normal confirmation and do not show the annotation warning.
function Chapters:confirmAndDownloadChapters(book, chapters, suffix, options)
    options = options or {}
    local includes_annotations = self.settings:get("cache").download_underlines_and_thoughts == true
    local text = options.confirmation_text
    if includes_annotations then
        local warning = _("This download includes underlines and thoughts and may take significantly longer.")
        text = text and (text .. "\n\n" .. warning) or warning
    end
    if not text then
        self.plugin.downloader:start(book, chapters, suffix, options)
        return
    end

    local confirm
    confirm = ConfirmBox:new{
        text = text,
        ok_text = _("Download"),
        ok_callback = self.ui_host:safeCallback(_("Download"), function()
            UIManager:close(confirm)
            self.plugin.downloader:start(book, chapters, suffix, options)
        end),
        cancel_text = _("Close"),
    }
    UIManager:show(confirm)
end

-- Ensure the book's chapter catalog is available in memory. Since chapter lists
-- are no longer persisted with the book record (they live in a separate on-disk
-- catalog cache), a book loaded from settings usually has book.chapters == nil;
-- this loads it from the cache. Synchronous, no network. Returns the chapter
-- list, or nil if the cache is missing (e.g. the book was never opened/cached).
function Chapters:ensureChaptersLoaded(book)
    if not book then return nil end
    if not (type(book.chapters) == "table" and #book.chapters > 0) then
        Content.load_catalog_cache(self.client, self.settings, book)
    end
    return book.chapters
end

-- Take over ReaderStatus:onEndOfBook for the open WeRead book, keeping the
-- original handler for non-WeRead documents and as a fallback.
function Chapters:installEndOfBookHook()
    local ui = self.plugin.ui
    if not self._orig_onEndOfBook and ui.status and type(ui.status.onEndOfBook) == "function" then
        self._orig_onEndOfBook = ui.status.onEndOfBook
        ui.status.onEndOfBook = function(status_self)
            return self:handleEndOfBook(status_self)
        end
    end
end

function Chapters:removeEndOfBookHook()
    local ui = self.plugin.ui
    if self._orig_onEndOfBook and ui and ui.status then
        ui.status.onEndOfBook = self._orig_onEndOfBook
        self._orig_onEndOfBook = nil
    end
end

-- Intercepts ReaderStatus:onEndOfBook for WeRead books (installed as a hook in
-- onReaderReady). Non-WeRead books defer to the original handler. For WeRead
-- books, an end_document_action of "next_file" auto-advances to the next
-- chapter; every other action (pop-up, book_status, …) shows our own navigation
-- dialog instead of the native one, falling back to the native handler only
-- when the dialog cannot be built.
function Chapters:handleEndOfBook(status_self)
    local action = G_reader_settings and G_reader_settings:readSetting("end_document_action") or "pop-up"
    local book_id = self.plugin:detectWeReadBook()
    if not book_id then
        return self._orig_onEndOfBook(status_self)
    end

    local books = self.settings:get("books", {})
    local book = books[book_id]
    self:ensureChaptersLoaded(book)
    local file = self.plugin.ui.document and self.plugin.ui.document.file
    local current_idx, current_ch, is_full_book = BookIndex.chapter_info_from_file(book, file)
    local next_ch = (not is_full_book) and current_idx and book.chapters[current_idx + 1]

    if action == "next_file" then
        if next_ch then
            self:openChapter(book, next_ch)
        else
            self.ui_host:showInfo(_("You have reached the last chapter."))
        end
        return true
    end

    -- For every other end-of-document action, prefer our WeRead navigation
    -- dialog. This intentionally overrides the global end_document_action
    -- (pop-up, book_status, …) for WeRead books; fall back to the native
    -- handler only when the dialog cannot be built.
    if self:showEndOfBookDialog(book_id) then
        return true
    end

    return self._orig_onEndOfBook(status_self)
end

-- Returns true if the custom dialog was successfully displayed, or false if
-- the dialog could not be built (e.g., missing chapter info for MP articles),
-- allowing the caller to fall back to the native end-of-book handler.
function Chapters:showEndOfBookDialog(book_id)
    local file_path = self.plugin.ui.document and self.plugin.ui.document.file
    if not file_path then return false end

    local books = self.settings:get("books", {})
    local book = books[book_id]
    if not book or not self:ensureChaptersLoaded(book) then return false end

    local current_idx, current_ch, is_full_book = BookIndex.chapter_info_from_file(book, file_path)
    -- The chapter-nav row is shown only for single downloaded chapters (a mapped
    -- current chapter that is not part of a full-book EPUB); "next chapter"
    -- additionally requires a successor.
    local show_chapter_nav = current_idx ~= nil and not is_full_book
    local next_chapter = show_chapter_nav and book.chapters[current_idx + 1] or nil

    EndOfBookDialog.show({ show_chapter_nav = show_chapter_nav, has_next = next_chapter ~= nil }, {
        on_bookshelf = function()
            self.plugin.shelf:showBookshelf()
        end,
        on_search = function()
            self.plugin.shelf:showSearch()
        end,
        on_chapter_list = function()
            self:showChapterList(book)
        end,
        on_next = next_chapter and function()
            self:openChapter(book, next_chapter)
        end or nil,
        on_book_details = function()
            self.plugin.shelf:showCurrentBookDetails()
        end,
        on_read_stats = function()
            self.plugin.report_ui:showReadStats()
        end,
        on_close_book = function()
            -- Mirror KOReader's ReaderStatus:openFileBrowser(): closing the
            -- reader alone exits the app when there is no file-manager stack, so
            -- reopen the file browser right after (positioned on the book file).
            local ui = self.plugin.ui
            if not ui then return end
            local file = ui.document and ui.document.file
            ui:onClose()
            if file and ui.showFileManager then
                ui:showFileManager(file)
            end
        end,
    })
    return true
end

return Chapters
