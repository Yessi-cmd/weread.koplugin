package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload.device = function()
    return { unpackArchive = function() return true end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, scheduleIn = function() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, value) return value end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(value) return value end,
        T = function(template, ...)
            local values = { ... }
            return (template:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end

local Updater = require("weread.lib.updater")

expect(Updater.MAX_PACKAGE_BYTES == 10 * 1024 * 1024,
    "update package limit must be 10 MiB")
expect(Updater.MAX_RELEASE_METADATA_BYTES == 1024 * 1024
        and Updater.MAX_CHECKSUM_BYTES == 4096,
    "update metadata limits changed unexpectedly")

expect(Updater.compare_versions("1.2.3", "1.2.2") == 1,
    "newer version was not detected")
expect(Updater.compare_versions("v1.2.3", "1.2.3") == 0,
    "v-prefixed version should compare equally")
expect(Updater.compare_versions("1.2.2", "1.2.3") == -1,
    "older version was not detected")
expect(Updater.compare_versions("invalid", "1.2.3") == nil,
    "invalid version should be rejected")
expect(Updater.compare_versions("1.2.3-beta", "1.2.3") == nil,
    "non-release version should be rejected")

local direct_first = Updater.candidate_urls(Updater.API_URL, false)
expect(#direct_first == 4 and direct_first[1] == Updater.API_URL
    and direct_first[2]:find("gh%-proxy.com"),
    "direct-first source order was wrong")
local proxy_first = Updater.candidate_urls(Updater.API_URL, true)
expect(#proxy_first == 4 and proxy_first[1]:find("gh%-proxy.com")
    and proxy_first[4] == Updater.API_URL,
    "proxy-first source order was wrong")
expect(#Updater.candidate_urls("https://example.com/update.zip", true) == 0,
    "untrusted update URL should not receive proxy candidates")

local private_source = assert(Updater.repository_urls(
    "Yessi-cmd/weread.koplugin"))
local private_candidates = Updater.candidate_urls(
    private_source.api_url, false, private_source)
expect(private_candidates[1] == private_source.api_url,
    "custom update repository API was rejected")
expect(#Updater.candidate_urls(Updater.API_URL, false, private_source) == 0,
    "custom update channel accepted the upstream API")
expect(Updater.repository_urls("https://github.com/owner/repo") == nil,
    "an arbitrary update repository URL was accepted")
expect(Updater.repository_urls("../repo") == nil,
    "dot-segment update repository was accepted")

local release, release_err = Updater.parse_release({
    tag_name = "v0.7.0",
    draft = false,
    prerelease = false,
    body = "## What's Changed\n\n**Added** `updates`",
    html_url = "https://phishing.invalid/fake-release",
    assets = {
        {
            name = "weread.koplugin-v0.7.0.zip",
            browser_download_url = "https://github.com/finlater/weread.koplugin/releases/download/v0.7.0/weread.koplugin-v0.7.0.zip",
            size = 1234,
        },
        {
            name = "weread.koplugin-v0.7.0.zip.sha256",
            browser_download_url = "https://github.com/finlater/weread.koplugin/releases/download/v0.7.0/weread.koplugin-v0.7.0.zip.sha256",
        },
    },
})
expect(release ~= nil and release_err == nil, "valid release was rejected")
expect(release.version == "0.7.0" and release.archive_size == 1234,
    "release metadata was parsed incorrectly")
expect(release.notes:find("Added updates", 1, true) ~= nil,
    "release notes were not normalized")
expect(release.release_url
        == "https://github.com/finlater/weread.koplugin/releases/tag/v0.7.0",
    "release page URL was trusted from mirrored metadata")

local missing, missing_err = Updater.parse_release({
    tag_name = "v0.7.0",
    assets = {},
})
expect(missing == nil and missing_err:find("checksum", 1, true),
    "release without checksum should be rejected")

local foreign = Updater.parse_release({
    tag_name = "v0.7.0",
    assets = {
        { name = "weread.koplugin-v0.7.0.zip", browser_download_url = "https://example.com/plugin.zip" },
        { name = "weread.koplugin-v0.7.0.zip.sha256", browser_download_url = "https://example.com/plugin.sha256" },
    },
})
expect(foreign == nil, "foreign download URL should be rejected")

local private_release = Updater.parse_release({
    tag_name = "v1.3.0",
    assets = {
        {
            name = "weread.koplugin-v1.3.0.zip",
            browser_download_url = private_source.release_prefix
                .. "v1.3.0/weread.koplugin-v1.3.0.zip",
        },
        {
            name = "weread.koplugin-v1.3.0.zip.sha256",
            browser_download_url = private_source.release_prefix
                .. "v1.3.0/weread.koplugin-v1.3.0.zip.sha256",
        },
    },
}, private_source)
expect(private_release and private_release.version == "1.3.0",
    "custom repository release metadata was rejected")

expect(Updater.is_safe_archive_entry({
        path = "weread.koplugin/main.lua", mode = "file", size = 1024,
    }), "regular plugin archive entry was rejected")
expect(Updater.is_safe_archive_entry({
        path = "weread.koplugin/", mode = "directory",
    }), "plugin archive directory entry was rejected")
expect(not Updater.is_safe_archive_entry({
        path = "weread.koplugin/../../outside", mode = "file", size = 1,
    }) and not Updater.is_safe_archive_entry({
        path = "weread.koplugin/link", mode = "link", size = 1,
    }) and not Updater.is_safe_archive_entry({
        path = "weread.koplugin/link", mode = "file", size = 1,
        linkpath = "/tmp/outside",
    }) and not Updater.is_safe_archive_entry({
        path = "weread.koplugin/huge", mode = "file",
        size = Updater.MAX_UNPACKED_BYTES + 1,
    }), "unsafe archive entry was accepted")

package.loaded["ltn12"] = {
    sink = {
        file = function(file)
            return function(chunk)
                if chunk then file:write(chunk) else file:close() end
                return 1
            end
        end,
        table = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    },
}
package.loaded["socket"] = {
    skip = function(count, ...)
        return select(count + 1, ...)
    end,
}
local timeout_sets, timeout_resets = 0, 0
package.loaded["socketutil"] = {
    FILE_BLOCK_TIMEOUT = 1,
    FILE_TOTAL_TIMEOUT = 1,
    LARGE_BLOCK_TIMEOUT = 1,
    LARGE_TOTAL_TIMEOUT = 1,
    set_timeout = function() timeout_sets = timeout_sets + 1 end,
    reset_timeout = function() timeout_resets = timeout_resets + 1 end,
}
local request_count, last_request_url, throw_request = 0, nil, false
package.loaded["socket/http"] = {
    request = function(options)
        request_count = request_count + 1
        last_request_url = options.url
        if throw_request then error("network exploded") end
        local ok, err = options.sink("abc")
        if not ok then return nil, err end
        ok, err = options.sink("def")
        if not ok then return nil, err end
        options.sink(nil)
        return 1, 200, {}, "OK"
    end,
}

local update_state = { prefer_proxy = false }
local updater = Updater:new{
    settings = {
        get = function() return update_state end,
        set = function() end,
        flush = function() end,
    },
    current_version = "0.6.0",
    plugin_dir = "/tmp/weread.koplugin",
}
local private_updater = Updater:new{
    settings = updater.settings,
    current_version = "1.2.0",
    plugin_dir = "/tmp/weread-private.koplugin",
    repository = "Yessi-cmd/weread.koplugin",
}
expect(private_updater.api_url == private_source.api_url
        and private_updater.release_prefix == private_source.release_prefix,
    "custom repository was not applied to the updater instance")
update_state.available_version = "9.9.9"
update_state.repository = "finlater/weread.koplugin"
update_state.last_check = 12345
expect(private_updater:has_update() == false,
    "cached metadata from another repository crossed update channels")
expect(private_updater:last_check_time() == 0,
    "last-check time from another repository delayed the private channel")
update_state.available_version = nil
update_state.repository = nil
update_state.last_check = nil
local backup_exists, purged_path = true, nil
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path)
        if path == updater.plugin_dir .. ".backup" and backup_exists then
            return "directory"
        end
    end,
}
package.loaded["ffi/util"] = {
    purgeDir = function(path) purged_path = path end,
}
local cleanup_ok, cleanup_err = updater:cleanup_backup()
expect(cleanup_ok == true and cleanup_err == nil
        and purged_path == updater.plugin_dir .. ".backup",
    "successful startup should remove the previous update backup")
backup_exists, purged_path = false, nil
cleanup_ok, cleanup_err = updater:cleanup_backup()
expect(cleanup_ok == true and cleanup_err == nil and purged_path == nil,
    "backup cleanup should be a no-op when no backup exists")
local progress = {}
local download_path = "/tmp/weread-updater-progress-spec.bin"
local streaming_url = Updater.RELEASE_PREFIX .. "v0.7.0/test.zip"
local downloaded, download_err = updater:_http_get(
    streaming_url,
    download_path,
    function(received, total)
        progress[#progress + 1] = { received, total }
    end,
    6,
    Updater.MAX_PACKAGE_BYTES)
expect(downloaded == true and download_err == nil
        and last_request_url == streaming_url,
    "streaming download failed")
expect(#progress == 2 and progress[1][1] == 3 and progress[2][1] == 6
    and progress[2][2] == 6,
    "streaming download did not report real byte progress")
local downloaded_file = assert(io.open(download_path, "rb"))
expect(downloaded_file:read("*a") == "abcdef",
    "streaming download wrote unexpected content")
downloaded_file:close()
os.remove(download_path)

request_count = 0
local oversized, oversized_err = updater:_http_get_with_mirrors(
    Updater.RELEASE_PREFIX .. "v0.7.0/test.zip",
    download_path, nil, 0, 5)
expect(oversized == nil and oversized_err == "download exceeds size limit",
    "streaming download should stop as soon as it exceeds the size limit")
expect(request_count == 1,
    "size-limit failures should not retry the download through mirrors")
expect(io.open(download_path, "rb") == nil,
    "oversized partial download should be removed")

request_count = 0
local memory_body, memory_err = updater:_http_get(
    Updater.API_URL, nil, nil, nil, 5)
expect(memory_body == nil and memory_err == "download exceeds size limit"
        and request_count == 1,
    "in-memory update metadata was not bounded")

update_state.prefer_proxy = true
request_count, last_request_url = 0, nil
local checksum_url = Updater.RELEASE_PREFIX
    .. "v0.7.0/weread.koplugin-v0.7.0.zip.sha256"
local direct_checksum, direct_checksum_err = updater:_http_get_direct(
    checksum_url, download_path, nil, nil, Updater.MAX_CHECKSUM_BYTES)
expect(direct_checksum == true and direct_checksum_err == nil
        and request_count == 1 and last_request_url == checksum_url,
    "checksum download was routed through a third-party mirror")
os.remove(download_path)
update_state.prefer_proxy = false

throw_request = true
local resets_before_exception = timeout_resets
local failed_request, failed_request_err = updater:_http_get(
    Updater.API_URL, nil, nil, nil, Updater.MAX_RELEASE_METADATA_BYTES)
throw_request = false
expect(failed_request == nil
        and failed_request_err:find("HTTP request failed", 1, true)
        and timeout_resets == resets_before_exception + 1,
    "request exception did not restore the global socket timeout")
expect(timeout_sets == timeout_resets,
    "socket timeout setup and cleanup became unbalanced")

local updater_source = assert(io.open("weread/lib/updater.lua", "r")):read("*a")
expect(updater_source:find('require("ui/', 1, true) == nil,
    "core updater must not import UI modules")

local meta = assert(io.open("_meta.lua", "r")):read("*a")
local main = assert(io.open("main.lua", "r")):read("*a")
local meta_version = meta:match('version%s*=%s*"([^"]+)"')
local main_version = main:match('version%s*=%s*"([^"]+)"')
expect(meta_version == main_version, "main.lua and _meta.lua versions must match")

print(("updater_spec: %d checks"):format(checks))
