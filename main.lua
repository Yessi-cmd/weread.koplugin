local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template

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
            return self:getMainMenuItems()
        end,
    }
end

function WeReadPlugin:getMainMenuItems()
    local items = {
        {
            text_func = function()
                local account = self.settings:get("account", {})
                if account.login_method == "qr" and tonumber(account.login_time or 0) > 0 then
                    local name = type(account.name) == "string" and account.name or ""
                    if name == "" then name = _("Unknown account") end
                    return T(_("Logged in · %1"), name)
                end
                return _("QR code login")
            end,
            keep_menu_open = true,
            callback = self.ui_host:safeCallback(_("QR login"), function(touchmenu_instance)
                self.ui_host:setLoginMenu(touchmenu_instance)
                local account = self.settings:get("account", {})
                if account.login_method == "qr" and tonumber(account.login_time or 0) > 0 then
                    self.account:showAccountStatus()
                else
                    self.qr_login:start()
                end
            end),
        },
        {
            text = _("Bookshelf"),
            callback = self.ui_host:safeCallback(_("Bookshelf"), function()
                self.shelf:showBookshelf()
            end),
        },
        {
            text = _("Search"),
            callback = self.ui_host:safeCallback(_("Search"), function()
                self.shelf:showSearch()
            end),
        },
        {
            text = _("Reading time report"),
            sub_item_table_func = function()
                if not self.account:requireLogin(true, true) then
                    return {}
                end
                return self.report_ui:getReadReportMenuItems()
            end,
        },
        {
            text = _("Reading statistics"),
            callback = self.ui_host:safeCallback(_("Reading statistics"), function()
                self.report_ui:showReadStats()
            end),
        },
        {
            text = _("Settings"),
            sub_item_table_func = function()
                return self:getSettingsMenuItems()
            end,
        },
        {
            text = T(_("About (v%1)"), self.version),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nhttps://github.com/finlater/weread.koplugin"), self.version),
                })
            end,
        },
    }

    if self.ui.document then
        table.insert(items, 2, {
            text = _("Sync progress now") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 3, {
            text = _("Book details"),
            callback = self.ui_host:safeCallback(_("Book details"), function()
                self.shelf:showCurrentBookDetails()
            end),
        })
        table.insert(items, 4, {
            text = _("Show underlines and thoughts"),
            checked_func = function()
                return self.settings:get("cache").show_annotations ~= false
            end,
            keep_menu_open = true,
            callback = self.ui_host:safeCallback(_("Show underlines and thoughts"), function()
                local cache = self.settings:get("cache")
                cache.show_annotations = not (cache.show_annotations ~= false)
                self.settings:set("cache", cache)
                self.settings:flush()
                logger.info(
                    LOG_MODULE,
                    "annotation visibility changed:",
                    "show=", tostring(cache.show_annotations)
                )
                -- Keep the tap interception registered in both states; hiding is
                -- handled by _onThoughtTap. Just close any popup already showing.
                if not cache.show_annotations then
                    self.annotations:closePopup()
                end
                self.annotations:applyVisibility()
            end),
        })
    end

    return items
end

function WeReadPlugin:getSettingsMenuItems()
    return {
        {
            text = _("Cache management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Scan and match local books"),
                        callback = self.ui_host:safeCallback(_("Scan and match local books"), function()
                            self.cache_admin:confirmScanLocalCache()
                        end),
                    },
                    {
                        text = _("Cache cleanup"),
                        callback = self.ui_host:safeCallback(_("Cache cleanup"), function()
                            self.cache_admin:showCacheManagement()
                        end),
                    },
                    {
                        text_func = function()
                            return T(_("Cache directory: %1"), BD.dirpath(self.settings:get_download_dir()))
                        end,
                        keep_menu_open = true,
                        callback = self.ui_host:safeCallback(_("Cache directory"), function(touchmenu_instance)
                            self.cache_admin:showDownloadDirPicker(touchmenu_instance)
                        end),
                    },
                }
            end,
        },
        {
            text = _("Progress management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Pull progress on open"),
                        enabled_func = function() return false end,
                        checked_func = function()
                            return self.settings:get("sync").pull_on_open
                        end,
                    },
                    {
                        text = _("Upload progress on close"),
                        enabled_func = function() return false end,
                        checked_func = function()
                            return self.settings:get("sync").upload_on_close
                        end,
                    },
                }
            end,
        },
        {
            text = _("Download content"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Book images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:get("cache").download_book_images
                        end,
                        callback = self.ui_host:safeCallback(_("Book images"), function()
                            local cache = self.settings:get("cache")
                            cache.download_book_images = not cache.download_book_images
                            self.settings:set("cache", cache)
                            self.settings:flush()
                            logger.info(
                                LOG_MODULE,
                                "image download setting changed:",
                                "target=book",
                                "enabled=", tostring(cache.download_book_images)
                            )
                        end),
                    },
                    {
                        text = _("Public account article images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:get("cache").download_mp_images
                        end,
                        check_callback_updates_menu = true,
                        callback = self.ui_host:safeCallback(_("Public account article images"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            if cache.download_mp_images then
                                self:setMPImageDownload(false)
                                touchmenu_instance:updateItems()
                                return
                            end
                            UIManager:show(ConfirmBox:new{
                                text = _("Downloading public account article images may significantly increase download time. Continue?"),
                                ok_text = _("Confirm"),
                                ok_callback = self.ui_host:safeCallback(_("Confirm"), function()
                                    self:setMPImageDownload(true)
                                    touchmenu_instance:updateItems()
                                end),
                                cancel_text = _("Cancel"),
                            })
                        end),
                    },
                    {
                        text = _("Underlines and thoughts"),
                        keep_menu_open = true,
                        check_callback_updates_menu = true,
                        checked_func = function()
                            return self.settings:get("cache").download_underlines_and_thoughts
                        end,
                        callback = self.ui_host:safeCallback(_("Underlines and thoughts"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            if cache.download_underlines_and_thoughts then
                                cache.download_underlines_and_thoughts = false
                                self.settings:set("cache", cache)
                                self.settings:flush()
                                logger.info(LOG_MODULE,
                                    "underlines/thoughts download setting changed:", "enabled=", "false")
                                touchmenu_instance:updateItems()
                                return
                            end
                            UIManager:show(ConfirmBox:new{
                                text = _("Downloading underlines and thoughts adds requests for every chapter and may significantly increase download time and cache usage. Continue?"),
                                ok_text = _("Confirm"),
                                ok_callback = self.ui_host:safeCallback(_("Confirm"), function()
                                    cache.download_underlines_and_thoughts = true
                                    self.settings:set("cache", cache)
                                    self.settings:flush()
                                    logger.info(LOG_MODULE,
                                        "underlines/thoughts download setting changed:", "enabled=", "true")
                                    touchmenu_instance:updateItems()
                                end),
                                cancel_text = _("Cancel"),
                            })
                        end),
                    },
                }
            end,
        },
        {
            text = _("Account management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Account status"),
                        callback = self.ui_host:safeCallback(_("Account status"), function()
                            self.account:showAccountStatus()
                        end),
                    },
                    {
                        text = _("Renew cookie now"),
                        keep_menu_open = true,
                        callback = self.ui_host:safeCallback(_("Renew cookie now"), function()
                            self.account:renewCookieWithUI()
                        end),
                    },
                    {
                        text = _("Clear account data"),
                        keep_menu_open = true,
                        callback = self.ui_host:safeCallback(_("Clear account data"), function()
                            self.account:confirmClearAccount()
                        end),
                    },
                }
            end,
        },
    }
end

function WeReadPlugin:setMPImageDownload(enabled)
    local cache = self.settings:get("cache")
    cache.download_mp_images = enabled == true
    self.settings:set("cache", cache)
    self.settings:flush()
    logger.info(
        LOG_MODULE,
        "image download setting changed:",
        "target=mp",
        "enabled=", tostring(cache.download_mp_images)
    )
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
