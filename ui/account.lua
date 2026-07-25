-- WeRead account state: the login gate every online feature calls first, plus
-- the status / renew / clear actions behind the account menu.
--
-- The QR login protocol itself lives in ui/qr_login.lua; this module only
-- decides when to start it and reports what credentials are configured.

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template

local I18n = require("lib.i18n")

local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"

local Account = {}
Account.__index = Account

function Account:new(plugin)
    return setmetatable({
        plugin = plugin,
        settings = plugin.settings,
        client = plugin.client,
        ui_host = plugin.ui_host,
    }, self)
end

-- Gate for every feature that needs credentials. Returns true when the required
-- credentials are present; otherwise it starts the QR login flow and returns
-- false so the caller aborts.
function Account:requireLogin(require_cookie, require_api_key)
    local missing_cookie = require_cookie and not self.settings:is_cookie_configured()
    local missing_api_key = require_api_key and not self.settings:is_api_configured()
    if not missing_cookie and not missing_api_key then
        return true
    end
    self.ui_host:showTransientInfo(_("Please scan the QR code to log in first."), 2)
    UIManager:scheduleIn(0.2, function()
        self.plugin.qr_login:start()
    end)
    return false
end

function Account:renewCookieWithUI()
    if not self:requireLogin(true, false) then
        return
    end
    self.ui_host:runNetworkAction(_("Renew cookie"), function()
        self.client:renew_cookie()
        logger.info(LOG_MODULE, "cookie renewed")
        return _("WeRead cookie renewed.")
    end)
end

function Account:showAccountStatus()
    local account = self.settings:get("account", {})
    local account_name = type(account.name) == "string" and account.name or ""
    if account_name == "" then
        account_name = (self.settings:is_cookie_configured() or self.settings:is_api_configured())
            and _("Unknown account") or _("Not logged in")
    end
    local login_method = account.login_method == "qr" and _("QR login") or _("Unknown")
    local cookie_status = self.settings:is_cookie_configured() and _("configured") or _("missing")
    local api_status = self.settings:is_api_configured() and _("configured") or _("missing")
    self.ui_host:showInfo(T(
        _("Account: %1\nLogin method: %2\nCookie: %3\nOfficial API key: %4\nCache directory:\n%5"),
        account_name,
        login_method,
        cookie_status,
        api_status,
        BD.dirpath(self.settings.cache_dir)
    ))
end

function Account:confirmClearAccount()
    UIManager:show(ConfirmBox:new{
        text = _("Clear WeRead cookie and API key? Cached books will remain."),
        ok_text = _("Clear"),
        ok_callback = self.ui_host:safeCallback(_("Clear"), function()
            self.plugin.qr_login:cancel()
            self.plugin.read_report:stop("account_cleared")
            self.settings:reset_account()
            self.ui_host:refreshLoginMenu()
            self.ui_host:showInfo(_("WeRead account data cleared."))
        end),
    })
end

return Account
