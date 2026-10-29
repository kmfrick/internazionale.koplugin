--[[
A handful of live requests through the plugin's own LuaSocket/LuaSec transport, as on the device:
latest issue page, sommario, two articles, the cover and a redirect.

  cd <koreader>/lib/koreader
  read -rs INTERNAZ_TOKEN && export INTERNAZ_TOKEN   # bash/zsh: keeps the token out of shell history
  ./luajit <repo>/tests/live_smoke.lua <repo>/internazionale.koplugin
]]

local plugin_dir = arg[1]
assert(plugin_dir, "usage: live_smoke.lua <plugin_dir>")
assert(os.getenv("INTERNAZ_TOKEN"), "set INTERNAZ_TOKEN to a subscriber token")

require("setupkoenv")
package.path = plugin_dir .. "/?.lua;" .. package.path
package.loaded["device"] = { model = "live-smoke-test" } -- all socketutil needs from the Device layer

local socket = require("socket")
local Api = require("internaz_api")
local api = Api:new{ token = os.getenv("INTERNAZ_TOKEN") }

local failures = 0
local function step(name, ok, detail)
    if not ok then failures = failures + 1 end
    print(("%-24s %s  %s"):format(name, ok and "OK  " or "FAIL", detail or ""))
end

local st = Api.tokenStatus(api.token)
step("token", st.valid and st.subscribed, st.valid and (st.subscribed and "valid, subscribed" or "not subscribed") or "expired or invalid")

local meta, err = api:fetchIssue(nil)
step("latest issue page", meta, meta and ("%d, stream %s: %s"):format(meta.number, meta.stream_id, meta.title or "") or err)
if not meta then os.exit(1) end
socket.sleep(0.3)

local outline
outline, err = api:fetchOutline(meta.stream_id)
step("sommario", outline, outline and (#outline.articles .. " articles") or err)
if not outline then os.exit(1) end
for i = 1, 2 do
    socket.sleep(0.3)
    local a = outline.articles[i]
    local item
    item, err = api:fetchArticle(a.id)
    step("article " .. a.id, item, item and (#item.content.data .. " blocks: " .. a.title) or err)
end

socket.sleep(0.3)
local img
img, err = api:getBinary(meta.cover)
step("cover image", img, img and (#img .. " bytes") or err)

socket.sleep(0.3)
local code, body = api:request{ url = "https://internazionale.it/sommario" } -- 301 to www
step("redirect apex -> www", code == 200 and body and body:find("page_context__title", 1, true) ~= nil, "HTTP " .. tostring(code))

os.exit(failures == 0 and 0 or 1)
