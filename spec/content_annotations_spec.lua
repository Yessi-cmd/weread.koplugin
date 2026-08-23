package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["bit"] = function()
    return { rshift = function(value, bits) return math.floor(value / 2 ^ bits) end }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/web/reader/"
                .. tostring(book_id) .. "/" .. tostring(chapter_uid or "")
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end

local Annotations = require("weread.lib.annotations")
local Content = require("weread.lib.content")

local original = "\xef\xbb\xbf<p>你好世界</p>"
local processed = Annotations.injectUnderlines(original, {
    { range = "3-7" },
}, nil, "chapter", "book")
expect(processed:sub(1, 3) ~= "\xef\xbb\xbf",
    "leading BOM was not removed")
expect(processed:find('<span class="wr%-underline">你好世界</span>') ~= nil,
    "UTF-8 underline range was not injected correctly")
expect(processed:find("<p>", 1, true) and processed:find("</p>", 1, true),
    "underline injection corrupted surrounding HTML")

local thought_html = Annotations.injectUnderlines("<p>hello</p>", {
    { range = "3-8" },
}, { ["3-8"] = true }, "chapter/1", 'book"2')
expect(thought_html:find("wr%-thought%-link") ~= nil
    and thought_html:find("wr%-star") == nil,
    "thought link was not generated without a trailing star")
expect(thought_html:find('id="wrthought%-book_2%-chapter_1%-3%-8"') ~= nil,
    "thought anchor id was not sanitized")

local trailing_whitespace = Annotations.injectUnderlines("<p>abc</p>\n  ", {
    { range = "3-12" },
}, { ["3-12"] = true }, "chapter/11", "book")
expect(trailing_whitespace:find(
        '<a id="wrthought%-book%-chapter_11%-3%-12" class="wr%-thought%-link" href="#wrthought%-book%-chapter_11%-3%-12"><span class="wr%-underline">abc</span></a>',
        1) ~= nil,
    "thought link stays attached to underlined text when the range ends with whitespace")

local unchanged = Annotations.injectUnderlines("<p>safe</p>", {
    { range = "bad" },
    { range = "999-1000" },
}, nil, "chapter", "book")
expect(unchanged == "<p>safe</p>", "invalid ranges changed the document")

local annotated, css = Annotations.process("<p>hello</p>", {
    chapterUid = "chapter",
    underlines = { { range = "3-8" } },
}, {
    { range = "3-8", pageReviews = { { review = { content = "idea" } } } },
}, "book")
expect(annotated ~= "<p>hello</p>", "annotation process did not change HTML")
expect(css:find(".wr%-underline") and css:find(".wr%-thought%-link"),
    "annotation CSS did not include underline and thought styles")
expect(css:find("wr%-star") == nil,
    "annotation CSS still included obsolete thought star styles")

local xhtml = Content.txt_to_xhtml("first & <tag>\r\n\r\nsecond")
expect(xhtml:find("<p>first &amp; &lt;tag&gt;</p>", 1, true),
    "plain text was not XML-escaped")
expect(xhtml:find("<p>second</p>", 1, true),
    "plain text paragraph conversion lost content")

local rewritten = Content.rewrite_image_sources(
    '<picture><source srcset="a.jpg 1x, a@2x.jpg 2x"/>'
        .. '<img src="a.jpg"/></picture><image xlink:href="b.png"/>',
    {
        ["a.jpg"] = "../images/a.jpg",
        ["a@2x.jpg"] = "../images/a@2x.jpg",
        ["b.png"] = "../images/b.png",
    })
expect(rewritten:find('src="../images/a.jpg"', 1, true),
    "image source was not rewritten")
expect(rewritten:find(
        'srcset="../images/a.jpg 1x, ../images/a@2x.jpg 2x"', 1, true),
    "responsive image sources were not rewritten")
expect(rewritten:find('xlink:href="b.png"', 1, true),
    "non-src image attribute should be left unchanged")
local data_srcset = 'data:image/svg+xml,%3Csvg%3E 1x, https://img.test/a.jpg 2x'
local preserved_srcset = Content.rewrite_image_sources(
    '<source srcset="' .. data_srcset .. '"/>',
    { ["a.jpg"] = "../images/a.jpg" })
expect(preserved_srcset:find(data_srcset, 1, true),
    "data URL commas in srcset were parsed as candidate separators")
local rewritten_css = Content.rewrite_css_sources(
    '.hero{background-image:url("covers/a.jpg")}.inline{background:url(data:image/png;base64,abc)}',
    { ["a.jpg"] = "../images/a.jpg" })
expect(rewritten_css:find('url("images/a.jpg")', 1, true)
        and rewritten_css:find("url(data:image/png;base64,abc)", 1, true),
    "CSS image resources were not rewritten safely")
local remote_xhtml, remote_assets = Content.download_remote_images({
    get_binary = function(_self, _url) return "\255\216\255jpeg" end,
}, '<picture><source srcset="https://img.test/a.jpg 1x, https://img.test/b.jpg 2x"/>'
    .. '<img src="https://img.test/a.jpg"/></picture>', {})
expect(#remote_assets == 2
        and remote_xhtml:find("../images/a.jpg 1x", 1, true)
        and remote_xhtml:find("../images/b.jpg 2x", 1, true),
    "remote responsive images were not cached and deduplicated")
expect(Content.is_safe_remote_url("https://img.test/a.jpg")
        and not Content.is_safe_remote_url("http://127.0.0.1/private")
        and not Content.is_safe_remote_url("http://192.168.1.2/private")
        and not Content.is_safe_remote_url("http://localhost/private")
        and not Content.is_safe_remote_url("file:///etc/passwd"),
    "remote resource URL guard accepted a local or unsupported target")
local private_fetches = 0
local private_xhtml, private_assets = Content.download_remote_images({
    get_binary = function() private_fetches = private_fetches + 1 end,
}, '<img src="http://127.0.0.1/private.jpg"/>', {})
expect(private_fetches == 0 and #private_assets == 0
        and private_xhtml:find("127.0.0.1", 1, true),
    "local image URL triggered a network request")
local previous_image_limit = Content.MAX_REMOTE_IMAGE_BYTES
Content.MAX_REMOTE_IMAGE_BYTES = 4
local oversized_xhtml, oversized_assets = Content.download_remote_images({
    get_binary = function() return "12345" end,
}, '<img src="https://img.test/large.jpg"/>', {})
Content.MAX_REMOTE_IMAGE_BYTES = previous_image_limit
expect(#oversized_assets == 0
        and oversized_xhtml:find("https://img.test/large.jpg", 1, true),
    "oversized remote image was embedded")
local svg_xhtml, svg_assets = Content.download_remote_images({
    get_binary = function()
        return '<svg xmlns="http://www.w3.org/2000/svg" onload="bad()">'
            .. '<script>bad()</script><rect width="1" height="1"/></svg>'
    end,
}, '<img src="https://img.test/vector.svg"/>', {})
expect(#svg_assets == 1 and svg_assets[1].media_type == "image/svg+xml"
        and not svg_assets[1].data:lower():find("<script", 1, true)
        and not svg_assets[1].data:lower():find("onload", 1, true)
        and svg_xhtml:find("../images/vector.svg", 1, true),
    "active SVG content was not sanitized")

local original_fetch_xhtml = Content.fetch_chapter_xhtml
local original_fetch_css = Content.fetch_chapter_css
Content.fetch_chapter_xhtml = function() return "<p>chapter</p>" end
Content.fetch_chapter_css = function(_client, _settings, _book, chapter)
    return ".chapter-" .. tostring(chapter.chapterUid) .. "{}"
end
local css_state = {}
Content.fetch_single_chapter_source({}, {}, {}, { chapterUid = 1 }, css_state)
Content.fetch_single_chapter_source({}, {}, {}, { chapterUid = 2 }, css_state)
Content.fetch_single_chapter_source({}, {}, {}, { chapterUid = 1 }, css_state)
expect(css_state.chapter_css["1"] == ".chapter-1{}"
        and css_state.chapter_css["2"] == ".chapter-2{}",
    "chapter styles were not kept in separate slots")
Content.fetch_chapter_xhtml = original_fetch_xhtml
Content.fetch_chapter_css = original_fetch_css

local original_download_assets = Content.download_chapter_assets
Content.download_chapter_assets = function(_client, _book, chapter)
    local suffix = tostring(chapter.chapterUid) == "1" and "" or "-2"
    return {}, { ["image.png"] = "../images/image" .. suffix .. ".png" }
end
local isolated_css_state = {
    chapter_css = {
        ["1"] = ".first{background:url(image.png)}",
        ["2"] = ".second{background:url(image.png)}",
    },
}
local image_settings = {
    get = function()
        return { download_book_images = true }
    end,
}
Content.finalize_single_chapter_content(
    {}, image_settings, {}, { chapterUid = 1 }, "<p>one</p>", isolated_css_state)
Content.finalize_single_chapter_content(
    {}, image_settings, {}, { chapterUid = 2 }, "<p>two</p>", isolated_css_state)
expect(isolated_css_state.chapter_css["1"]:find(
        "url(images/image.png)", 1, true)
        and not isolated_css_state.chapter_css["1"]:find("image-2", 1, true)
        and isolated_css_state.chapter_css["2"]:find(
            "url(images/image-2.png)", 1, true),
    "a later chapter remapped an earlier chapter's same-named CSS image")
Content.download_chapter_assets = original_download_assets

local body = Content.extract_mp_body(
    '<div id="js_content"><p data-src="x.jpg">article</p>'
        .. '<script>bad()</script></div><script>after()</script>')
expect(body and body:find('src="x.jpg"', 1, true)
    and not body:find("bad()", 1, true),
    "MP article body extraction did not normalize or sanitize content")
expect(Content.extract_mp_body("<html>missing</html>") == nil,
    "missing MP body should return nil")

local stripped = Content.strip_mp_images(
    '<p>before<img src="x"/></p><picture><source src="y"/></picture><p>after</p>')
expect(not stripped:lower():find("<img", 1, true)
    and not stripped:lower():find("<picture", 1, true)
    and stripped:find("before", 1, true) and stripped:find("after", 1, true),
    "MP image stripping removed text or kept media")

local articles = Content.parse_mp_articles({
    reviews = {{
        subReviews = {{
            reviewId = "outer",
            review = {
                reviewId = "inner",
                belongBookId = "book",
                mpInfo = {
                    originalId = "original",
                    title = "Article",
                    content_url = "https://mp.example/article",
                },
            },
        }},
    }},
})
expect(#articles == 1 and articles[1].title == "Article"
    and #articles[1].reviewIds == 3,
    "MP article metadata was not normalized")

print(("content_annotations_spec: %d checks"):format(checks))
