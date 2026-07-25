-- Reading-progress sync with WeRead (work in progress).
--
-- Only uploadCurrentProgress() has a live entry point today: the
-- `weread_sync_progress` Dispatcher action registered in main.lua. It is a
-- manual smoke test rather than real sync — it picks an arbitrary book record
-- and uploads whatever reading state was stored for it, with no mapping between
-- KOReader positions and WeRead chapter offsets. The "Sync progress now" menu
-- item is still greyed out for that reason.
--
-- pullProgress() and the reader-URL parser are the other half of the same
-- experiment and currently have no entry point: parsing a reader URL is how the
-- psvts / pclts / token values that an upload needs get seeded. They are kept
-- here so the whole unfinished feature lives in one place.

local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local I18n = require("lib.i18n")
local WeRead = require("lib.weread")

local function _(text)
    return I18n.tr(text)
end

local ProgressSync = {}
ProgressSync.__index = ProgressSync

function ProgressSync:new(plugin)
    return setmetatable({
        plugin = plugin,
        settings = plugin.settings,
        client = plugin.client,
        ui_host = plugin.ui_host,
    }, self)
end

function ProgressSync:uploadCurrentProgress()
    if not self.plugin.account:requireLogin(true, false) then
        return
    end
    local books = self.settings:get("books", {})
    local book_id, book
    for id, item in pairs(books) do
        book_id, book = id, item
        break
    end
    if not book_id then
        self.ui_host:showInfo(_("Parse a WeRead reader URL before testing progress sync."))
        return
    end
    local payload = WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid or 0,
        chapter_idx = book.chapter_idx or 0,
        chapter_offset = book.chapter_offset or 0,
        progress = book.progress or 0,
        summary = book.summary or "",
        app_id = book.app_id,
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
    }
    UIManager:show(ConfirmBox:new{
        text = T(_("Upload local progress to WeRead?\n\nBook: %1\nProgress: %2%%\nChapter offset: %3"), book.title or book_id, tostring(payload.pr), tostring(payload.co)),
        ok_text = _("Upload"),
        ok_callback = self.ui_host:safeCallback(_("Upload"), function()
            self.ui_host:runNetworkAction(_("Sync progress"), function()
                local result = self.client:report_read(payload, book.reader_url)
                if result and result.succ then
                    return _("WeRead progress synced.")
                end
                return _("Progress request sent, but response did not include succ=1.")
            end)
        end),
    })
end

function ProgressSync:pullProgress(book_id)
    if not self.plugin.account:requireLogin(true, true) then
        return
    end
    self.ui_host:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%"), tostring(progress))
    end)
end

function ProgressSync:showPasteReaderURL()
    local dialog
    dialog = InputDialog:new{
        title = _("Paste WeRead reader URL"),
        input = "https://weread.qq.com/web/reader/",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self.ui_host:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Parse"),
                    is_enter_default = true,
                    callback = self.ui_host:safeCallback(_("Parse"), function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        self:parseReaderURL(url)
                    end),
                },
            },
        },
    }
    self.ui_host:showInputDialog(dialog)
end

function ProgressSync:parseReaderURL(url)
    if not self.plugin.account:requireLogin(true, false) then
        return
    end
    self.ui_host:runNetworkAction(_("Parse reader URL"), function()
        local html = self.client:get_text(url, { referer = url })
        local book_id = html:match([["bookId"%s*:%s*"([^"]+)"]]) or html:match([["bookId"%s*:%s*(%d+)]])
        local title = html:match([["title"%s*:%s*"([^"]+)"]]) or _("Unknown title")
        local psvts = html:match([["psvts"%s*:%s*"([^"]+)"]])
        local pclts = html:match([["pclts"%s*:%s*"([^"]+)"]])
        local token = html:match([["token"%s*:%s*"([^"]+)"]])
        if not book_id then
            return _("Reader HTML loaded, but bookId was not found.")
        end
        local books = self.settings:get("books", {})
        local record = books[book_id] or {}
        record.book_id = book_id
        record.title = title
        record.reader_url = url
        record.psvts = psvts
        record.pclts = pclts
        record.token = token
        record.updated_at = os.time()
        books[book_id] = record
        self.settings:set("books", books)
        self.settings:flush()
        return T(_("Reader URL parsed.\nBook: %1\nbookId: %2"), title, book_id)
    end)
end

return ProgressSync
