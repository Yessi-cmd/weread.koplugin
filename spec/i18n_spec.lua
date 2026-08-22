-- Plugin language override remains independent from KOReader's global language.

package.path = "./?.lua;./?/init.lua;" .. package.path

local global_language = "en"
G_reader_settings = {
    readSetting = function(_self, key)
        if key == "language" then return global_language end
    end,
}

local I18n = require("weread.lib.i18n")
local checks = 0

local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

expect(I18n.tr("Settings") == "Settings",
    "automatic language should initially follow KOReader")
expect(I18n.set_language("zh") == "zh"
        and I18n.tr("Settings") == "设置"
        and I18n.tr("Upload progress while reading") == "阅读时定时上传进度"
        and I18n.tr("Smart restoration") == "智能还原",
    "Simplified Chinese override was not applied")
expect(I18n.set_language("en") == "en"
        and I18n.tr("Settings") == "Settings",
    "English override was not applied")
global_language = "zh_CN"
expect(I18n.set_language("auto") == "auto"
        and I18n.tr("Settings") == "设置",
    "automatic language did not return to KOReader")

print(("i18n_spec: %d checks"):format(checks))
