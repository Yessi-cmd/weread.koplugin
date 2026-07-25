-- Reading-time reporting and reading statistics, from the user's side.
--
-- The reporting state machine itself is lib/read_report.lua; this module is its
-- control surface: the menu that enables it, picks between auto-association and
-- a manually chosen target book, and shows what the reporter is doing. Reading
-- statistics are here too because they are the other read-side view of the same
-- data (fetched by lib/read_stats.lua, drawn by ui/read_stats_view.lua).

local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template

local I18n = require("lib.i18n")
local ReadStats = require("lib.read_stats")
local ReadStatsView = require("ui.read_stats_view")
local Util = require("lib.util")
local WeRead = require("lib.weread")

local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"

local log_error = Util.log_error
local display_error = Util.display_error

local ReportUI = {}
ReportUI.__index = ReportUI

function ReportUI:new(plugin)
    return setmetatable({
        plugin = plugin,
        settings = plugin.settings,
        client = plugin.client,
        ui_host = plugin.ui_host,
    }, self)
end

function ReportUI:maybeStartReadReport()
    return self.plugin.read_report:maybe_start("menu")
end

function ReportUI:stopReadReport(reason)
    self.plugin.read_report:stop(reason or "explicit_stop")
end

function ReportUI:getReadReportMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Enable reading time report"),
            checked_func = function()
                return self.settings:get("read_report").enabled
            end,
            callback = self.ui_host:safeCallback(_("Enable reading time report"), function()
                local cur = self.settings:get("read_report")
                cur.enabled = not cur.enabled
                self.settings:set("read_report", cur)
                self.settings:flush()
                if cur.enabled then
                    if cur.mode == "auto" then
                        self:maybeStartReadReport()
                    elseif cur.book_id == "" then
                        self.ui_host:showTransientInfo(_("Please select a target book"), 2)
                        self:showReadReportBookPicker()
                    else
                        self:maybeStartReadReport()
                    end
                else
                    self:stopReadReport()
                end
            end),
        },
        {
            text = _("Only report when reading"),
            checked_func = function()
                return self.settings:get("read_report").report_on_open ~= false
            end,
            callback = self.ui_host:safeCallback(_("Only report when reading"), function()
                local cur = self.settings:get("read_report")
                cur.report_on_open = cur.report_on_open == false
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:stopReadReport("trigger_mode_changed")
                if cur.enabled then
                    self:maybeStartReadReport()
                end
            end),
        },
        {
            text_func = function()
                local current = self.settings:get("read_report")
                if current.mode == "manual" and current.book_title ~= "" then
                    return _("Select target book") .. " · " .. current.book_title
                end
                return _("Select target book")
            end,
            post_text = rr.mode == "auto" and _("Auto-associate") or nil,
            sub_item_table_func = function()
                return self:getReportTargetMenuItems()
            end,
        },
        {
            text = _("Report status"),
            keep_menu_open = true,
            callback = self.ui_host:safeCallback(_("Report status"), function()
                local cur = self.settings:get("read_report")
                local report_status = self.plugin.read_report:status()
                local target
                if cur.mode == "auto" then
                    local auto_title = report_status.target_book_title
                    target = auto_title and T(_("Auto: %1"), auto_title) or _("Auto-associate")
                else
                    target = cur.book_title ~= "" and cur.book_title or _("Not configured")
                end
                local status = report_status.running and _("Running") or _("Stopped")
                local count = report_status.count
                local last = report_status.last_time
                    and os.date("%H:%M:%S", report_status.last_time) or "--"
                local err = report_status.last_error or ""
                local msg = T(_("Report book: %1\nStatus: %2"), target, status)
                    .. "\n" .. T(_("Reported: %1 times, last: %2"), tostring(count), last)
                if err ~= "" then
                    msg = msg .. "\n" .. T(_("Last error: %1"), err)
                end
                self.ui_host:showInfo(msg)
            end),
        },
    }
end

function ReportUI:getReportTargetMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Auto-associate with WeRead book"),
            checked_func = function()
                return self.settings:get("read_report").mode == "auto"
            end,
            callback = self.ui_host:safeCallback(_("Auto-associate with WeRead book"), function()
                local cur = self.settings:get("read_report")
                cur.mode = "auto"
                cur.book_id = ""
                cur.book_title = ""
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:stopReadReport("target_changed")
                if cur.enabled then
                    self:maybeStartReadReport()
                end
            end),
        },
        {
            text = _("Manually set report book"),
            checked_func = function()
                return self.settings:get("read_report").mode == "manual"
            end,
            post_text = rr.mode == "manual" and rr.book_title ~= "" and rr.book_title or "",
            callback = self.ui_host:safeCallback(_("Manually set report book"), function()
                local cur = self.settings:get("read_report")
                cur.mode = "manual"
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:stopReadReport("target_changed")
                self:showReadReportBookPicker()
            end),
        },
    }
end

function ReportUI:showReadReportBookPicker()
    if not self.plugin.account:requireLogin(true, true) then
        return
    end
    self.ui_host:showBusy(_("Loading bookshelf..."))
    self.ui_host:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/shelf/sync", {})
        end)
        if not ok then
            self.ui_host:closeBusy()
            logger.err(LOG_MODULE, "load report bookshelf failed:", log_error(result))
            self.ui_host:showInfo(T(_("Load bookshelf failed:\n%1"), display_error(result)))
            return
        end
        self.ui_host:closeBusy()
        local all_books = result.books or {}
        local items = {}
        for i, book in ipairs(all_books) do
            if not WeRead.is_mp_book(book.bookId) then
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    callback = self.ui_host:safeCallback(book.title or _("Select target book"), function()
                        local rr = self.settings:get("read_report")
                        rr.book_id = book.bookId
                        rr.book_title = book.title or book.bookId
                        self.settings:set("read_report", rr)
                        self.settings:flush()
                        self:stopReadReport("target_changed")
                        if self._picker_menu then
                            UIManager:close(self._picker_menu)
                            self._picker_menu = nil
                        end
                        self.ui_host:showTransientInfo(T(_("Target book set: %1"), rr.book_title))
                        self:maybeStartReadReport()
                    end),
                })
            end
        end
        if not items or #items == 0 then
            self.ui_host:showInfo(_("Your WeRead shelf is empty."))
            return
        end
        self._picker_menu = Menu:new{
            title = _("Select a book to report reading time"),
            item_table = items,
            is_borderless = true,
            title_bar_fm_style = true,
        }
        UIManager:show(self._picker_menu)
    end)
end

function ReportUI:showReadStats()
    if not self.plugin.account:requireLogin(false, true) then
        return
    end
    -- Open on the monthly tab by default.
    self:loadReadStats("monthly", nil, nil)
end

-- Fetch reading statistics for a period and (re)show the visualization page.
-- old_view, when provided, is closed once the new data is ready (tab switch or
-- period navigation).
function ReportUI:loadReadStats(mode, base_time, old_view)
    self.ui_host:showBusy(_("Loading reading statistics..."))
    self.ui_host:runOnlineTask(_("Reading statistics"), function()
        local ok, data = pcall(function()
            return ReadStats.fetch(self.client, mode, base_time)
        end)
        self.ui_host:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load reading statistics failed:", log_error(data))
            self.ui_host:showInfo(T(_("%1 failed:\n%2"), _("Reading statistics"), display_error(data)))
            return
        end
        if old_view then
            UIManager:close(old_view)
        end
        local view
        view = ReadStatsView.show(data, {
            on_prev = function()
                self:loadReadStats(mode, data.prev_base_time, view)
            end,
            on_next = function()
                self:loadReadStats(mode, data.next_base_time, view)
            end,
            on_switch = function(new_mode)
                self:loadReadStats(new_mode, nil, view)
            end,
        })
    end)
end

return ReportUI
