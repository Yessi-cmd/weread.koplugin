package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local CacheSafety = require("weread.lib.cache_safety")

expect(CacheSafety.shell_quote("a'b$(touch marker)`id`")
        == "'a'\\''b$(touch marker)`id`'",
    "shell quoting did not keep substitutions inside literal text")

local root = os.tmpname() .. "-weread-cache-safety"
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/book")))
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/legacy")))
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/legacy-remove")))
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/collision")))
assert(os.execute("mkdir -p " .. string.format("%q", root .. "/wrong")))
local legacy_file = assert(io.open(root .. "/legacy-remove/book.epub", "wb"))
legacy_file:write("legacy")
legacy_file:close()

local marked, mark_err = CacheSafety.mark(root .. "/book", "book")
expect(marked == true, "ownership marker failed: " .. tostring(mark_err))
expect(CacheSafety.read_owner(root .. "/book") == "book",
    "ownership marker did not round-trip")

local valid = CacheSafety.validate_owned(root .. "/book", "book", {
    roots = { root },
})
expect(valid == true, "matching owner was rejected")
local wrong, wrong_err = CacheSafety.validate_owned(
    root .. "/book", "different-book", { roots = { root } })
expect(wrong == nil and tostring(wrong_err):find("ownership", 1, true),
    "mismatched owner was accepted")

local legacy, legacy_kind = CacheSafety.validate_owned(
    root .. "/legacy", "legacy", {
        roots = { root }, legacy_evidence = true,
    })
expect(legacy == true and legacy_kind == "legacy",
    "direct legacy cache child was not accepted")
local claimed, claim_err = CacheSafety.claim(
    root .. "/legacy", "legacy", {
        roots = { root }, legacy_evidence = true,
    })
expect(claimed == true and CacheSafety.read_owner(root .. "/legacy") == "legacy",
    "validated legacy directory could not be claimed: " .. tostring(claim_err))
local outside = CacheSafety.validate_owned(
    root .. "/wrong", "wrong", { roots = { root .. "/elsewhere" } })
expect(outside == nil, "an unowned directory outside the cache root was accepted")
expect(CacheSafety.claim(root .. "/wrong", "wrong", {
    roots = { root .. "/elsewhere" },
}) == nil, "an arbitrary persisted directory was laundered into owned cache")
local collision, collision_err = CacheSafety.validate_owned(
    root .. "/collision", "collision", {
        roots = { root }, allow_new_child = true,
    })
expect(collision == nil
    and tostring(collision_err):find("verified", 1, true),
    "an existing same-name directory was accepted without cache evidence")
local new_child, new_kind = CacheSafety.validate_owned(
    root .. "/new-book", "new-book", {
        roots = { root }, allow_new_child = true,
    })
expect(new_child == true and new_kind == "new",
    "a missing exact book child could not be prepared")
local file_evidence = CacheSafety.has_legacy_file_evidence(
    root .. "/legacy-remove", {
        cached_file = root .. "/legacy-remove/book.epub",
    })
expect(file_evidence == true, "a tracked legacy cache file was not recognized")
expect(CacheSafety.has_legacy_file_evidence(root .. "/collision", {
    cached_file = root .. "/collision/missing.epub",
}) == false, "a missing tracked path was accepted as cache evidence")
expect(CacheSafety.validate_owned("/", "book", { roots = { root } }) == nil,
    "filesystem root was accepted")
expect(CacheSafety.validate_owned(root .. "/../book", "book", {
    roots = { root },
}) == nil, "a traversal path was accepted")

local modes = {
    [root .. "/book"] = "directory",
    [root .. "/legacy"] = "directory",
    [root .. "/legacy-remove"] = "directory",
    [root .. "/collision"] = "directory",
    [root .. "/link"] = "link",
}
local fake_lfs = {
    symlinkattributes = function(path)
        local mode = modes[path]
        return mode and { mode = mode } or nil
    end,
    attributes = function(path)
        local mode = modes[path]
        return mode and { mode = mode } or nil
    end,
}
local purged = {}
local function purge(path)
    purged[#purged + 1] = path
    -- Match KOReader's historical no-return-value success convention.
end

local removed, remove_err = CacheSafety.remove_book_dir(
    root .. "/book", "book", {
        roots = { root }, lfs = fake_lfs, purge = purge,
    })
expect(removed == true and purged[1] == root .. "/book",
    "marked directory was not passed to the safe purge primitive: "
        .. tostring(remove_err))

removed = CacheSafety.remove_book_dir(
    root .. "/legacy-remove", "legacy-remove", {
    roots = { root }, legacy_evidence = file_evidence,
    lfs = fake_lfs, purge = purge,
})
expect(removed == true and purged[2] == root .. "/legacy-remove",
    "legacy direct child was not removed safely")

local collision_removed = CacheSafety.remove_book_dir(
    root .. "/collision", "collision", {
        roots = { root }, lfs = fake_lfs, purge = purge,
    })
expect(collision_removed == nil and #purged == 2,
    "an unverified same-name directory reached the purge primitive")

local linked_owner = CacheSafety.validate_owned(root .. "/link", "link", {
    roots = { root }, allow_new_child = true, lfs = fake_lfs,
})
expect(linked_owner == nil,
    "a symbolic-link cache directory was accepted for writing")

local refused = CacheSafety.remove_book_dir(root .. "/link", "link", {
    roots = { root }, lfs = fake_lfs, purge = purge,
})
expect(refused == nil and #purged == 2,
    "symbolic-link cache path reached the purge primitive")

local missing = CacheSafety.remove_book_dir(root .. "/missing", "missing", {
    roots = { root }, lfs = fake_lfs, purge = purge,
})
expect(missing == true and #purged == 2,
    "an already-missing cache directory was not treated as cleared")

assert(os.execute("rm -rf " .. string.format("%q", root)))
print(("cache_safety_spec: %d checks"):format(checks))
