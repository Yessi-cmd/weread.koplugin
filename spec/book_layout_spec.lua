package.path = "./?.lua;./?/init.lua;" .. package.path

local BookLayout = require("weread.lib.book_layout")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

expect(BookLayout.normalize_mode("unknown") == "smart",
    "unknown layout mode did not fall back to smart")
expect(BookLayout.classify_chapter("<p>普通文字章节内容。</p>") == "text",
    "plain chapter was not classified as text")
expect(BookLayout.classify_chapter(
        "<p>这是一段包含足够多文字的图文章节，用于避免被识别为只有图片的章节。</p><img src='a.jpg'/>")
        == "illustrated",
    "mixed chapter was not classified as illustrated")
expect(BookLayout.classify_chapter("<div><img src='page.jpg'/></div>") == "image",
    "image-only chapter was not classified as image")

local smart_body, smart_kind, smart_added = BookLayout.prepare_body(
    "<p>老师本该对我垂以训诫。</p>",
    { title = "第10章", level = 1 }, "smart")
expect(smart_added and smart_kind == "text"
        and smart_body:find(">第10章</h1>", 1, true),
    "smart mode did not add a missing chapter title")
expect(BookLayout.compose_css("body{}", "smart")
        :find("margin: 2.5em 0 5em", 1, true),
    "smart mode did not add adaptive chapter-opening whitespace")

local existing_body, _existing_kind, existing_added = BookLayout.prepare_body(
    "<h2>第 10 章</h2><p>老师本该对我垂以训诫。</p>",
    { title = "第10章", level = 2 }, "smart")
expect(not existing_added
        and existing_body:find("<h2>第 10 章</h2>", 1, true),
    "smart mode duplicated an existing visible title")
expect(not BookLayout.has_visible_title(
        "<html><head><title>第10章</title></head><body><p>正文</p></body></html>",
        "第10章"),
    "head metadata was mistaken for a visible title")

local original_body, _original_kind, original_added = BookLayout.prepare_body(
    "<p>正文</p>", { title = "章节标题" }, "original")
expect(not original_added and original_body == "<p>正文</p>",
    "original mode changed chapter markup")
local image_body, image_kind, image_added = BookLayout.prepare_body(
    "<img src='page.jpg'/>", { title = "插图" }, "smart")
expect(image_kind == "image" and not image_added
        and image_body == "<img src='page.jpg'/>",
    "image-only chapter received a generated text title")

local book_kind = BookLayout.classify_book({
    { chapterUid = 1 }, { chapterUid = 2 }, { chapterUid = 3 },
}, {
    ["1"] = "<img src='1.jpg'/>",
    ["2"] = "<img src='2.jpg'/>",
    ["3"] = "<p>少量文字</p><img src='3.jpg'/>",
})
expect(book_kind == "image", "image-dominant book was not detected")
expect(BookLayout.body_classes("clean", "illustrated", "text")
        == "wr-mode-clean wr-book-illustrated wr-chapter-text",
    "layout body classes were wrong")
expect(BookLayout.compose_css(nil, "clean"):find("text-align: justify", 1, true),
    "clean mode did not add normalized reading styles")

local sanitized = BookLayout.sanitize_body(
    '<SCRIPT>alert(1)</SCRIPT><p onclick="bad()">safe\0text'
        .. '<a href="javascript:bad()">link</a><a href=file:///etc/passwd>x</a></p>'
        .. '<svg onload=bad()><script>bad()</script></svg>'
        .. '<iframe src="https://bad.test"></iframe>')
expect(not sanitized:lower():find("<script", 1, true)
        and not sanitized:lower():find("<iframe", 1, true)
        and not sanitized:lower():find("onclick", 1, true)
        and not sanitized:lower():find("onload", 1, true)
        and sanitized:find('href="#"', 1, true)
        and sanitized:find("href=#", 1, true)
        and sanitized:find("safetext", 1, true),
    "active or XML-invalid chapter content was not sanitized")
local extracted = BookLayout.extract_body(
    '<?xml version="1.0"?><HTML><HEAD><title>hidden</title></HEAD>'
        .. '<BODY><p>first</p></BODY><BODY><p>second</p></BODY></HTML>')
expect(extracted:find("first", 1, true) and extracted:find("second", 1, true)
        and not extracted:find("hidden", 1, true),
    "uppercase or concatenated XHTML bodies were not extracted")
local safe_css = BookLayout.compose_css(
    '@import "file:///etc/passwd";a{behavior:url(x);background:url(javascript:bad);width:expression(x)}',
    "original")
expect(not safe_css:lower():find("@import", 1, true)
        and not safe_css:lower():find("javascript", 1, true)
        and not safe_css:lower():find("expression", 1, true)
        and not safe_css:lower():find("behavior", 1, true),
    "active CSS constructs were retained")

print(("book_layout_spec: %d checks"):format(checks))
