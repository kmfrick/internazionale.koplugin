--[[--
Lays out an Internazionale issue as an EPUB 3 (with an NCX for older readers).

The builder streams everything into a writer as it goes, so images never pile up in memory:

    local b = Epub.Builder{ writer = w, issue = meta, outline = outline, fetch = fetch_fn, image_mode = "normal" }
    b:begin()
    b:setCover()
    b:addArticle(outline_article, article_json)   -- for each article, in order
    b:finish()

`writer:add(path, content, binary)` must store one zip entry; `fetch(url)` returns bytes or nil.
]]

local Api = require("internaz_api")

local Epub = {}

Epub.CSS = [[
body { margin: 0; line-height: 1.4; text-align: justify; hyphens: auto; }
p { margin: 0; text-indent: 1.2em; }
p.noindent, p.first { text-indent: 0; }
.initial { font-weight: bold; font-size: 1.5em; line-height: 1; }

.kicker { font-family: sans-serif; font-size: 0.75em; font-weight: bold; text-transform: uppercase;
          letter-spacing: 0.06em; text-indent: 0; text-align: left; margin: 0 0 0.6em 0; }
h1.title { font-size: 1.7em; line-height: 1.15; text-align: left; hyphens: none; margin: 0 0 0.5em 0; }
.standfirst { font-size: 1.1em; font-style: italic; line-height: 1.3; text-indent: 0; text-align: left;
              margin: 0 0 0.8em 0; }
.byline { font-family: sans-serif; font-size: 0.85em; text-indent: 0; text-align: left; margin: 0 0 1.2em 0; }
.byline .author { font-weight: bold; }
.byline .source { font-style: italic; }

h2.subhead, h3.subhead { font-family: sans-serif; font-size: 1em; font-weight: bold; text-align: left;
                         hyphens: none; margin: 1.2em 0 0.4em 0; page-break-after: avoid; }
h2.subhead { font-size: 1.15em; }

.figure { margin: 1em 0; text-align: center; text-indent: 0; page-break-inside: avoid; }
.figure img { max-width: 100%; }
.caption { font-family: sans-serif; font-size: 0.75em; line-height: 1.3; text-align: left; text-indent: 0;
           margin: 0.3em 0 0 0; }
.credit { font-style: italic; }

blockquote.pullquote { font-size: 1.15em; font-style: italic; text-align: left; margin: 1em 1.2em;
                       padding: 0.3em 0 0.3em 0.7em; border-left: 3px solid black; }
blockquote.pullquote p { text-indent: 0; }

.box { font-family: sans-serif; font-size: 0.88em; margin: 1.3em 0; padding: 0.6em 0;
       border-top: 2px solid black; border-bottom: 1px solid black; }
.box p { text-indent: 0; margin-bottom: 0.4em; }
.box p.box-title { font-weight: bold; font-size: 1.1em; text-align: left; margin-bottom: 0.5em; }
.box p.box-subtitle { font-style: italic; }

.minireview { margin: 0 0 1.2em 0; }
.minireview p { text-indent: 0; }
.minireview p.work { font-family: sans-serif; font-size: 0.9em; text-align: left; margin-bottom: 0.2em; }

.note { font-size: 0.85em; font-style: italic; margin: 1em 0; }
.note p { text-indent: 0; }
.portrait-name { font-family: sans-serif; font-weight: bold; font-size: 1.2em; text-indent: 0; margin-top: 0.8em; }
.portrait-title { font-style: italic; text-indent: 0; margin-bottom: 0.8em; }
ol, ul { margin: 0.6em 0 0.6em 1.4em; padding: 0; }
li { margin-bottom: 0.3em; }
li p { text-indent: 0; }
hr { border: 0; border-top: 1px solid black; margin: 1em 25%; }

.issue-ref { font-family: sans-serif; font-size: 0.75em; text-align: right; text-indent: 0; margin-top: 1.6em; }
.backlink { font-family: sans-serif; font-size: 0.75em; text-align: right; text-indent: 0; }

body.cover { text-align: center; }
.cover { text-align: center; margin: 0; }
.cover img { width: 100%; }

.masthead { font-family: sans-serif; font-size: 2em; font-weight: bold; text-align: center; text-indent: 0;
            letter-spacing: 0.04em; margin: 0.4em 0 0 0; }
.issue-line { font-family: sans-serif; font-size: 0.85em; text-align: center; text-indent: 0; margin: 0 0 1.2em 0; }
h1.coverstory { font-size: 1.5em; text-align: center; hyphens: none; margin: 0 0 0.3em 0; }
.coverdesc { font-style: italic; text-align: center; text-indent: 0; margin: 0 1em 1.5em 1em; }
h2.toc-section { font-family: sans-serif; font-size: 0.95em; font-weight: bold; text-transform: uppercase;
                 letter-spacing: 0.05em; text-align: left; border-bottom: 1px solid black;
                 margin: 1.3em 0 0.4em 0; page-break-after: avoid; }
h3.toc-sub { font-family: sans-serif; font-size: 0.85em; font-weight: bold; font-style: italic; text-align: left;
             margin: 0.8em 0 0.3em 0; page-break-after: avoid; }
ul.toc { list-style-type: none; margin: 0; padding: 0; }
ul.toc li { text-align: left; margin: 0 0 0.45em 0; }
.toc-tag { font-family: sans-serif; font-size: 0.7em; text-transform: uppercase; letter-spacing: 0.05em; }
.toc-author { font-size: 0.85em; font-style: italic; }
]]

local CONTAINER = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]]

-- Article types whose images are the content itself: always fetched, in the larger size.
local VISUAL = {
    paper_strisce = true, paper_vignette = true, paper_graphic_journalism = true,
    paper_fotobig = true, paper_portfolio = true,
}

local function esc(s)
    s = tostring(s or ""):gsub("[%z\1-\8\11\12\14-\31]", "")
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
Epub.escape = esc

-- Tags kept from the CMS markup (attributes are always dropped); everything else is unwrapped.
local TAGS = {
    p = "p", em = "em", i = "em", strong = "strong", b = "strong", u = "u", sup = "sup", sub = "sub",
    small = "small", ol = "ol", ul = "ul", li = "li", blockquote = "blockquote",
}
local XML_ENTITIES = { amp = true, lt = true, gt = true, quot = true, apos = true }

--- CMS HTML fragment -> well-formed XHTML fragment.
function Epub.sanitize(html)
    if type(html) ~= "string" then return "" end
    -- \1 \2 \3 are used below as placeholders for "&", "<" and ">" of markup we keep
    local s = html:gsub("[%z\1-\8\11\12\14-\31]", "")
    s = s:gsub("<!%-%-.-%-%->", ""):gsub("<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
         :gsub("<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>", "")
    s = s:gsub("&(#?[xX]?%w+);", function(e)
        if XML_ENTITIES[e] or e:match("^#[xX]%x+$") or e:match("^#%d+$") then
            return "\1" .. e .. ";"
        end
        local decoded = Api.decodeEntities("&" .. e .. ";")
        if decoded == "&" .. e .. ";" then
            return "\1amp;" .. e .. ";"
        end
        return decoded
    end)
    local stack = {}
    s = s:gsub("<(/?)([%a][%w]*)([^>]*)>", function(closing, name, rest)
        name = name:lower()
        if name == "br" then return "\2br/\3" end
        local tag = TAGS[name]
        if not tag then return "" end
        if closing == "" then
            if rest:match("/%s*$") then return "" end -- empty <p/> and the like
            table.insert(stack, tag)
            return "\2" .. tag .. "\3"
        end
        for i = #stack, 1, -1 do
            if stack[i] == tag then
                local out = {}
                for j = #stack, i, -1 do
                    table.insert(out, "\2/" .. stack[j] .. "\3")
                    stack[j] = nil
                end
                return table.concat(out)
            end
        end
        return "" -- stray closing tag
    end)
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub("\1", "&"):gsub("\2", "<"):gsub("\3", ">")
    for i = #stack, 1, -1 do
        s = s .. "</" .. stack[i] .. ">"
    end
    return s
end

--- Sanitized block of paragraphs; bare text gets wrapped in <p>.
local function paragraphs(html)
    local s = Epub.sanitize(html)
    s = s:gsub("<p>%s*</p>", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return "" end
    if not (s:find("^<p>") or s:find("^<ol>") or s:find("^<ul>") or s:find("^<blockquote>")) then
        s = "<p>" .. s .. "</p>"
    end
    return s
end

local OPENING_QUOTES = { "“", "«", "‘", '"', "'", "(" }

--- Bold initial on the first letter of the first paragraph (no floats: crengine pages them badly).
local function addInitial(x)
    local rest = x:match("^<p>(.*)$")
    if not rest then return x end
    local quote = ""
    for _, q in ipairs(OPENING_QUOTES) do
        if rest:sub(1, #q) == q then
            quote = q
            rest = rest:sub(#q + 1)
            break
        end
    end
    local ch = rest:match("^[%w\194-\244][\128-\191]*")
    if not ch then
        return (x:gsub("^<p>", '<p class="first">', 1))
    end
    return '<p class="first"><span class="initial">' .. quote .. ch .. "</span>" .. rest:sub(#ch + 1)
end

local function credits(d)
    local c = Api.cleanText(d.credits)
    if c then return c end
    local parts = {}
    for _, k in ipairs{ "author", "agency" } do
        local v = Api.cleanText(d[k])
        if v then table.insert(parts, v) end
    end
    if #parts > 0 then return table.concat(parts, ", ") end
end

local function figure(href, caption, credit, visual)
    local out = { '<div class="figure', visual and " visual" or "", '"><img src="', href, '" alt=""/>' }
    if caption or credit then
        table.insert(out, '<p class="caption">')
        if caption then table.insert(out, esc(caption)) end
        if credit then
            table.insert(out, (caption and " " or "") .. '<span class="credit">' .. esc(credit) .. "</span>")
        end
        table.insert(out, "</p>")
    end
    table.insert(out, "</div>\n")
    return table.concat(out)
end

local function xhtmlPage(title, body, body_class)
    return table.concat{
        '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html>\n',
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="it" lang="it">\n',
        '<head>\n<meta charset="UTF-8"/>\n<title>', esc(title), "</title>\n",
        '<link rel="stylesheet" type="text/css" href="style.css"/>\n</head>\n',
        "<body", body_class and (' class="' .. body_class .. '"') or "", ">\n",
        body,
        "\n</body>\n</html>\n",
    }
end

local function sniffImage(bytes)
    if type(bytes) ~= "string" or #bytes < 12 then return nil end
    if bytes:sub(1, 3) == "\255\216\255" then return ".jpg", "image/jpeg" end
    if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return ".png", "image/png" end
    if bytes:sub(1, 4) == "GIF8" then return ".gif", "image/gif" end
    if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then return ".webp", "image/webp" end
end

-- Builder ---------------------------------------------------------------------

local Builder = {}
Builder.__index = Builder

function Epub.Builder(o)
    local self = setmetatable(o, Builder)
    self.image_mode = self.image_mode or "normal"
    self.manifest = {}
    self.order = {}      -- article ids actually added, in reading order
    self.done = {}       -- article id -> { href=, title= }
    self.images = {}     -- url -> href, or false if it failed
    self.image_items = {} -- href -> manifest item
    self.n_images = 0
    self.failed_images = 0
    self.section_of = {}
    for i, s in ipairs(self.outline.sections) do
        for _, a in ipairs(s.articles) do self.section_of[a.id] = i end
        for _, c in ipairs(s.children) do
            for _, a in ipairs(c.articles) do self.section_of[a.id] = i end
        end
    end
    return self
end

function Builder:add(path, content, binary)
    if not self.writer:add(path, content, binary) then
        error("scrittura dell'EPUB non riuscita (" .. path .. ")")
    end
end

function Builder:addItem(id, href, media_type, properties)
    table.insert(self.manifest, { id = id, href = href, media_type = media_type, properties = properties })
    return self.manifest[#self.manifest]
end

function Builder:begin()
    self:add("mimetype", "application/epub+zip", true)
    self:add("META-INF/container.xml", CONTAINER)
    self:add("OEBPS/style.css", Epub.CSS)
    self:addItem("css", "style.css", "text/css")
end

--- Fetch the first candidate URL that yields an image; returns href, manifest item.
function Builder:image(candidates)
    for _, url in ipairs(candidates) do
        local known = self.images[url]
        if known then return known, self.image_items[known] end
        if known == nil then
            local bytes = self.fetch(url)
            local ext, media_type = sniffImage(bytes)
            if ext then
                self.n_images = self.n_images + 1
                local href = "images/i" .. self.n_images .. ext
                self:add("OEBPS/" .. href, bytes, true)
                self.image_items[href] = self:addItem("img" .. self.n_images, href, media_type)
                self.images[url] = href
                return href, self.image_items[href]
            end
            self.images[url] = false
        end
    end
    self.failed_images = self.failed_images + 1
end

function Builder:imageFor(d, visual)
    if self.image_mode == "visual" and not visual then return nil end
    local size = (self.image_mode == "high" or visual) and "md" or "sd"
    local urls = type(d.urls) == "table" and d.urls or {}
    local candidates = {}
    local function push(u)
        if type(u) ~= "string" or u == "" then return end
        for _, x in ipairs(candidates) do
            if x == u then return end
        end
        table.insert(candidates, u)
    end
    push(urls[size] or Api.imageVariant(d.url, size))
    if size == "md" then push(urls.sd or Api.imageVariant(d.url, "sd")) end
    push(d.url)
    if #candidates == 0 then return nil end
    return self:image(candidates)
end

function Builder:setCover()
    local issue = self.issue
    if not issue.cover then return end
    local href, item = self:image({ issue.cover, issue.cover_fallback })
    if href then
        item.properties = "cover-image"
        self.cover_item = item
        self.cover_href = href
    end
end

function Builder:addArticle(a, item)
    local visual = VISUAL[item.type] or false
    local blocks = item.content and type(item.content.data) == "table" and item.content.data or {}
    local out = {}
    local function w(...)
        for i = 1, select("#", ...) do
            out[#out + 1] = select(i, ...)
        end
    end

    local section = a.section
    local headers = type(item.tags_paper) == "table" and item.tags_paper.attr_testatina
    local print_header = type(headers) == "table" and type(headers[1]) == "table" and Api.cleanText(headers[1].name)
    -- the sommario files the features under a generic "Articoli": the print header says more
    if print_header and section == "Articoli" then section = print_header end
    local kicker = {}
    for _, k in ipairs{ section or "", a.subsection or "", a.tag or "" } do
        if k ~= "" then table.insert(kicker, k) end
    end
    if #kicker > 0 then
        w('<p class="kicker">', esc(table.concat(kicker, " · ")), "</p>\n")
    end
    local title = (a.title and a.title ~= "" and a.title) or Api.cleanText(item.title) or "Senza titolo"
    w('<h1 class="title">', esc(title), "</h1>\n")

    local summary_block
    for _, b in ipairs(blocks) do
        if b.type == "summary" then
            summary_block = b
            local t = Api.cleanText(type(b.data) == "table" and b.data.text)
            if t then w('<p class="standfirst">', esc(t), "</p>\n") end
            break
        end
    end

    local names = Api.authorNames(item.authors_list)
    if #names == 0 then names = a.authors or {} end
    local origin = {}
    local fonte = type(item.authors_fonte) == "table" and Api.cleanText(item.authors_fonte.name)
    if fonte then table.insert(origin, fonte) end
    local paese = type(item.authors_paese) == "table" and Api.cleanText(item.authors_paese.name)
    if paese then
        paese = paese:gsub("^Magazine,%s*", "")
        if paese ~= "" then table.insert(origin, paese) end
    end
    if #names > 0 or #origin > 0 then
        w('<p class="byline">')
        if #names > 0 then w('<span class="author">', esc(table.concat(names, ", ")), "</span>") end
        if #origin > 0 then
            w(#names > 0 and ", " or "", '<span class="source">', esc(table.concat(origin, ", ")), "</span>")
        end
        w("</p>\n")
    end

    if type(item.article_img) == "table" then
        local href = self:imageFor(item.article_img, visual)
        if href then
            w(figure(href, Api.cleanText(item.article_img.caption), credits(item.article_img), visual))
        end
    end

    local open_boxes, noindent, initial_done = 0, true, false
    for _, b in ipairs(blocks) do
        local t = b.type or ""
        local d = type(b.data) == "table" and b.data or {}
        if b == summary_block or t:match("^ad") or t:match("^cta_") then -- luacheck: ignore 542
            -- ads and "read also" links to the website
        elseif t == "text" or t == "dropcap" or t == "olist" then
            local x = paragraphs(d.text)
            if x ~= "" then
                if t == "dropcap" and not initial_done then
                    x = addInitial(x)
                    initial_done = true
                elseif noindent then
                    x = x:gsub("^<p>", '<p class="noindent">', 1)
                end
                w(x, "\n")
                noindent = false
            end
        elseif t == "innerheading" or t == "heading" then
            local h = Api.cleanText(d.text)
            if h then
                local tag = t == "heading" and "h2" or "h3"
                w("<", tag, ' class="subhead">', esc(h), "</", tag, ">\n")
                noindent = true
            end
        elseif t == "image" then
            local href = self:imageFor(d, visual)
            if href then
                w(figure(href, Api.cleanText(d.caption) or Api.cleanText(d.dida), credits(d), visual))
                noindent = true
            end
        elseif t == "quote" then
            local x = paragraphs(d.text)
            if x ~= "" then
                w('<blockquote class="pullquote">', x, "</blockquote>\n")
                noindent = true
            end
        elseif t == "infobox" then
            w('<div class="box">\n')
            open_boxes = open_boxes + 1
            local heading = Api.cleanText(d.infobox_heading)
            local subtitle = Api.cleanText(d.infobox_title)
            if heading or subtitle then
                w('<p class="box-title">', esc(heading or subtitle), "</p>\n")
            end
            if heading and subtitle and subtitle ~= heading then
                w('<p class="box-subtitle">', esc(subtitle), "</p>\n")
            end
            noindent = true
        elseif t == "infoboxend" then
            if open_boxes > 0 then
                w("</div>\n")
                open_boxes = open_boxes - 1
            end
            noindent = true
        elseif t == "minireview" then
            w('<div class="minireview">\n')
            local work = Api.cleanText(d.opera_titolo)
            local author = Api.cleanText(d.opera_autore)
            local italic = Api.cleanText(d.corsivo)
            local producer = Api.cleanText(d.opera_produttore)
            if work or author or italic or producer then
                w('<p class="work">')
                if work then w("<strong>", esc(work), "</strong>") end
                if author then w(work and ", " or "", esc(author)) end
                if italic then w((work or author) and " " or "", "<em>", esc(italic), "</em>") end
                if producer then w(", ", esc(producer)) end
                w("</p>\n")
            end
            w(paragraphs(d.text or d.testo), "\n</div>\n")
        elseif t == "note" then
            local x = paragraphs(d.text)
            if x ~= "" then w('<div class="note">', x, "</div>\n") end
        elseif t == "line" then
            w("<hr/>\n")
            noindent = true
        elseif t == "portrait_name" or t == "portrait_title" then
            local x = Api.cleanText(d.text)
            if x then w('<p class="', (t:gsub("_", "-")), '">', esc(x), "</p>\n") end
            noindent = true
        elseif type(d.text) == "string" then
            -- unknown block type that still carries text
            local x = paragraphs(d.text)
            if x ~= "" then w(x, "\n") end
        end
    end
    for _ = 1, open_boxes do w("</div>\n") end

    local pa = type(item.paper_attributes) == "table" and item.paper_attributes or {}
    if not self.issue_date and type(pa.issue_date) == "string" and pa.issue_date:match("^%d%d%d%d%-%d%d%-%d%d$") then
        self.issue_date = pa.issue_date
    end
    local ref = "Internazionale " .. tostring(self.issue.number)
    if pa.issue_page and tostring(pa.issue_page) ~= "" and tostring(pa.issue_page) ~= "0" then
        ref = ref .. " · pagina " .. tostring(pa.issue_page)
    end
    w('<p class="issue-ref">', esc(ref), "</p>\n")
    local sec = self.section_of[a.id]
    w('<p class="backlink"><a href="sommario.xhtml', sec and ("#s" .. sec) or "", '">Torna al sommario</a></p>')

    local href = "a" .. a.id .. ".xhtml"
    self:add("OEBPS/" .. href, xhtmlPage(title, table.concat(out), "article"))
    self:addItem("a" .. a.id, href, "application/xhtml+xml")
    self.done[a.id] = { href = href, title = title }
    table.insert(self.order, a.id)
end

-- Table of contents -------------------------------------------------------------

function Builder:tocTree()
    local tree = {}
    if self.cover_href then
        table.insert(tree, { label = "Copertina", href = "cover.xhtml" })
    end
    table.insert(tree, { label = "Sommario", href = "sommario.xhtml" })
    local function leaves(list, articles)
        for _, a in ipairs(articles) do
            local d = self.done[a.id]
            if d then table.insert(list, { label = d.title, href = d.href }) end
        end
    end
    for _, s in ipairs(self.outline.sections) do
        local node = { label = s.title ~= "" and s.title or "Articoli", children = {} }
        leaves(node.children, s.articles)
        for _, c in ipairs(s.children) do
            local sub = { label = c.title ~= "" and c.title or node.label, children = {} }
            leaves(sub.children, c.articles)
            if #sub.children > 0 then
                sub.href = sub.children[1].href
                table.insert(node.children, sub)
            end
        end
        if #node.children > 0 then
            node.href = node.children[1].href
            table.insert(tree, node)
        end
    end
    return tree
end

function Builder:issueTitle()
    local t = "Internazionale " .. tostring(self.issue.number)
    if self.issue.title then t = t .. " – " .. self.issue.title end
    return t
end

function Builder:sommarioPage()
    local issue = self.issue
    local out = { '<p class="masthead">Internazionale</p>\n' }
    local line = "Numero " .. tostring(issue.number)
    if issue.date_text then line = line .. " · " .. issue.date_text end
    table.insert(out, '<p class="issue-line">' .. esc(line) .. "</p>\n")
    if issue.title then table.insert(out, '<h1 class="coverstory">' .. esc(issue.title) .. "</h1>\n") end
    if issue.description then table.insert(out, '<p class="coverdesc">' .. esc(issue.description) .. "</p>\n") end

    local function list(articles)
        local items = {}
        for _, a in ipairs(articles) do
            local d = self.done[a.id]
            if d then
                local li = { "<li>" }
                if a.tag then table.insert(li, '<span class="toc-tag">' .. esc(a.tag) .. "</span> ") end
                table.insert(li, '<a href="' .. d.href .. '">' .. esc(d.title) .. "</a>")
                if a.authors and #a.authors > 0 then
                    table.insert(li, ' <span class="toc-author">' .. esc(table.concat(a.authors, ", ")) .. "</span>")
                end
                table.insert(li, "</li>\n")
                table.insert(items, table.concat(li))
            end
        end
        if #items == 0 then return nil end
        return '<ul class="toc">\n' .. table.concat(items) .. "</ul>\n"
    end

    for i, s in ipairs(self.outline.sections) do
        local parts = {}
        local direct = list(s.articles)
        if direct then table.insert(parts, direct) end
        for _, c in ipairs(s.children) do
            local sub = list(c.articles)
            if sub then
                table.insert(parts, '<h3 class="toc-sub">' .. esc(c.title) .. "</h3>\n" .. sub)
            end
        end
        if #parts > 0 then
            table.insert(out, '<h2 class="toc-section" id="s' .. i .. '">' .. esc(s.title ~= "" and s.title or "Articoli") .. "</h2>\n")
            table.insert(out, table.concat(parts))
        end
    end
    return xhtmlPage("Sommario", table.concat(out), "sommario")
end

function Builder:finish()
    if self.cover_href then
        self:add("OEBPS/cover.xhtml", xhtmlPage("Copertina",
            '<div class="cover"><img src="' .. self.cover_href .. '" alt="Copertina"/></div>', "cover"))
        self:addItem("cover", "cover.xhtml", "application/xhtml+xml")
    end
    self:add("OEBPS/sommario.xhtml", self:sommarioPage())
    self:addItem("sommario", "sommario.xhtml", "application/xhtml+xml")

    local spine = {}
    if self.cover_href then table.insert(spine, { id = "cover", href = "cover.xhtml" }) end
    table.insert(spine, { id = "sommario", href = "sommario.xhtml" })
    for _, id in ipairs(self.order) do
        table.insert(spine, { id = "a" .. id, href = self.done[id].href })
    end
    local play_order = {}
    for i, s in ipairs(spine) do play_order[s.href] = i end

    local tree = self:tocTree()
    local title = self:issueTitle()
    local uid = "urn:internazionale:numero:" .. tostring(self.issue.number)
    local date = self.issue_date or self.issue.date

    -- EPUB 3 navigation document
    local nav = {}
    local function navList(nodes, depth)
        local ind = string.rep("  ", depth)
        table.insert(nav, ind .. "<ol>\n")
        for _, n in ipairs(nodes) do
            table.insert(nav, ind .. '  <li><a href="' .. n.href .. '">' .. esc(n.label) .. "</a>")
            if n.children and #n.children > 0 then
                table.insert(nav, "\n")
                navList(n.children, depth + 2)
                table.insert(nav, ind .. "  ")
            end
            table.insert(nav, "</li>\n")
        end
        table.insert(nav, ind .. "</ol>\n")
    end
    navList(tree, 1)
    self:add("OEBPS/nav.xhtml", xhtmlPage("Indice",
        '<nav epub:type="toc" id="toc">\n  <h1>Indice</h1>\n' .. table.concat(nav) .. "</nav>", "nav"))

    -- EPUB 2 NCX
    local ncx, n_points, max_depth = {}, 0, 1
    local function navPoints(nodes, depth)
        if depth > max_depth then max_depth = depth end
        local ind = string.rep("  ", depth + 1)
        for _, n in ipairs(nodes) do
            n_points = n_points + 1
            table.insert(ncx, string.format('%s<navPoint id="np%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="%s"/>',
                ind, n_points, play_order[n.href] or 1, esc(n.label), n.href))
            if n.children and #n.children > 0 then
                table.insert(ncx, "\n")
                navPoints(n.children, depth + 1)
                table.insert(ncx, ind)
            end
            table.insert(ncx, "</navPoint>\n")
        end
    end
    navPoints(tree, 1)
    self:add("OEBPS/toc.ncx", table.concat{
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="it">\n',
        '  <head>\n    <meta name="dtb:uid" content="', esc(uid), '"/>\n',
        '    <meta name="dtb:depth" content="', tostring(max_depth), '"/>\n',
        '    <meta name="dtb:totalPageCount" content="0"/>\n    <meta name="dtb:maxPageNumber" content="0"/>\n  </head>\n',
        "  <docTitle><text>", esc(title), "</text></docTitle>\n",
        "  <navMap>\n", table.concat(ncx), "  </navMap>\n</ncx>\n",
    })

    -- Package document
    local opf = {
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="it">\n',
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\n',
        '    <dc:identifier id="bookid">', esc(uid), "</dc:identifier>\n",
        "    <dc:title>", esc(title), "</dc:title>\n",
        "    <dc:creator>Internazionale</dc:creator>\n",
        "    <dc:publisher>Internazionale</dc:publisher>\n",
        "    <dc:language>it</dc:language>\n",
    }
    if date then table.insert(opf, "    <dc:date>" .. esc(date) .. "</dc:date>\n") end
    if self.issue.description then
        table.insert(opf, "    <dc:description>" .. esc(self.issue.description) .. "</dc:description>\n")
    end
    table.insert(opf, '    <meta property="dcterms:modified">' .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. "</meta>\n")
    table.insert(opf, '    <meta property="belongs-to-collection" id="series">Internazionale</meta>\n')
    table.insert(opf, '    <meta refines="#series" property="collection-type">series</meta>\n')
    table.insert(opf, '    <meta refines="#series" property="group-position">' .. tostring(self.issue.number) .. "</meta>\n")
    table.insert(opf, '    <meta name="calibre:series" content="Internazionale"/>\n')
    table.insert(opf, '    <meta name="calibre:series_index" content="' .. tostring(self.issue.number) .. '"/>\n')
    if self.cover_item then
        table.insert(opf, '    <meta name="cover" content="' .. self.cover_item.id .. '"/>\n')
    end
    table.insert(opf, "  </metadata>\n  <manifest>\n")
    table.insert(opf, '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n')
    table.insert(opf, '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n')
    for _, m in ipairs(self.manifest) do
        table.insert(opf, string.format('    <item id="%s" href="%s" media-type="%s"%s/>\n',
            m.id, m.href, m.media_type, m.properties and (' properties="' .. m.properties .. '"') or ""))
    end
    table.insert(opf, '  </manifest>\n  <spine toc="ncx">\n')
    for _, s in ipairs(spine) do
        table.insert(opf, '    <itemref idref="' .. s.id .. '"/>\n')
    end
    table.insert(opf, "  </spine>\n</package>\n")
    self:add("OEBPS/content.opf", table.concat(opf))
end

return Epub
