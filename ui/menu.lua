-- ui/menu.lua — the plugin's menu tree under KOReader's Tools menu.
--
-- Declaration only: every item reads or toggles a setting and otherwise hands
-- off to a controller on the plugin (plugin.shelf, plugin.account, ...). No
-- network, no book-store I/O, no dialogs beyond the confirmations that guard an
-- expensive setting.
--
-- When an item is added, removed, renamed or moved, keep this file, the
-- translations in lib/i18n.lua, and the menu tree in README.md in sync.

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template

local I18n = require("lib.i18n")

local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"

local M = {}

local function setMPImageDownload(plugin, enabled)
    local cache = plugin.settings:get("cache")
    cache.download_mp_images = enabled == true
    plugin.settings:set("cache", cache)
    plugin.settings:flush()
    logger.info(
        LOG_MODULE,
        "image download setting changed:",
        "target=mp",
        "enabled=", tostring(cache.download_mp_images)
    )
end

-- Items shown when the WeRead entry in the Tools menu is opened. The
-- document-only entries are inserted after the login row, so they sit at the top
-- while reading.
function M.mainItems(plugin)
    local settings = plugin.settings
    local ui_host = plugin.ui_host

    local items = {
        {
            text_func = function()
                local account = settings:get("account", {})
                if account.login_method == "qr" and tonumber(account.login_time or 0) > 0 then
                    local name = type(account.name) == "string" and account.name or ""
                    if name == "" then name = _("Unknown account") end
                    return T(_("Logged in · %1"), name)
                end
                return _("QR code login")
            end,
            keep_menu_open = true,
            callback = ui_host:safeCallback(_("QR login"), function(touchmenu_instance)
                ui_host:setLoginMenu(touchmenu_instance)
                local account = settings:get("account", {})
                if account.login_method == "qr" and tonumber(account.login_time or 0) > 0 then
                    plugin.account:showAccountStatus()
                else
                    plugin.qr_login:start()
                end
            end),
        },
        {
            text = _("Bookshelf"),
            callback = ui_host:safeCallback(_("Bookshelf"), function()
                plugin.shelf:showBookshelf()
            end),
        },
        {
            text = _("Search"),
            callback = ui_host:safeCallback(_("Search"), function()
                plugin.shelf:showSearch()
            end),
        },
        {
            text = _("Reading time report"),
            sub_item_table_func = function()
                if not plugin.account:requireLogin(true, true) then
                    return {}
                end
                return plugin.report_ui:getReadReportMenuItems()
            end,
        },
        {
            text = _("Reading statistics"),
            callback = ui_host:safeCallback(_("Reading statistics"), function()
                plugin.report_ui:showReadStats()
            end),
        },
        {
            text = _("Settings"),
            sub_item_table_func = function()
                return M.settingsItems(plugin)
            end,
        },
        {
            text = T(_("About (v%1)"), plugin.version),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nhttps://github.com/finlater/weread.koplugin"), plugin.version),
                })
            end,
        },
    }

    if plugin.ui.document then
        table.insert(items, 2, {
            text = _("Sync progress now") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 3, {
            text = _("Book details"),
            callback = ui_host:safeCallback(_("Book details"), function()
                plugin.shelf:showCurrentBookDetails()
            end),
        })
        table.insert(items, 4, {
            text = _("Show underlines and thoughts"),
            checked_func = function()
                return settings:get("cache").show_annotations ~= false
            end,
            keep_menu_open = true,
            callback = ui_host:safeCallback(_("Show underlines and thoughts"), function()
                local cache = settings:get("cache")
                cache.show_annotations = not (cache.show_annotations ~= false)
                settings:set("cache", cache)
                settings:flush()
                logger.info(
                    LOG_MODULE,
                    "annotation visibility changed:",
                    "show=", tostring(cache.show_annotations)
                )
                -- Keep the tap interception registered in both states; hiding is
                -- handled by _onThoughtTap. Just close any popup already showing.
                if not cache.show_annotations then
                    plugin.annotations:closePopup()
                end
                plugin.annotations:applyVisibility()
            end),
        })
    end

    return items
end

function M.settingsItems(plugin)
    local settings = plugin.settings
    local ui_host = plugin.ui_host

    return {
        {
            text = _("Cache management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Scan and match local books"),
                        callback = ui_host:safeCallback(_("Scan and match local books"), function()
                            plugin.cache_admin:confirmScanLocalCache()
                        end),
                    },
                    {
                        text = _("Cache cleanup"),
                        callback = ui_host:safeCallback(_("Cache cleanup"), function()
                            plugin.cache_admin:showCacheManagement()
                        end),
                    },
                    {
                        text_func = function()
                            return T(_("Cache directory: %1"), BD.dirpath(settings:get_download_dir()))
                        end,
                        keep_menu_open = true,
                        callback = ui_host:safeCallback(_("Cache directory"), function(touchmenu_instance)
                            plugin.cache_admin:showDownloadDirPicker(touchmenu_instance)
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
                            return settings:get("sync").pull_on_open
                        end,
                    },
                    {
                        text = _("Upload progress on close"),
                        enabled_func = function() return false end,
                        checked_func = function()
                            return settings:get("sync").upload_on_close
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
                            return settings:get("cache").download_book_images
                        end,
                        callback = ui_host:safeCallback(_("Book images"), function()
                            local cache = settings:get("cache")
                            cache.download_book_images = not cache.download_book_images
                            settings:set("cache", cache)
                            settings:flush()
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
                            return settings:get("cache").download_mp_images
                        end,
                        check_callback_updates_menu = true,
                        callback = ui_host:safeCallback(_("Public account article images"), function(touchmenu_instance)
                            local cache = settings:get("cache")
                            if cache.download_mp_images then
                                setMPImageDownload(plugin, false)
                                touchmenu_instance:updateItems()
                                return
                            end
                            UIManager:show(ConfirmBox:new{
                                text = _("Downloading public account article images may significantly increase download time. Continue?"),
                                ok_text = _("Confirm"),
                                ok_callback = ui_host:safeCallback(_("Confirm"), function()
                                    setMPImageDownload(plugin, true)
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
                            return settings:get("cache").download_underlines_and_thoughts
                        end,
                        callback = ui_host:safeCallback(_("Underlines and thoughts"), function(touchmenu_instance)
                            local cache = settings:get("cache")
                            if cache.download_underlines_and_thoughts then
                                cache.download_underlines_and_thoughts = false
                                settings:set("cache", cache)
                                settings:flush()
                                logger.info(LOG_MODULE,
                                    "underlines/thoughts download setting changed:", "enabled=", "false")
                                touchmenu_instance:updateItems()
                                return
                            end
                            UIManager:show(ConfirmBox:new{
                                text = _("Downloading underlines and thoughts adds requests for every chapter and may significantly increase download time and cache usage. Continue?"),
                                ok_text = _("Confirm"),
                                ok_callback = ui_host:safeCallback(_("Confirm"), function()
                                    cache.download_underlines_and_thoughts = true
                                    settings:set("cache", cache)
                                    settings:flush()
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
                        callback = ui_host:safeCallback(_("Account status"), function()
                            plugin.account:showAccountStatus()
                        end),
                    },
                    {
                        text = _("Renew cookie now"),
                        keep_menu_open = true,
                        callback = ui_host:safeCallback(_("Renew cookie now"), function()
                            plugin.account:renewCookieWithUI()
                        end),
                    },
                    {
                        text = _("Clear account data"),
                        keep_menu_open = true,
                        callback = ui_host:safeCallback(_("Clear account data"), function()
                            plugin.account:confirmClearAccount()
                        end),
                    },
                }
            end,
        },
    }
end

return M
