-- Focused tests for paginated chapter actions and visible multi-selection state.

package.path = "./?.lua;" .. package.path

local function empty_module() return {} end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = empty_module
package.preload["ui/widget/buttondialog"] = empty_module
package.preload["ui/widget/confirmbox"] = empty_module
package.preload["weread.lib.content"] = empty_module
package.preload["ui/widget/infomessage"] = empty_module
package.preload["ui/widget/inputdialog"] = empty_module
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["ui/widget/progressbardialog"] = empty_module
package.preload["ui/widget/textviewer"] = empty_module
package.preload["weread.lib.protocol"] = empty_module

local closed = 0
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
        close = function() closed = closed + 1 end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function() return false end,
    }
end

G_reader_settings = {
    readSetting = function(_self, key)
        return key == "items_per_page" and 5 or nil
    end,
}

local Library = require("weread.ui.library")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local chapters = {}
for index = 1, 7 do
    chapters[index] = {
        chapterUid = index,
        title = "Chapter " .. tostring(index),
        wordCount = index * 100,
    }
end

local shown = {}
local fake_menu = {
    updateItems = function() end,
    switchItemTable = function() end,
}
local downloaded_options
local returned_to_parent = false
local host = {
    safeCallback = function(_self, _label, callback) return callback end,
    loadChapters = function(_self, _book, callback) callback(chapters) end,
    showList = function(_self, title, items, _empty, options)
        shown[#shown + 1] = { title = title, items = items, options = options }
        return fake_menu
    end,
    confirmAndDownloadChapters = function(_self, _book, _targets, _suffix, options)
        downloaded_options = options
    end,
    showTransientInfo = function() end,
    openChapter = function() end,
}
for key, value in pairs(Library) do
    if host[key] == nil then host[key] = value end
end

local book = { title = "Book", cached_chapters = {} }
host:showChapterList(book)
local chapter_menu = shown[1]
expect(chapter_menu.options.items_per_page == 5,
    "chapter menu uses the same fixed pagination size as its action layout")
for _, index in ipairs({ 1, 6, 11 }) do
    expect(chapter_menu.items[index].text == "[Action] Refresh chapter list",
        "refresh action is first on page at item " .. tostring(index))
    expect(chapter_menu.items[index + 1].text == "[Action] Select chapters to download",
        "selection action is second on page at item " .. tostring(index + 1))
end

host:showChapterDownloadSelection(book, chapters, function()
    returned_to_parent = true
end)
local selection_menu = shown[2]
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (0)",
    "selection page starts with a distinct download action")
expect(selection_menu.items[6].text_func() == "[Download] Selected chapters (0)",
    "download action repeats at the top of the second page")

selection_menu.items[2].callback()
expect(selection_menu.items[2].text_func():find("[✓]", 1, true) == 1,
    "selected chapter gets an explicit visible marker")
expect(selection_menu.items[2].mandatory_func() == "Selected",
    "selected chapter gets a visible right-side status")
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (1)",
    "download action count updates after selection")

selection_menu.items[2].callback()
expect(selection_menu.items[2].text_func():find("[  ]", 1, true) == 1,
    "tapping a selected chapter removes its marker")
expect(selection_menu.items[1].text_func() == "[Download] Selected chapters (0)",
    "download action count decreases after deselection")
selection_menu.items[2].callback()

selection_menu.items[1].callback()
expect(downloaded_options and downloaded_options.separate_chapters == true,
    "multi-selection starts a separate-chapter download")
downloaded_options.on_complete(true)
expect(closed == 1 and returned_to_parent,
    "successful multi-download closes selection and returns to parent list")

print(string.format(
    "chapter_list_ui_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
