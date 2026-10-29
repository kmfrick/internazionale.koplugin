--[[
Unit checks for the plugin's pure functions, run with KOReader's LuaJIT:

  cd <koreader>/lib/koreader
  ./luajit <repo>/tests/unit.lua <repo>/internazionale.koplugin [corpus_dir]
]]

local plugin_dir, corpus = arg[1], arg[2]
require("setupkoenv")
package.path = plugin_dir .. "/?.lua;" .. package.path
package.loaded["socketutil"] = { USER_AGENT = "test" }

local Api = require("internaz_api")
local Epub = require("internaz_epub")
local mime = require("mime")
local rapidjson = require("rapidjson")

local failures = 0
local function eq(got, want, what)
    if got ~= want then
        failures = failures + 1
        print(("FAIL %s\n  got:  %s\n  want: %s"):format(what, tostring(got), tostring(want)))
    end
end

-- sanitize
eq(Epub.sanitize("<p>Ciao <strong>mondo</strong></p>\n"), "<p>Ciao <strong>mondo</strong></p>\n", "keeps simple markup")
eq(Epub.sanitize("<p class='x'>a <a href='/y?a=1&b=2'>link</a></p>"), "<p>a link</p>", "drops attributes and links")
eq(Epub.sanitize("<p>uno<br>due</p>"), "<p>uno<br/>due</p>", "self-closes br")
eq(Epub.sanitize("<p>Tom & Jerry &rsquo;s &amp; &#8217; &bogus;</p>"), "<p>Tom &amp; Jerry ’s &amp; &#8217; &amp;bogus;</p>", "entities")
eq(Epub.sanitize("<p><em>aperto</p>"), "<p><em>aperto</em></p>", "closes unbalanced tags")
eq(Epub.sanitize("a < b > c</em>"), "a &lt; b &gt; c", "escapes stray brackets, drops stray closers")
eq(Epub.sanitize("<p><b>x</b><i>y</i></p>"), "<p><strong>x</strong><em>y</em></p>", "maps b/i")
eq(Epub.sanitize("<div><span>t</span></div><p/>"), "t", "unwraps unknown tags, drops empty elements")
eq(Epub.sanitize("x\1y\2z\3"), "xyz", "strips control characters")
eq(Epub.escape('<"&>'), "&lt;&quot;&amp;&gt;", "escape")

-- entities and text
eq(Api.decodeEntities("&egrave; &#232; &#xE8; &nope;"), "è è è &nope;", "decodeEntities")
eq(Api.cleanText("  <p>Una   <em>prova</em>&nbsp;</p> "), "Una prova", "cleanText trims nbsp too")

-- dates and images
eq(Api.parseItalianDate("30 ottobre 2026 • Numero 1689"), "2026-10-30", "parseItalianDate")
eq(Api.parseItalianDate("1 Gennaio 2027"), "2027-01-01", "parseItalianDate capitalised")
eq(Api.imageVariant("https://media.internazionale.it/images/2026/10/28/362399-ld.jpg", "md"),
    "https://media.internazionale.it/images/2026/10/28/362399-md.jpg", "imageVariant")
eq(Api.imageVariant("https://media.internazionale.it/images/2026/10/28/362399.jpg", "md"),
    "https://media.internazionale.it/images/2026/10/28/362399.jpg", "imageVariant without size")

-- token
local function b64url(s) return (mime.b64(s):gsub("%+", "-"):gsub("/", "_"):gsub("=", "")) end
local payload = rapidjson.encode({
    exp = 2000000000, email = "a@b.c", is_subscribed = "false",
    in_subscription = { is_subscribed = "true", subscription_end_date = "1893456000" },
})
local token = b64url('{"typ":"JWT","alg":"HS256"}') .. "." .. b64url(payload) .. ".c2ln"
local st = Api.tokenStatus(token, 1900000000)
eq(st.valid, true, "token valid")
eq(st.subscribed, true, "token subscribed (in_subscription wins)")
eq(st.subscription_end, 1893456000, "token subscription end")
eq(Api.tokenStatus(token, 2000000000).valid, false, "token expired")
eq(Api.tokenStatus("garbage").valid, false, "garbage token")

-- the cookie goes to the site's hosts only, redirects included
eq(Api.isSiteHost("https://data.internazionale.it/x.json"), true, "subdomain is site")
eq(Api.isSiteHost("https://internazionale.it/"), true, "apex is site")
eq(Api.isSiteHost("https://evilinternazionale.it/"), false, "look-alike is not site")
eq(Api.isSiteHost("https://internazionale.it.example.com/"), false, "suffix trick is not site")
eq(Api.isSiteHost("http://www.internazionale.it/"), false, "plain http is not site")
eq(Api.isSiteHost("https://www.internazionale.it:x@evil.com/a.jpg"), false, "userinfo trick is not site")
eq(Api.isSiteHost("https://www.internazionale.it:443/x"), true, "explicit port is site")
local seen = {}
local api = Api:new{ token = "T", transport = function(req)
    table.insert(seen, { url = req.url, cookie = req.headers["Cookie"] })
    if req.url == "https://media.internazionale.it/a.jpg" then
        return 302, "", { location = "https://cdn.example.com/a.jpg" }
    end
    return 200, "IMG", {}
end }
local code, body, rerr = api:request{ url = "https://media.internazionale.it/a.jpg" }
eq(code, 200, "redirect followed")
eq(body, "IMG", "redirect body")
eq(rerr, nil, "no error string on success")
eq(seen[1].cookie, "internaz_auth_tkn=T", "cookie sent to the site")
eq(seen[2] and seen[2].url, "https://cdn.example.com/a.jpg", "redirect target")
eq(seen[2] and seen[2].cookie, nil, "no cookie once off the site")
local downgrade = Api:new{ token = "T", transport = function(req)
    if req.url:match("^https://") then return 301, "", { location = "http://www.internazionale.it/x" } end
    return 200, "PLAIN", {}
end }
eq((downgrade:request{ url = "https://www.internazionale.it/x" }), 301, "no redirect down to http")
local hops = {}
local relative = Api:new{ transport = function(req)
    table.insert(hops, req.url)
    if #hops == 1 then return 302, "", { location = "b/c" } end
    if #hops == 2 then return 302, "", { location = "//media.internazionale.it/d" } end
    return 200, "", {}
end }
relative:request{ url = "https://www.internazionale.it/a/x.html" }
eq(hops[2], "https://www.internazionale.it/a/b/c", "relative location")
eq(hops[3], "https://media.internazionale.it/d", "protocol-relative location")

-- real responses
if corpus then
    local function readFile(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
    local meta = Api.parseIssuePage(readFile(corpus .. "/sommario.html"))
    eq(meta and meta.number, 1689, "issue number")
    eq(meta and meta.stream_id, "11532", "stream id")
    eq(meta and meta.title, "Se cambia il vento", "cover story")
    eq(meta and meta.date, "2026-10-30", "issue date")
    eq(meta and meta.prev, 1688, "previous issue")
    eq(meta and meta.cover, "https://media.internazionale.it/images/2026/10/29/362497-md.png", "cover md")
    local outline = Api.parseOutline(Api.decodeJSON(readFile(corpus .. "/sommario.json")))
    eq(outline and #outline.articles, 94, "articles in sommario")
    eq(outline and outline.sections[1].title, "La settimana", "first section")
    local cultura
    for _, s in ipairs(outline.sections) do if s.title == "Cultura" then cultura = s end end
    eq(cultura and #cultura.children, 4, "Cultura subsections")
    for _, s in ipairs(outline.sections) do
        eq(s.title ~= "Oroscopo", true, "link-only sections dropped")
    end
end

print(failures == 0 and "all unit checks passed" or (failures .. " failures"))
os.exit(failures == 0 and 0 or 1)
