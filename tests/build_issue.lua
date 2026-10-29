--[[
Builds an issue EPUB with the plugin's modules, outside the KOReader UI, using KOReader's own
LuaJIT and libraries (rapidjson, libarchive, LuaSec).

  cd <koreader>/lib/koreader
  # offline, from saved responses (sommario.html, sommario.json, a_<id>.json, sample.jpg, sample.png):
  ./luajit <repo>/tests/build_issue.lua <repo>/internazionale.koplugin out.epub <corpus_dir>
  # live (ISSUE=1688 for a back issue, IMAGES=normal|high|visual); in bash/zsh, read keeps the token out of history:
  read -rs INTERNAZ_TOKEN && export INTERNAZ_TOKEN
  ./luajit <repo>/tests/build_issue.lua <repo>/internazionale.koplugin out.epub
]]

local plugin_dir, out_path, corpus = arg[1], arg[2], arg[3]
assert(plugin_dir and out_path, "usage: build_issue.lua <plugin_dir> <out.epub> [corpus_dir]")
assert(corpus or os.getenv("INTERNAZ_TOKEN"), "live build: set INTERNAZ_TOKEN to a subscriber token")

require("setupkoenv")
package.path = plugin_dir .. "/?.lua;" .. package.path
-- socketutil pulls in the whole Device layer; the plugin only needs its user agent here.
package.loaded["socketutil"] = { USER_AGENT = "KOReader internazionale.koplugin test" }

local Api = require("internaz_api")
local Epub = require("internaz_epub")
local Archiver = require("ffi/archiver")

local function readFile(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local transport
if corpus then
    local jpeg, png = readFile(corpus .. "/sample.jpg"), readFile(corpus .. "/sample.png")
    transport = function(req)
        local url = req.url
        local id = url:match("/item/article/(%d+)%.json$")
        if id then
            local body = readFile(corpus .. "/a_" .. id .. ".json")
            return body and 200 or 404, body or ""
        end
        if url:match("/items/sommario/") then return 200, readFile(corpus .. "/sommario.json") end
        if url:match("/sommario") then return 200, readFile(corpus .. "/sommario.html") end
        if url:match("^https://media%.internazionale%.it/") then
            return 200, url:match("%.png$") and png or jpeg
        end
        return 404, ""
    end
else
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    transport = function(req)
        socket.sleep(0.2) -- be gentle with the site
        local chunks = {}
        local ok, code, headers = https.request{
            url = req.url,
            method = req.method or "GET",
            headers = req.headers,
            source = req.body and ltn12.source.string(req.body) or nil,
            sink = ltn12.sink.table(chunks),
            redirect = false, -- Api:request follows redirects itself
        }
        if not ok then return nil, nil, code end
        return code, table.concat(chunks), headers
    end
end

local api = Api:new{ transport = transport, token = os.getenv("INTERNAZ_TOKEN") }
local meta = assert(api:fetchIssue(tonumber(os.getenv("ISSUE") or "")))
print(("issue %d (%s) stream %s: %s"):format(meta.number, meta.date or "?", meta.stream_id, meta.title or ""))
local outline = assert(api:fetchOutline(meta.stream_id))
print(("%d sections, %d articles"):format(#outline.sections, #outline.articles))

local zip = Archiver.Writer:new{}
assert(zip:open(out_path, "epub"), zip.err)
local mtime, compression = os.time(), nil
local writer = {
    add = function(_, entry, content, binary)
        local wanted = binary and "store" or "deflate"
        if wanted ~= compression then
            zip:setZipCompression(wanted)
            compression = wanted
        end
        return zip:addFileFromMemory(entry, content, mtime)
    end,
}

local b = Epub.Builder{
    writer = writer,
    issue = meta,
    outline = outline,
    image_mode = os.getenv("IMAGES") or "normal",
    fetch = function(url) return api:getBinary(url) end,
}
b:begin()
b:setCover()
for _, a in ipairs(outline.articles) do
    local item, err = api:fetchArticle(a.id)
    if item then
        b:addArticle(a, item)
    else
        print("skipped", a.id, a.title, err)
    end
end
b:finish()
zip:close()
print(("built %s: %d articles, %d images, %d images failed"):format(out_path, #b.order, b.n_images, b.failed_images))
