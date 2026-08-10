package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local encoded, next_payload = {}, 0
package.preload["json"] = function()
    return {
        encode = function(value)
            next_payload = next_payload + 1
            local key = "payload-" .. next_payload
            encoded[key] = value
            return key
        end,
        decode = function(value) return encoded[value] end,
    }
end

local files = { ["/data/weread"] = true }
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path) return files[path] and "file" or nil end,
        mkdir = function(path) files[path] = true; return true end,
    }
end

local databases = {}
local fail_open
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function(path)
            if fail_open and path:find(fail_open, 1, true) then error("open failed") end
            files[path] = true
            databases[path] = databases[path] or {
                documents = {}, sync_chapters = {},
            }
            local data = databases[path]
            local db = {}
            db.exec = function(_db, sql)
                if sql:find("DELETE FROM sync_chapters", 1, true) then
                    data.sync_chapters = {}
                elseif sql:find("DELETE FROM sync_state", 1, true) then
                    data.sync_state = nil
                end
            end
            db.close = function() end
            db.prepare = function(_db, sql)
                local stmt = { sql = sql, args = {} }
                stmt.reset = function(current)
                    current.args = {}
                    return current
                end
                stmt.bind = function(current, ...)
                    current.args = { ... }
                    return current
                end
                stmt.step = function(current)
                    if current.sql:find("SELECT payload FROM sync_state", 1, true) then
                        return data.sync_state and { data.sync_state } or nil
                    end
                    if current.sql:find("SELECT position, chapter_uid, payload", 1, true) then
                        current.row_index = (current.row_index or 0) + 1
                        local chapter = data.sync_chapters[current.row_index]
                        return chapter and {
                            chapter.position, chapter.chapter_uid, chapter.payload,
                        } or nil
                    end
                    if current.sql:find("SELECT payload", 1, true) then
                        local payload = data.documents[current.args[1]]
                        return payload and { payload } or nil
                    elseif current.sql:find("INSERT INTO documents", 1, true) then
                        data.documents[current.args[1]] = current.args[2]
                    elseif current.sql:find("INSERT INTO sync_state", 1, true) then
                        data.sync_state = current.args[1]
                    elseif current.sql:find("INSERT INTO sync_chapters", 1, true) then
                        data.sync_chapters[current.args[1]] = {
                            position = current.args[1],
                            chapter_uid = current.args[2],
                            payload = current.args[3],
                        }
                    end
                    return nil
                end
                stmt.close = function() end
                return stmt
            end
            return db
        end,
    }
end

local function remove_file(path)
    files[path] = nil
    databases[path] = nil
    return true
end

local DB = require("weread.lib.external_annotations_db")
local legacy = {
    schema_version = 1,
    documents = {
        ["/books/第一炉香.epub"] = {
            binding = { book_id = "7", title = "第一炉香" },
            records = { { pos0 = "xp0", pos1 = "xp1", items = {
                { author = "读者", content = "想法" },
            } } },
        },
        ["/other/第一炉香.epub"] = {
            binding = { book_id = "8", title = "同名书" },
            records = {},
        },
    },
}
local flushes = 0
local settings = {
    data_dir = "/data/weread",
    get = function(_self, key, default)
        if key == "external_annotations" then return legacy end
        return default
    end,
    delete = function(_self, key)
        expect(key == "external_annotations", "migration deleted an unrelated setting")
        legacy = nil
    end,
    flush = function() flushes = flushes + 1 end,
}

local store = DB:new(settings, { remove_file = remove_file })
local first_path = store:databasePath("/books/第一炉香.epub")
local second_path = store:databasePath("/other/第一炉香.epub")
expect(first_path:find("/external-annotations/第一炉香-", 1, true) ~= nil,
    "per-book database path is not recognizable")
expect(first_path ~= second_path, "same-name books shared a database")

local ok, changed, count = store:migrateLegacySettings()
expect(ok and changed and count == 2, "legacy settings were not fully migrated")
expect(legacy == nil and flushes == 1,
    "legacy settings key was not deleted and flushed after migration")
local loaded = store:getDocument("/books/第一炉香.epub")
expect(loaded and loaded.binding.book_id == "7"
        and loaded.records[1].items[1].content == "想法",
    "binding, XPointer, or thought data did not survive migration")

expect(store:replaceSyncCheckpoint("/books/第一炉香.epub", {
    book_id = "7", catalog_signature = "signature", chapters = {},
}), "sync checkpoint could not be initialized")
expect(store:saveSyncChapter("/books/第一炉香.epub", 1, "chapter-1", {
    underlines = { { range = "1-2" } }, reviews = {},
}), "completed sync chapter could not be checkpointed")
local checkpoint = store:getSyncCheckpoint("/books/第一炉香.epub")
expect(checkpoint and checkpoint.catalog_signature == "signature"
        and checkpoint.chapters[1].chapter_uid == "chapter-1",
    "sync checkpoint could not be resumed")
expect(store:clearSyncCheckpoint("/books/第一炉香.epub")
        and store:getSyncCheckpoint("/books/第一炉香.epub") == nil,
    "completed sync checkpoint was not cleared")

expect(store:clearDocument("/books/第一炉香.epub"),
    "per-book database could not be cleared")
expect(not files[first_path] and files[second_path],
    "clearing one book affected the wrong database")

local failing_legacy = { documents = {
    ["/books/fail.epub"] = { binding = { book_id = "9" } },
} }
local failing_settings = {
    data_dir = "/data/weread",
    get = function() return failing_legacy end,
    delete = function() failing_legacy = nil end,
    flush = function() end,
}
fail_open = "/fail-"
local migrated = DB:new(failing_settings):migrateLegacySettings()
expect(not migrated and failing_legacy ~= nil,
    "failed database migration deleted the only legacy copy")

print(("external_annotations_db_spec: %d checks"):format(checks))
