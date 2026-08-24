local I18n = require("weread.lib.i18n")

local function _(text)
    return I18n.tr(text)
end

return {
    fullname = _("weread-yessi"),
    description = _([[Read WeRead books in KOReader, cache chapters, and sync reading progress.]]),
    version = "1.3.0",
    private_build = true,
}
