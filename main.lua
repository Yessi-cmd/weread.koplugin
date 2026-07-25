local Dispatcher = require("dispatcher")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Account = require("lib.account")
local AnnotationsUI = require("lib.annotations_ui")
local BookIndex = require("lib.book_index")
local CacheAdmin = require("lib.cache_admin")
local Chapters = require("lib.chapters")
local Client = require("lib.client")
local Content = require("lib.content")
local Downloader = require("lib.downloader")
local I18n = require("lib.i18n")
local MPArticles = require("lib.mp_articles")
local PluginMenu = require("ui.menu")
local ProgressSync = require("lib.progress_sync")
local QRLogin = require("lib.qr_login")
local ReadReport = require("lib.read_report")
local ReportUI = require("lib.report_ui")
local Settings = require("lib.settings")
local Shelf = require("lib.shelf")
local UIHost = require("lib.ui_host")
local Util = require("lib.util")
local ThoughtPopup = require("ui.thought_popup")

-- `_` is the translation function; never reuse it as a loop placeholder in this file.
local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"

local log_error = Util.log_error

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = "0.1.1",
}

function WeReadPlugin:init()
    math.randomseed(os.time())
    self.settings = Settings:new()
    self.client = Client:new(self.settings)
    self.ui_host = UIHost:new(self)
    self.downloader = Downloader:new{
        client = self.client,
        settings = self.settings,
        show_info       = function(text) self.ui_host:showInfo(text) end,
        show_transient  = function(text, timeout) self.ui_host:showTransientInfo(text, timeout) end,
        refresh_ui      = function() self.ui_host:refreshUI() end,
        refresh_shelf   = function() self.shelf:refreshCacheIndicators() end,
        open_file       = function(path) self.ui_host:openFile(path) end,
        safe_callback   = function(label, fn) return self.ui_host:safeCallback(label, fn) end,
        require_login   = function(cookie, api_key) return self.account:requireLogin(cookie, api_key) end,
        run_online_task = function(label, fn) self.ui_host:runOnlineTask(label, fn) end,
    }
    self:migrateLegacyBookData()
    self.qr_login = QRLogin:new(self.ui_host, self.client, self.settings)
    self.read_report = ReadReport:new{
        settings = self.settings,
        client = self.client,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        -- The report tick runs on the UI loop; use the link-state check here
        -- because NetworkMgr:isOnline() does a blocking DNS lookup.
        is_online = function()
            return self.ui_host:isNetworkConnected()
        end,
    }
    self.account = Account:new(self)
    self.annotations = AnnotationsUI:new(self)
    self.cache_admin = CacheAdmin:new(self)
    self.chapters = Chapters:new(self)
    self.mp_articles = MPArticles:new(self)
    self.progress_sync = ProgressSync:new(self)
    self.report_ui = ReportUI:new(self)
    self.shelf = Shelf:new(self)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local read_report = self.settings:get("read_report")
    if read_report.enabled
        and read_report.mode == "manual"
        and read_report.book_id ~= ""
        and read_report.report_on_open == false then
        self.read_report:maybe_start("plugin_start")
    end
    ThoughtPopup.init()
    logger.info(LOG_MODULE, "initialized:", "version=", self.version)
end

function WeReadPlugin:migrateLegacyBookData()
    local books = self.settings:get("books", {})
    local found, migrated, failed = false, 0, 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and book.chapters ~= nil then
            found = true
            if type(book.chapters) == "table" then
                local ok, saved = pcall(Content.save_catalog_cache,
                    self.client, self.settings, book, book.chapters)
                if ok and saved then
                    migrated = migrated + 1
                else
                    failed = failed + 1
                end
            end
            book.chapters = nil
        end
    end
    if found or self.settings:has_legacy_book_records() then
        local ok, err = pcall(function()
            self.settings:set("books", books)
            self.settings:flush()
        end)
        if ok then
            logger.info(LOG_MODULE, "legacy per-book data migrated:",
                "catalogs=", tostring(migrated), "catalog_failures=", tostring(failed))
        else
            logger.err(LOG_MODULE, "legacy per-book data migration failed:", log_error(err))
        end
    end
end

function WeReadPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("weread_show", {
        category = "none",
        event = "ShowWeRead",
        title = _("WeRead"),
        filemanager = true,
        reader = true,
    })
    Dispatcher:registerAction("weread_sync_progress", {
        category = "none",
        event = "WeReadSyncProgress",
        title = _("Sync WeRead progress"),
        reader = true,
    })
end

function WeReadPlugin:addToMainMenu(menu_items)
    menu_items.weread = {
        text = _("WeRead"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return PluginMenu.mainItems(self)
        end,
    }
end

-- The book id of the currently open document, or nil when it is not WeRead
-- content. The matching itself lives in lib/book_index.lua; this only supplies
-- the plugin's settings and the book-directory resolver.
function WeReadPlugin:detectWeReadBook()
    if not self.ui.document then
        return nil
    end
    return BookIndex.detect_book_id{
        file = self.ui.document.file,
        books = self.settings:get("books", {}),
        cache_dir = self.settings.cache_dir,
        resolve_dir = function(book_id, book)
            return Content.book_resolved_dir(self.settings, book_id, book)
        end,
    }
end

function WeReadPlugin:onShowWeRead()
    self.account:showAccountStatus()
end

function WeReadPlugin:onWeReadSyncProgress()
    self.progress_sync:uploadCurrentProgress()
end

-- Fires before KOReader renders the document, which is the only safe moment to
-- apply the "annotations hidden" stylesheet (see lib/annotations_ui.lua).
function WeReadPlugin:onReadSettings()
    self.annotations:applyInitialVisibility()
end

function WeReadPlugin:onReaderReady()
    local weread_book_id = self:detectWeReadBook()
    self.annotations:onReaderReady(weread_book_id)
    if weread_book_id then
        self.chapters:installEndOfBookHook()
    else
        self.chapters:removeEndOfBookHook()
    end

    local _started, _title, reason = self.read_report:on_reader_ready()
    local rr = self.settings:get("read_report")
    if rr.enabled and rr.mode == "auto" and reason == "document_not_weread" then
        self.ui_host:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
    end
end

function WeReadPlugin:onCloseDocument()
    self.annotations:onCloseDocument()
    self.chapters:removeEndOfBookHook()
    self.read_report:on_close_document()
end

function WeReadPlugin:onSuspend()
    self.read_report:on_suspend()
end

function WeReadPlugin:onResume()
    self.read_report:on_resume()
end

function WeReadPlugin:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return WeReadPlugin
