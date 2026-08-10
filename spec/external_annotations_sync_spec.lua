package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        setDirty = function() end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        fetch_catalog = function()
            return {
                { chapterUid = "chapter-1" },
                { chapterUid = "chapter-2" },
                { chapterUid = "chapter-3" },
            }
        end,
    }
end
local located_chapters
package.preload["weread.lib.external_annotations"] = function()
    return {
        locate = function(_document, chapters)
            located_chapters = chapters
            return { { pos0 = "xp0", pos1 = "xp1" } },
                { located = #chapters, total = #chapters }
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end }
end
package.preload["weread.ui.xpointer_overlay"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.thoughts"] = function()
    return {
        collect_ranges = function(underlines)
            local ranges = {}
            for _, row in ipairs(underlines.underlines or {}) do
                ranges[#ranges + 1] = row.range
            end
            return ranges
        end,
    }
end

local dialogs = {}
package.preload["weread.ui.download_dialog"] = function()
    local Dialog = {}
    function Dialog:new(options)
        options.show = function() end
        options.close = function(current) current.closed = true end
        options.setTitle = function(current, title) current.title = title end
        options.reportProgress = function(current, value) current.progress = value end
        dialogs[#dialogs + 1] = options
        return options
    end
    return Dialog
end

local document_value = {
    binding = { book_id = "book-1", title = "Book", author = "Author" },
    records = {},
}
local checkpoint
local database = {
    getDocument = function() return document_value end,
    getSyncCheckpoint = function() return checkpoint end,
    replaceSyncCheckpoint = function(_self, _path, value)
        checkpoint = value
        checkpoint.chapters = {}
        return true
    end,
    saveSyncChapter = function(_self, _path, position, uid, value)
        value.position = position
        value.chapter_uid = uid
        checkpoint.chapters[#checkpoint.chapters + 1] = value
        return true
    end,
    saveDocument = function(_self, _path, value)
        document_value = value
        return true
    end,
    clearSyncCheckpoint = function()
        checkpoint = nil
        return true
    end,
}

local underline_calls = {}
local client = {
    get_chapter_underlines = function(_self, _book_id, uid)
        underline_calls[#underline_calls + 1] = uid
        return true, { underlines = { { range = uid .. "-range", markText = uid } } }
    end,
    get_chapter_reviews = function(_self, _book_id, uid)
        return true, { reviews = { { range = uid .. "-range", pageReviews = {} } } }
    end,
}

local info, transient
local host = {
    ui = { document = { file = "/books/local.epub" } },
    settings = {},
    client = client,
    external_annotations_db = database,
    requireLogin = function() return true end,
    runOnlineTask = function(_self, _label, callback) callback(); return true end,
    showInfo = function(_self, text) info = text end,
    showTransientInfo = function(_self, text) transient = text end,
}
local Controller = require("weread.ui.xpointer_overlay_controller")
for name, method in pairs(Controller) do host[name] = method end

local function run_one()
    local callback = table.remove(scheduled, 1)
    expect(callback ~= nil, "expected a scheduled sync step")
    callback()
end
local function run_all()
    while #scheduled > 0 do run_one() end
end

host:syncExternalAnnotations()
run_one() -- prepare catalog
run_one() -- download chapter 1 underlines
run_one() -- download chapter 1 thoughts and checkpoint it
dialogs[1].buttons[1][1].callback()
run_all()
expect(transient and transient:find("saved", 1, true),
    "cancelling did not explain that the checkpoint was retained")
expect(#underline_calls == 1 and underline_calls[1] == "chapter-1",
    "cancellation downloaded another chapter")
expect(checkpoint and #checkpoint.chapters == 1,
    "cancellation discarded the completed chapter checkpoint")

host:syncExternalAnnotations()
run_all()
expect(#underline_calls == 3
        and underline_calls[2] == "chapter-2"
        and underline_calls[3] == "chapter-3",
    "resume did not skip the completed chapter")
expect(located_chapters and #located_chapters == 3,
    "final matching did not include resumed and newly downloaded chapters")
expect(checkpoint == nil, "successful sync retained its temporary checkpoint")
expect(document_value.records and #document_value.records == 1,
    "successful sync did not save final projected records")
expect(info and info:find("Sync completed", 1, true),
    "successful resumed sync did not report completion")

print(("external_annotations_sync_spec: %d checks"):format(checks))
