-- The plugin's UI and network primitives: everything a feature controller needs
-- to talk to the user or to guard a network call, in one injected object.
--
-- Extracted from main.lua so controllers depend on this narrow surface instead
-- of the whole plugin. It is deliberately the exact interface lib/qr_login.lua
-- already expects from its `host`, so that module needs no changes.
--
-- Two error-reporting conventions are kept from the original code:
--   * every wrapper (safeCallback / runOnlineTask / runNetworkAction) closes the
--     busy message before reporting, so a thrown error can never leave an
--     undismissable InfoMessage on screen;
--   * the log gets the full message (Util.log_error) while the dialog gets only
--     the first line (Util.display_error).

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template

local I18n = require("lib.i18n")
local Util = require("lib.util")

local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"

local UIHost = {}
UIHost.__index = UIHost

-- `plugin` is the WeReadPlugin instance; only plugin.ui (KOReader's
-- ReaderUI/FileManager) is used, and always at call time since KOReader may
-- replace it during the plugin's lifetime.
function UIHost:new(plugin)
    return setmetatable({
        plugin = plugin,
    }, self)
end

-- Wrap a menu/button callback so a thrown error is logged and shown instead of
-- taking down the UI loop.
function UIHost:safeCallback(label, callback)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(Util.unpack(args))
        end, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "action failed:", label, Util.log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, Util.display_error(err)))
        end
    end
end

function UIHost:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function UIHost:showTransientInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

function UIHost:showBusy(text)
    self:closeBusy()
    self.busy_message = InfoMessage:new{
        text = text,
        dismissable = false,
    }
    UIManager:show(self.busy_message)
    self:refreshUI()
end

function UIHost:closeBusy()
    if self.busy_message then
        UIManager:close(self.busy_message)
        self.busy_message = nil
        self:refreshUI()
    end
end

function UIHost:refreshUI()
    if UIManager.forceRePaint then
        local ok, err = pcall(function()
            UIManager:forceRePaint()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "forceRePaint failed:", Util.log_error(err))
        end
    end
end

function UIHost:showInputDialog(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        local ok, err = pcall(function()
            dialog:onShowKeyboard()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "failed to show keyboard:", Util.log_error(err))
        end
    end
end

function UIHost:isNetworkOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isOnline then
        return true
    end
    local ok_online, online = pcall(function()
        return NetworkMgr:isOnline()
    end)
    if not ok_online then
        logger.warn(LOG_MODULE, "network status check failed:", Util.log_error(online))
        return true
    end
    return online == true
end

-- Non-blocking connectivity check (interface link state only). Unlike
-- isNetworkOnline() it never resolves DNS, so it is safe on the UI loop.
function UIHost:isNetworkConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isConnected then
        return self:isNetworkOnline()
    end
    local ok_connected, connected = pcall(function()
        return NetworkMgr:isConnected()
    end)
    if not ok_connected then
        logger.warn(LOG_MODULE, "network link check failed:", Util.log_error(connected))
        return true
    end
    return connected == true
end

function UIHost:showOffline(label)
    self:closeBusy()
    logger.warn(LOG_MODULE, "network unavailable:", label)
    self:showInfo(T(_("%1 failed:\n%2"), label, _("No network connection. Please connect Wi-Fi and try again.")))
end

function UIHost:runOnlineTask(label, callback, delay)
    if not self:isNetworkOnline() then
        self:showOffline(label)
        return false
    end
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "network task failed:", label, Util.log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, Util.display_error(err)))
        end
    end)
    return true
end

function UIHost:runNetworkAction(label, action)
    self:runOnlineTask(label, function()
        local ok, result = pcall(action)
        if ok then
            self:showInfo(result or label)
        else
            logger.err(LOG_MODULE, "network action failed:", label, Util.log_error(result))
            self:showInfo(T(_("%1 failed:\n%2"), label, Util.display_error(result)))
        end
    end)
end

function UIHost:showList(title, items, empty_text)
    if not items or #items == 0 then
        self:showInfo(empty_text or _("No items."))
        return
    end
    local menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
    return menu
end

-- Remember the touch-menu instance showing the login entry so the QR login flow
-- can refresh its label after logging in.
function UIHost:setLoginMenu(touchmenu_instance)
    self._login_menu_instance = touchmenu_instance
end

function UIHost:refreshLoginMenu()
    local menu = self._login_menu_instance
    if menu and type(menu.updateItems) == "function" then
        local ok, err = pcall(function()
            menu:updateItems()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "refresh login menu failed:", Util.log_error(err))
        end
    end
    self:refreshUI()
end

function UIHost:openFile(path)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    local ui = self.plugin.ui
    if ui.document then
        ui:switchDocument(path)
    else
        ui:openFile(path)
    end
end

return UIHost
