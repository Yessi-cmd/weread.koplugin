-- WeRead public-account (公众号) articles: the article list for one account and
-- downloading a single article for reading.
--
-- Article lists are cached in the book record, so opening an account shows the
-- last known list immediately and only refreshes on request. Downloading goes
-- through Content.fetch_mp_article_html, which optionally embeds images; that is
-- the slow path, hence the progress dialog.

local ProgressbarDialog = require("ui/widget/progressbardialog")
local logger = require("logger")
local T = require("ffi/util").template

local Content = require("lib.content")
local I18n = require("lib.i18n")
local Util = require("lib.util")

local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"

local log_error = Util.log_error
local display_error = Util.display_error

local MPArticles = {}
MPArticles.__index = MPArticles

function MPArticles:new(plugin)
    return setmetatable({
        plugin = plugin,
        settings = plugin.settings,
        client = plugin.client,
        ui_host = plugin.ui_host,
    }, self)
end

function MPArticles:showMPAccount(book)
    self:rememberMPAccount(book)
    if not self.plugin.account:requireLogin(true, false) then
        return
    end
    local book_id = book.book_id or book.bookId
    local cached = self:getCachedMPArticles(book_id)
    if cached and #cached > 0 then
        self:showMPArticleList(book, cached)
        return
    end
    self:fetchMPArticles(book)
end

function MPArticles:rememberMPAccount(book)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return
    end
    local books = self.settings:get("books", {})
    local record = books[book_id] or {}
    record.book_id = book_id
    record.title = book.title or record.title
    record.author = book.author or record.author
    record.updated_at = os.time()
    -- Keep the resolved cache directory in sync both ways so the transient book
    -- object used for cached-path lookups knows where its articles actually live.
    record.cache_dir = book.cache_dir or record.cache_dir
    book.cache_dir = record.cache_dir
    books[book_id] = record
    self.settings:set("books", books)
    self.settings:flush()
end

function MPArticles:fetchMPArticles(book)
    if not self.plugin.account:requireLogin(true, false) then
        return
    end
    self.ui_host:runOnlineTask(_("Loading articles..."), function()
        self.ui_host:showBusy(_("Loading articles..."))
        local book_id = book.book_id or book.bookId
        local function request_articles()
            local ticket = self.settings:get("wr_ticket", "")
            if ticket == "" then ticket = nil end
            return self.client:get_mp_articles(book_id, 0, 100, ticket)
        end
        local ok, result, err_code = pcall(request_articles)
        if ok and not result and (err_code == -2041 or err_code == -2012) then
            logger.info(LOG_MODULE, "MP credentials rejected; renewing before retry")
            local renew_ok = pcall(function()
                return self.client:renew_cookie()
            end)
            if renew_ok then
                ok, result, err_code = pcall(request_articles)
            end
        end
        self.ui_host:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load MP articles failed:", log_error(result))
            self.ui_host:showInfo(T(_("Load articles failed:\n%1"), display_error(result)))
            return
        end
        if not result and (err_code == -2041 or err_code == -2012) then
            logger.warn(LOG_MODULE, "load MP articles rejected, error_code:", tostring(err_code))
            self.ui_host:showInfo(_("WeRead could not refresh the public-account credential. Please scan the QR code again."))
            return
        end
        if not result then
            logger.warn(LOG_MODULE, "load MP articles failed, error_code:", tostring(err_code))
            self.ui_host:showInfo(T(_("Load articles failed:\n%1"), "errCode " .. tostring(err_code)))
            return
        end
        local articles = Content.parse_mp_articles(result)
        self:cacheMPArticles(book_id, articles)
        self:showMPArticleList(book, articles)
    end)
end

function MPArticles:getCachedMPArticles(book_id)
    local books = self.settings:get("books", {})
    local record = books[book_id]
    if record and record.mp_articles then
        return record.mp_articles
    end
    return nil
end

function MPArticles:cacheMPArticles(book_id, articles)
    local books = self.settings:get("books", {})
    books[book_id] = books[book_id] or {}
    books[book_id].mp_articles = articles
    books[book_id].mp_articles_time = os.time()
    self.settings:set("books", books)
    self.settings:flush()
end

function MPArticles:showMPArticleList(book, articles)
    local items = {}
    for _i, article in ipairs(articles) do
        local cached_path = Content.mp_article_cached_path(self.settings, book, article)
        local is_cached = cached_path ~= nil
        local date_str = ""
        if article.createTime and article.createTime > 0 then
            date_str = os.date("%Y-%m-%d", article.createTime)
        end
        table.insert(items, {
            text = article.title or _("Article"),
            post_text = date_str,
            mandatory = is_cached and _("Cached") or "",
            callback = self.ui_host:safeCallback(article.title or _("Article"), function()
                if is_cached then
                    self.ui_host:openFile(cached_path)
                else
                    self:downloadMPArticleAndRead(book, article)
                end
            end),
        })
    end
    table.insert(items, {
        text = _("Refresh article list"),
        callback = self.ui_host:safeCallback(_("Refresh article list"), function()
            self:fetchMPArticles(book)
        end),
    })
    self.ui_host:showList(book.title or _("Public Account"), items, _("No articles."))
end

function MPArticles:downloadMPArticleAndRead(book, article)
    if not self.plugin.account:requireLogin(true, false) then
        return
    end
    self.ui_host:runOnlineTask(_("Download article and read"), function()
        self.ui_host:showBusy(T(_("Downloading article: %1"), article.title or ""))
        local progress_dialog
        local ok, path_or_err = pcall(function()
            return Content.fetch_mp_article_html(self.client, self.settings, book, article, {
                progress = function(current, total)
                    if not progress_dialog then
                        self.ui_host:closeBusy()
                        progress_dialog = ProgressbarDialog:new{
                            title = T(_("Downloading images: %1"), article.title or ""),
                            progress_max = total,
                        }
                        progress_dialog:show()
                        self.ui_host:refreshUI()
                    end
                    progress_dialog:reportProgress(current)
                end,
            })
        end)
        if progress_dialog then
            progress_dialog:close()
        else
            self.ui_host:closeBusy()
        end
        if not ok then
            logger.err(LOG_MODULE, "download MP article failed:", log_error(path_or_err))
            self.ui_host:showInfo(T(_("Download failed:\n%1"), display_error(path_or_err)))
            return
        end
        logger.info(
            LOG_MODULE,
            "MP article downloaded:",
            "images=", self.settings:get("cache").download_mp_images and "embedded" or "removed"
        )
        -- Persist the resolved cache directory (set by save_mp_article_html) so the
        -- article files can still be located after the download directory changes.
        local book_id = book.book_id or book.bookId
        if book_id and book.cache_dir then
            local books = self.settings:get("books", {})
            local record = books[book_id] or {}
            record.cache_dir = book.cache_dir
            books[book_id] = record
            self.settings:set("books", books)
            self.settings:flush()
        end
        self.ui_host:openFile(path_or_err)
    end)
end

return MPArticles
