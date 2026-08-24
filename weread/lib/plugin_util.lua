local I18n = require("weread.lib.i18n")
local logger = require("weread.lib.logger")
local time = require("ui/time")
local T = require("ffi/util").template

local PluginUtil = {
    T = T,
    unpack_args = unpack or table.unpack,
}

function PluginUtil.tr(text)
    return I18n.tr(text)
end

function PluginUtil.set_language(language)
    return I18n.set_language(language)
end

function PluginUtil.log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

function PluginUtil.display_error(err)
    local text = tostring(err)
    local public_account_errors = {
        mp_credentials_expired = "The public-account credential expired. Scan the WeRead QR code again.",
        mp_verification_required = "WeRead requires a security verification. Complete it in WeRead or the WeRead web reader, then retry.",
        mp_risk_controlled = "WeRead temporarily limited public-account requests. Stop retrying for a while, then renew the cookie and try again.",
    }
    for token, message in pairs(public_account_errors) do
        if text:find(token, 1, true) then
            return I18n.tr(message)
        end
    end
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

function PluginUtil.file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

function PluginUtil.thought_perf(stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.dbg("thought_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed), ...)
end

return PluginUtil
