--[[--
Internazionale for KOReader: downloads an issue of the weekly as an EPUB laid out for e-ink
(sections in the table of contents, standfirsts, boxes, photos with captions) and opens it.

@module koplugin.Internazionale
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template

local Api = require("internaz_api")
local Epub = require("internaz_epub")

local ISSUES_IN_LIST = 12

local Internazionale = WidgetContainer:extend{
    name = "internazionale",
    is_doc_only = false,
}

function Internazionale:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/internazionale.lua")
    self.api = Api:new{ token = self.settings:readSetting("token") }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Internazionale:onDispatcherRegisterActions()
    Dispatcher:registerAction("internazionale_latest", {
        category = "none", event = "InternazionaleLatest", title = "Internazionale: ultimo numero", general = true,
    })
end

function Internazionale:onInternazionaleLatest()
    self:openIssue(nil)
    return true
end

-- Menu ---------------------------------------------------------------------------

function Internazionale:addToMainMenu(menu_items)
    menu_items.internazionale = {
        text = "Internazionale",
        sorting_hint = "tools",
        sub_item_table_func = function() return self:getSubMenuItems() end,
    }
end

local IMAGE_MODES = {
    { "normal", "Normali", "Alta risoluzione solo per strisce, vignette e foto; circa 15 MB a numero" },
    { "high", "Tutte in alta risoluzione", "File più pesanti e download più lunghi" },
    { "visual", "Solo strisce, vignette e foto", "Niente illustrazioni negli articoli: file più leggeri" },
}

function Internazionale:getSubMenuItems()
    local image_items = {}
    for _, m in ipairs(IMAGE_MODES) do
        table.insert(image_items, {
            text = m[2],
            help_text = m[3],
            radio = true,
            checked_func = function() return self:imageMode() == m[1] end,
            callback = function()
                self.settings:saveSetting("image_mode", m[1])
                self.settings:flush()
            end,
        })
    end
    return {
        {
            text = "Ultimo numero",
            callback = function() self:openIssue(nil) end,
        },
        {
            text = "Sfoglia i numeri",
            callback = function() self:showIssues() end,
        },
        {
            text_func = function()
                local st = Api.tokenStatus(self.api.token)
                local who = self.settings:readSetting("email") or st.email
                return who and ("Account: " .. who) or "Account: accedi"
            end,
            sub_item_table_func = function() return self:getAccountMenuItems() end,
            separator = true,
        },
        {
            text = "Immagini",
            sub_item_table = image_items,
        },
        {
            text_func = function() return "Cartella: " .. self:downloadDir() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local PathChooser = require("ui/widget/pathchooser")
                UIManager:show(PathChooser:new{
                    select_directory = true,
                    select_file = false,
                    path = self:downloadDir(),
                    onConfirm = function(path)
                        self.settings:saveSetting("download_dir", path)
                        self.settings:flush()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
    }
end

function Internazionale:getAccountMenuItems()
    return {
        {
            text_func = function()
                local st = Api.tokenStatus(self.api.token)
                if not st.expires then return "Non hai effettuato l'accesso" end
                local sub = st.subscribed and st.subscription_end
                    and ("abbonamento fino al " .. os.date("%d/%m/%Y", st.subscription_end))
                    or (st.subscribed and "abbonato" or "nessun abbonamento attivo")
                return sub
            end,
            enabled_func = function() return false end,
        },
        {
            text = "Accedi…",
            callback = function() self:showLoginDialog() end,
        },
        {
            text = "Incolla un token…",
            help_text = "Il valore del cookie internaz_auth_tkn copiato dal browser. Dura 7 giorni: per il rinnovo automatico accedi con email e password.",
            callback = function() self:showTokenDialog() end,
        },
        {
            text = "Esci",
            callback = function()
                for _, k in ipairs{ "token", "email", "password" } do self.settings:delSetting(k) end
                self.settings:flush()
                self.api.token = nil
                UIManager:show(InfoMessage:new{ text = "Credenziali eliminate.", timeout = 2 })
            end,
        },
    }
end

-- Settings helpers ------------------------------------------------------------------

function Internazionale:imageMode()
    return self.settings:readSetting("image_mode") or "normal"
end

function Internazionale:downloadDir()
    local dir = self.settings:readSetting("download_dir")
    if not dir then
        dir = (G_reader_settings:readSetting("home_dir") or DataStorage:getFullDataDir()) .. "/Internazionale"
    end
    return dir
end

function Internazionale:issuePath(number)
    return string.format("%s/Internazionale %d.epub", self:downloadDir(), number)
end

function Internazionale:isDownloaded(number)
    return lfs.attributes(self:issuePath(number), "mode") == "file"
end

function Internazionale:rememberIssue(meta, is_latest)
    local issues = self.settings:readSetting("issues") or {}
    issues[tostring(meta.number)] = {
        stream_id = meta.stream_id, title = meta.title, date_text = meta.date_text, date = meta.date,
        description = meta.description, cover = meta.cover, cover_fallback = meta.cover_fallback,
    }
    self.settings:saveSetting("issues", issues)
    if is_latest then self.settings:saveSetting("latest", meta.number) end
    self.settings:flush()
end

function Internazionale:cachedIssue(number)
    local issues = self.settings:readSetting("issues") or {}
    local c = issues[tostring(number)]
    if c and c.stream_id then
        local meta = util.tableDeepCopy(c)
        meta.number = number
        return meta
    end
end

function Internazionale:saveToken(token)
    self.api.token = token
    self.settings:saveSetting("token", token)
    self.settings:flush()
end

-- Authentication ------------------------------------------------------------------

--- Inside a Trapper coroutine: makes sure we hold a valid subscriber token.
function Internazionale:ensureLogin()
    local st = Api.tokenStatus(self.api.token)
    if not st.valid then
        local email, password = self.settings:readSetting("email"), self.settings:readSetting("password")
        if not (email and password) then
            return nil, "login_required"
        end
        Trapper:info("Accesso a Internazionale…")
        local token, err = self.api:login(email, password)
        if not token then
            return nil, "login_required", err
        end
        self:saveToken(token)
        st = Api.tokenStatus(token)
    end
    if not st.subscribed then
        return nil, "Questo account non risulta abbonato a Internazionale."
    end
    return true
end

function Internazionale:showLoginDialog(after, message)
    local dialog
    dialog = MultiInputDialog:new{
        title = "Accesso a Internazionale",
        fields = {
            {
                text = self.settings:readSetting("email") or "",
                hint = "Email",
                description = message,
            },
            {
                text = "",
                hint = "Password",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = "Annulla",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "Accedi",
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local email, password = util.trim(fields[1] or ""), fields[2] or ""
                        if email == "" or password == "" then return end
                        UIManager:close(dialog)
                        NetworkMgr:runWhenOnline(function() self:doLogin(email, password, after) end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Internazionale:doLogin(email, password, after)
    local info = InfoMessage:new{ text = "Accesso in corso…" }
    UIManager:show(info)
    UIManager:forceRePaint()
    local token, err = self.api:login(email, password)
    UIManager:close(info)
    if not token then
        self:showLoginDialog(after, err)
        return
    end
    self.settings:saveSetting("email", email)
    -- kept so the 7-day token can be renewed without asking again
    self.settings:saveSetting("password", password)
    self:saveToken(token)
    local st = Api.tokenStatus(token)
    if not st.subscribed then
        UIManager:show(InfoMessage:new{ text = "Accesso effettuato, ma l'account non risulta abbonato a Internazionale." })
        return
    end
    UIManager:show(InfoMessage:new{
        text = st.subscription_end
            and ("Accesso effettuato. Abbonamento valido fino al " .. os.date("%d/%m/%Y", st.subscription_end) .. ".")
            or "Accesso effettuato.",
        timeout = 3,
    })
    if after then UIManager:scheduleIn(1, after) end
end

function Internazionale:showTokenDialog()
    local dialog
    dialog = InputDialog:new{
        title = "Token di Internazionale",
        description = "Valore del cookie internaz_auth_tkn",
        input = "",
        buttons = {
            {
                {
                    text = "Annulla",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "Salva",
                    is_enter_default = true,
                    callback = function()
                        local token = util.trim(dialog:getInputText() or ""):gsub('^"', ""):gsub('"$', "")
                        token = token:gsub("^internaz_auth_tkn[=:]%s*", ""):gsub('^"', ""):gsub('"$', "")
                        local st = Api.tokenStatus(token)
                        if not st.expires then
                            UIManager:show(InfoMessage:new{ text = "Token non valido." })
                            return
                        end
                        UIManager:close(dialog)
                        self:saveToken(token)
                        UIManager:show(InfoMessage:new{
                            text = st.valid
                                and ("Token salvato, valido fino al " .. os.date("%d/%m/%Y %H:%M", st.expires) .. ".")
                                or "Il token è già scaduto.",
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Issues --------------------------------------------------------------------------

--- number=nil: latest issue.
function Internazionale:openIssue(number)
    if number and self:isDownloaded(number) then
        return self:openFile(self:issuePath(number))
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local ok, err = pcall(self.downloadAndOpen, self, number)
            if not ok then
                logger.err("Internazionale: download failed", err)
                Trapper:clear()
                UIManager:show(InfoMessage:new{ text = "Errore durante il download:\n" .. tostring(err) })
            end
        end)
    end)
end

function Internazionale:openFile(path)
    UIManager:nextTick(function()
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end)
end

local function fail(text)
    Trapper:clear()
    UIManager:show(InfoMessage:new{ text = text })
end

function Internazionale:downloadAndOpen(number, force)
    Trapper:setPausedText("Interrompere il download?", "Interrompi", "Continua")
    local meta = number and self:cachedIssue(number)
    if not meta then
        if not Trapper:info(number and T("Internazionale %1: lettura del sommario…", number)
                or "Internazionale: ricerca dell'ultimo numero…") then
            return Trapper:clear()
        end
        local err
        meta, err = self.api:fetchIssue(number)
        if not meta then
            return fail("Impossibile leggere il sommario: " .. tostring(err))
        end
        self:rememberIssue(meta, number == nil)
    end

    local path = self:issuePath(meta.number)
    if not force and self:isDownloaded(meta.number) then
        Trapper:clear()
        return self:openFile(path)
    end

    local ok, err, detail = self:ensureLogin()
    if not ok then
        Trapper:clear()
        if err == "login_required" then
            UIManager:nextTick(function()
                self:showLoginDialog(function() self:openIssue(meta.number) end, detail)
            end)
            return
        end
        return fail(err)
    end

    if not Trapper:info(T("Internazionale %1: sommario…", meta.number)) then return Trapper:clear() end
    local outline
    outline, err = self.api:fetchOutline(meta.stream_id)
    if not outline then
        return fail("Impossibile leggere il sommario: " .. tostring(err))
    end

    local dir = self:downloadDir()
    if not util.makePath(dir) and lfs.attributes(dir, "mode") ~= "directory" then
        return fail("Impossibile creare la cartella " .. dir)
    end
    local tmp = path .. ".part"
    local Archiver = require("ffi/archiver")
    local zip = Archiver.Writer:new{}
    if not zip:open(tmp, "epub") then
        return fail("Impossibile creare il file:\n" .. tostring(zip.err))
    end
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

    local builder = Epub.Builder{
        writer = writer,
        issue = meta,
        outline = outline,
        image_mode = self:imageMode(),
        fetch = function(url) return self.api:getBinary(url) end,
    }
    local cancelled, failed = false, 0
    local built, build_err = pcall(function()
        builder:begin()
        builder:setCover()
        local total = #outline.articles
        for i, a in ipairs(outline.articles) do
            if not Trapper:info(T("Internazionale %1\nArticolo %2 di %3\n\n%4", meta.number, i, total, a.title)) then
                cancelled = true
                return
            end
            local item = self.api:fetchArticle(a.id)
            if item then
                builder:addArticle(a, item)
            else
                failed = failed + 1
            end
        end
        Trapper:info("Creazione dell'EPUB…")
        builder:finish()
    end)
    zip:close()

    if cancelled or not built or #builder.order == 0 then
        os.remove(tmp)
        if cancelled then return Trapper:clear() end
        return fail("Download non riuscito: " .. tostring(build_err or "nessun articolo scaricato"))
    end
    -- rename replaces the old copy on Linux; remove it first only if that didn't work
    local renamed, rename_err = os.rename(tmp, path)
    if not renamed and lfs.attributes(path, "mode") == "file" then
        os.remove(path)
        renamed, rename_err = os.rename(tmp, path)
    end
    if not renamed then
        os.remove(tmp)
        return fail("Impossibile salvare il file:\n" .. tostring(rename_err))
    end
    Trapper:clear()
    if failed > 0 or builder.failed_images > 0 then
        UIManager:show(InfoMessage:new{
            text = T("Numero %1 scaricato.\nArticoli non scaricati: %2\nImmagini non scaricate: %3",
                meta.number, failed, builder.failed_images),
            timeout = 4,
        })
    end
    self:openFile(path)
end

function Internazionale:showIssues()
    local function show(latest)
        UIManager:nextTick(function() self:showIssueMenu(latest) end)
    end
    if not NetworkMgr:isOnline() then
        return show(self.settings:readSetting("latest"))
    end
    Trapper:wrap(function()
        Trapper:info("Internazionale: ricerca dell'ultimo numero…")
        local meta = self.api:fetchIssue(nil)
        if meta then self:rememberIssue(meta, true) end
        Trapper:clear()
        show(meta and meta.number or self.settings:readSetting("latest"))
    end)
end

function Internazionale:downloadedNumbers()
    local found = {}
    local dir = self:downloadDir()
    if lfs.attributes(dir, "mode") == "directory" then
        for f in lfs.dir(dir) do
            local n = f:match("^Internazionale (%d+)%.epub$")
            if n then found[tonumber(n)] = true end
        end
    end
    return found
end

function Internazionale:showIssueMenu(latest)
    local numbers = self:downloadedNumbers()
    if latest then
        for n = latest, math.max(1, latest - ISSUES_IN_LIST + 1), -1 do numbers[n] = true end
    end
    local sorted = {}
    for n in pairs(numbers) do table.insert(sorted, n) end
    table.sort(sorted, function(x, y) return x > y end)

    local issues = self.settings:readSetting("issues") or {}
    local items = {}
    for _, n in ipairs(sorted) do
        local c = issues[tostring(n)] or {}
        local downloaded = self:isDownloaded(n)
        table.insert(items, {
            text = c.title and T("%1 · %2", n, c.title) or T("Numero %1", n),
            mandatory = (downloaded and "✓ " or "") .. (c.date_text or ""),
            bold = downloaded,
            callback = function()
                UIManager:close(self.issue_menu)
                self:openIssue(n)
            end,
            hold_callback = function() self:showIssueActions(n, downloaded) end,
        })
    end
    table.insert(items, {
        text = "Altro numero…",
        callback = function() self:askIssueNumber() end,
    })

    self.issue_menu = Menu:new{
        title = "Internazionale",
        subtitle = latest and T("Ultimo numero: %1 · tieni premuto per altre azioni", latest) or "Tieni premuto un numero per altre azioni",
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(_, item)
            if item.hold_callback then item.hold_callback() end
            return true
        end,
    }
    UIManager:show(self.issue_menu)
end

function Internazionale:showIssueActions(number, downloaded)
    if not downloaded then
        return self:openIssue(number)
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = T("Internazionale %1", number),
        buttons = {
            {{
                text = "Scarica di nuovo",
                callback = function()
                    UIManager:close(dialog)
                    if self.issue_menu then UIManager:close(self.issue_menu) end
                    NetworkMgr:runWhenOnline(function()
                        Trapper:wrap(function()
                            local ok, err = pcall(self.downloadAndOpen, self, number, true)
                            if not ok then fail("Errore durante il download:\n" .. tostring(err)) end
                        end)
                    end)
                end,
            }},
            {{
                text = "Elimina",
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T("Eliminare il numero %1?", number),
                        ok_text = "Elimina",
                        ok_callback = function()
                            local path = self:issuePath(number)
                            local realpath = require("ffi/util").realpath
                            local ReaderUI = require("apps/reader/readerui")
                            local reader = ReaderUI.instance
                            local open_file = reader and reader.document and reader.document.file
                            if open_file and (realpath(open_file) or open_file) == (realpath(path) or path) then
                                UIManager:show(InfoMessage:new{ text = "Chiudi il numero prima di eliminarlo." })
                                return
                            end
                            -- same cleanup as the file browser: sidecar, history, collections
                            local FileManager = require("apps/filemanager/filemanager")
                            if not FileManager:deleteFile(path, true) then
                                return -- deleteFile has already shown "Failed to delete"
                            end
                            if FileManager.instance then FileManager.instance:onRefresh() end
                            if self.issue_menu then
                                UIManager:close(self.issue_menu)
                                self:showIssueMenu(self.settings:readSetting("latest"))
                            end
                        end,
                    })
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Internazionale:askIssueNumber()
    local dialog
    dialog = InputDialog:new{
        title = "Numero di Internazionale",
        input_type = "number",
        input = "",
        buttons = {
            {
                {
                    text = "Annulla",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "Apri",
                    is_enter_default = true,
                    callback = function()
                        local n = tonumber(dialog:getInputText())
                        if not n then return end
                        UIManager:close(dialog)
                        if self.issue_menu then UIManager:close(self.issue_menu) end
                        self:openIssue(n)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Internazionale
