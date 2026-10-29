--[[--
Client for the internazionale.it endpoints used by the website itself.

  * www.internazionale.it/sommario[/N]                    issue page (HTML): stream id, cover, cover story
  * data.internazionale.it/stream_data/items/sommario/... table of contents of an issue (JSON)
  * data.internazionale.it/stream_data/item/article/ID    one article as structured blocks (JSON)
  * api.internazionale.it/users/login/                    login, returns the JWT the site keeps in the
                                                          internaz_auth_tkn cookie (valid for 7 days)

Like the browser, requests to *.internazionale.it carry the account cookie (the login itself excepted);
it is never sent to any other host, redirects included.
]]

local logger = require("logger")
local mime = require("mime")
local rapidjson = require("rapidjson")
local util = require("util")

local Api = {
    SITE = "https://www.internazionale.it",
    DATA = "https://data.internazionale.it/stream_data",
    AUTH = "https://api.internazionale.it",
    COOKIE = "internaz_auth_tkn",
}

local MONTHS = {
    gennaio = 1, febbraio = 2, marzo = 3, aprile = 4, maggio = 5, giugno = 6,
    luglio = 7, agosto = 8, settembre = 9, ottobre = 10, novembre = 11, dicembre = 12,
}

function Api:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- rapidjson decodes JSON null as rapidjson.null, a truthy lightuserdata: turn those into nil.
local function stripNulls(t)
    for k, v in pairs(t) do
        if v == rapidjson.null then
            t[k] = nil
        elseif type(v) == "table" then
            stripNulls(v)
        end
    end
    return t
end

local function decodeJSON(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, data = pcall(rapidjson.decode, body)
    if ok and type(data) == "table" then
        return stripNulls(data)
    end
end
Api.decodeJSON = decodeJSON

-- util.htmlEntitiesToUtf8 only knows the XML ones and numeric references.
local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\u{00A0}",
    rsquo = "’", lsquo = "‘", rdquo = "”", ldquo = "“", laquo = "«", raquo = "»",
    hellip = "…", ndash = "–", mdash = "—", middot = "·", bull = "•", deg = "°", euro = "€",
    agrave = "à", aacute = "á", egrave = "è", eacute = "é", igrave = "ì", iacute = "í",
    ograve = "ò", oacute = "ó", ugrave = "ù", uacute = "ú", Agrave = "À", Egrave = "È",
    Eacute = "É", Igrave = "Ì", Ograve = "Ò", Ugrave = "Ù", ccedil = "ç", ntilde = "ñ",
    auml = "ä", ouml = "ö", uuml = "ü", szlig = "ß",
}

function Api.decodeEntities(s)
    return (s:gsub("&(#?[xX]?%w+);", function(e)
        local hex = e:match("^#[xX](%x+)$")
        if hex then return util.unicodeCodepointToUtf8(tonumber(hex, 16)) end
        local dec = e:match("^#(%d+)$")
        if dec then return util.unicodeCodepointToUtf8(tonumber(dec)) end
        return NAMED_ENTITIES[e]
    end))
end

local function cleanText(s)
    if type(s) ~= "string" then return nil end
    s = Api.decodeEntities((s:gsub("<[^>]*>", "")))
    -- %s doesn't cover the UTF-8 no-break space
    s = util.trim((s:gsub("\194\160", " "):gsub("%s+", " ")))
    if s == "" then return nil end
    return s
end
Api.cleanText = cleanText

--- Default transport: LuaSocket (+ LuaSec for https), as used by the other KOReader plugins.
local function socketTransport(req)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    if req.large then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    -- table_sink reads the total timeout when it is created, so only after set_timeout
    local chunks = {}
    local request = {
        url = req.url,
        method = req.method or "GET",
        headers = req.headers,
        sink = socketutil.table_sink(chunks),
        redirect = false, -- followed in Api:request, so the cookie never leaves the site
    }
    if req.body then
        request.source = ltn12.source.string(req.body)
    end
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if headers == nil then
        return nil, nil, tostring(status or code)
    end
    return code, table.concat(chunks), headers
end

--- True for https URLs on internazionale.it or one of its subdomains.
function Api.isSiteHost(url)
    -- authority as LuaSocket's url.parse sees it: everything up to the path, query or fragment
    local authority = type(url) == "string" and url:match("^https://([^/?#]*)")
    -- user:pass@host would make the host the part after "@": never send the cookie there
    if not authority or authority:find("@", 1, true) then return false end
    local host = authority:gsub(":%d*$", ""):lower()
    if host:find(":", 1, true) then return false end
    local suffix = ".internazionale.it"
    return host == "internazionale.it" or host:sub(-#suffix) == suffix
end

--- Absolute URL for a Location header; nil for anything we won't follow (e.g. a downgrade to http).
local function resolveLocation(base, location)
    if location:match("^https://") then return location end
    if location:match("^//") then return "https:" .. location end
    if location:match("^%a[%w+.%-]*:") then return nil end
    local origin, path = base:match("^(https://[^/?#]+)([^?#]*)")
    if not origin then return nil end
    if location:sub(1, 1) == "/" then return origin .. location end
    return origin .. (path:gsub("[^/]*$", "")) .. location
end

local REDIRECTS = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

--- Returns code, body (or nil, nil, error message on network failure).
function Api:request(req)
    local transport = self.transport or socketTransport
    local method = req.method or "GET"
    local url = req.url
    for _ = 1, 5 do
        local headers = {}
        for k, v in pairs(req.headers or {}) do headers[k] = v end
        headers["User-Agent"] = headers["User-Agent"] or require("socketutil").USER_AGENT
        if self.token and not req.no_auth and Api.isSiteHost(url) then
            headers["Cookie"] = Api.COOKIE .. "=" .. self.token
        end
        if req.body then
            headers["Content-Length"] = tostring(#req.body)
        end
        local code, body, extra = transport{
            url = url, method = method, headers = headers, body = req.body, large = req.large,
        }
        -- on success the transport's third value is the response headers, on failure an error string
        local err = type(extra) == "string" and extra or nil
        local location = type(extra) == "table" and extra.location
        if method == "GET" and REDIRECTS[code] and type(location) == "string" then
            url = resolveLocation(url, location)
            if not url then return code, body end
        else
            if code ~= 200 then
                logger.warn("Internazionale:", method, url, "->", code, err)
            end
            return code, body, err
        end
    end
    return nil, nil, "troppi redirect"
end

function Api:getJSON(url)
    local code, body, err = self:request{ url = url }
    if not code then return nil, "rete: " .. tostring(err) end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    local data = decodeJSON(body)
    if not data then return nil, "risposta non valida" end
    return data
end

function Api:getBinary(url)
    local code, body, err = self:request{ url = url, large = true }
    if code == 200 and body and #body > 0 then
        return body
    end
    return nil, code and ("HTTP " .. tostring(code)) or err
end

-- Authentication ------------------------------------------------------------

local function b64urlDecode(s)
    s = s:gsub("%-", "+"):gsub("_", "/")
    local pad = #s % 4
    if pad > 0 then
        s = s .. string.rep("=", 4 - pad)
    end
    return mime.unb64(s)
end

function Api.decodeToken(token)
    if type(token) ~= "string" then return nil end
    local payload = token:match("^[%w%-_]+%.([%w%-_]+)%.[%w%-_]+$")
    if not payload then return nil end
    return decodeJSON(b64urlDecode(payload))
end

--- Expiry and subscription status from the JWT payload, used for the account menu and to know when to log in again.
function Api.tokenStatus(token, now)
    local p = Api.decodeToken(token)
    if not p then
        return { valid = false }
    end
    now = now or os.time()
    local sub = type(p.in_subscription) == "table" and p.in_subscription or p
    local exp = tonumber(p.exp) or 0
    return {
        valid = exp > now + 600,
        expires = exp,
        subscribed = tostring(sub.is_subscribed) == "true",
        subscription_end = tonumber(sub.subscription_end_date),
        email = p.email,
        firstname = p.firstname,
    }
end

function Api:login(email, password)
    local body = rapidjson.encode({ email = email, psw = password })
    local code, resp, err = self:request{
        url = Api.AUTH .. "/users/login/",
        method = "POST",
        no_auth = true,
        body = body,
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Accept"] = "application/json, text/plain, */*",
            ["Origin"] = "https://utente.internazionale.it",
            ["Referer"] = "https://utente.internazionale.it/login",
        },
    }
    if not code then
        return nil, "Rete non disponibile (" .. tostring(err) .. ")"
    end
    local data = decodeJSON(resp)
    local info = data and type(data.info) == "table" and data.info or {}
    if code == 200 and data and data.response == "ok" and type(info.token) == "string" and info.token ~= "" then
        self.token = info.token
        return info.token
    end
    local msg = type(info.message) == "string" and info.message or nil
    return nil, msg or ("Accesso non riuscito (HTTP " .. tostring(code) .. ")")
end

-- Issues --------------------------------------------------------------------

function Api.parseItalianDate(s)
    if type(s) ~= "string" then return nil end
    local d, m, y = s:lower():match("(%d+)%s+(%a+)%s+(%d%d%d%d)")
    local month = m and MONTHS[m]
    if not month then return nil end
    return string.format("%04d-%02d-%02d", tonumber(y), month, tonumber(d))
end

--- Variant of a media.internazionale.it image URL: ld (320px), sd (640), md (1200), hd (2048).
function Api.imageVariant(url, size)
    if type(url) ~= "string" then return nil end
    local base, ext = url:match("^(.-)%-%a%a(%.%a+)$")
    if base then
        return base .. "-" .. size .. ext
    end
    return url
end

--- Parse an issue page (www.internazionale.it/sommario[/N]).
function Api.parseIssuePage(html)
    local meta = {}
    meta.stream_id = html:match('data%-stream%-page="sommario"[^>]-data%-stream%-id="(%d+)"')
        or html:match('data%-stream%-id="(%d+)"[^>]-data%-stream%-page="sommario"')
    local brief = cleanText(html:match('class="page_context__brief[^"]*">(.-)</div>'))
    if brief then
        meta.number = tonumber(brief:match("Numero%s+(%d+)"))
        meta.date_text = cleanText(brief:match("^(.-)•")) or brief
        meta.date = Api.parseItalianDate(brief)
    end
    if not meta.number then
        meta.number = tonumber((html:match("<title>.-Numero%s+(%d+)")))
    end
    meta.title = cleanText(html:match('class="page_context__title[^"]*">(.-)</h1>'))
    meta.description = cleanText(html:match('class="page_context__content[^"]*">(.-)</div>'))
    local cover = html:match('class="page_context__img.-<img src="([^"]+)"')
    if cover then
        meta.cover = Api.imageVariant(cover, "md")
        meta.cover_fallback = cover
    end
    meta.prev = tonumber((html:match('class="arrow_prev" href="/sommario/(%d+)"')))
    if not meta.stream_id or not meta.number then
        return nil
    end
    return meta
end

--- Issue metadata; number=nil means the latest issue.
function Api:fetchIssue(number)
    local url = Api.SITE .. "/sommario" .. (number and ("/" .. tostring(number)) or "")
    local code, html, err = self:request{ url = url }
    if not code then return nil, "rete: " .. tostring(err) end
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    local meta = Api.parseIssuePage(html)
    if not meta then return nil, "pagina del sommario non riconosciuta" end
    return meta
end

local function authorNames(list)
    local names = {}
    if type(list) == "table" then
        for _, a in ipairs(list) do
            local n = type(a) == "table" and cleanText(a.name)
            if n then table.insert(names, n) end
        end
    end
    return names
end
Api.authorNames = authorNames

--[[--
Turn the sommario JSON into an outline:
  sections = { { title=, articles={...}, children={ { title=, articles={...} } } } }
  articles = flat list in reading order: { id=, title=, tag=, authors={}, section=, subsection= }
]]
function Api.parseOutline(sommario)
    local item = type(sommario) == "table" and type(sommario.items) == "table" and sommario.items[1]
    local blocks = item and item.content and item.content.data
    if type(blocks) ~= "table" then return nil end

    local sections, articles, seen = {}, {}, {}
    local section, subsection
    local function newSection(title)
        section = { title = title or "", articles = {}, children = {} }
        table.insert(sections, section)
        subsection = nil
    end
    for _, b in ipairs(blocks) do
        local t, d = b.type or "", type(b.data) == "table" and b.data or {}
        if t == "abs_testatina" then
            newSection(cleanText(d.text) or cleanText(d.tag_name))
        elseif t == "abs_testatina_cultura" then
            if not section then newSection("") end
            subsection = { title = cleanText(d.text) or cleanText(d.tag_name) or "", articles = {} }
            table.insert(section.children, subsection)
        elseif t:match("^abs_article") and d.post_id then
            local id = tostring(d.post_id)
            if not seen[id] then
                seen[id] = true
                if not section then newSection("") end
                local a = {
                    id = id,
                    title = cleanText(d.title) or cleanText(d.post_title) or "",
                    tag = cleanText(d.tag),
                    authors = authorNames(d.authors),
                    section = section.title,
                    subsection = subsection and subsection.title,
                }
                table.insert((subsection or section).articles, a)
                table.insert(articles, a)
            end
        end
    end
    -- drop sections that only held web links (e.g. the horoscope)
    for i = #sections, 1, -1 do
        local s = sections[i]
        for j = #s.children, 1, -1 do
            if #s.children[j].articles == 0 then table.remove(s.children, j) end
        end
        if #s.articles == 0 and #s.children == 0 then table.remove(sections, i) end
    end
    return { sections = sections, articles = articles }
end

function Api:fetchOutline(stream_id)
    local data, err = self:getJSON(string.format("%s/items/sommario/200/%s/0.json", Api.DATA, stream_id))
    if not data then return nil, err end
    local outline = Api.parseOutline(data)
    if not outline or #outline.articles == 0 then
        return nil, "sommario vuoto"
    end
    return outline
end

function Api:fetchArticle(id)
    local data, err = self:getJSON(string.format("%s/item/article/%s.json", Api.DATA, id))
    if not data then return nil, err end
    local item = type(data.items) == "table" and data.items[1]
    if type(item) ~= "table" then return nil, "articolo vuoto" end
    return item
end

return Api
