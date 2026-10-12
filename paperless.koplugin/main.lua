--[[--
Paperless-ngx client for KOReader.

Browse (recent / by tag), full-text search and download documents from a
Paperless-ngx server, then open them in KOReader. Uses the documented REST
API with token authentication:

  GET  /api/documents/?...            list / search
  GET  /api/tags/?...                 tag list
  GET  /api/documents/<id>/download/  file (archived PDF by default)
  POST /api/token/                    optional: exchange username/password for a token

Optional Cloudflare Access service-token headers are supported for servers
that sit behind Cloudflare Access.

@module koplugin.Paperless
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]+$") or "."
local TLS = dofile(PLUGIN_DIR .. "/tls.lua")
local BUNDLED_CA = PLUGIN_DIR .. "/cacert.pem"

local DEFAULT_PAGE_SIZE = 50
-- Keep list responses small: never request the (large) OCR "content" field.
local DOC_FIELDS = "id,title,created,added,page_count,original_file_name,tags"

local Paperless = WidgetContainer:extend{
    name = "paperless",
    is_doc_only = false,
}

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function Paperless:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/paperless.lua")
    self.menus = {}
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Paperless:onDispatcherRegisterActions()
    Dispatcher:registerAction("paperless_open", {
        category = "none", event = "ShowPaperless", title = _("Paperless-ngx"), general = true,
    })
end

function Paperless:onShowPaperless()
    self:showHome()
    return true
end

function Paperless:addToMainMenu(menu_items)
    menu_items.paperless = {
        text = _("Paperless-ngx"),
        sorting_hint = "tools",
        callback = function()
            self:showHome()
        end,
    }
end

---------------------------------------------------------------------------
-- Settings helpers
---------------------------------------------------------------------------

function Paperless:get(key, default)
    local value = self.settings:readSetting(key)
    if value == nil then
        return default
    end
    return value
end

function Paperless:set(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Paperless:getBaseUrl()
    local base = self:get("server_url", "")
    if base == "" then
        return nil
    end
    if not base:match("^%a+://") then
        base = "https://" .. base
    end
    return (base:gsub("/+$", ""))
end

function Paperless:getDownloadDir()
    local dir = self:get("download_dir")
    if not dir or dir == "" then
        local home = G_reader_settings:readSetting("home_dir") or "/mnt/us/documents"
        dir = home .. "/Paperless"
    end
    dir = dir:gsub("/+$", "")
    util.makePath(dir .. "/")
    return dir
end

---------------------------------------------------------------------------
-- HTTP / API
---------------------------------------------------------------------------

function Paperless:buildHeaders(extra)
    local headers = {
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
    }
    local token = self:get("token", "")
    if token ~= "" then
        headers["Authorization"] = "Token " .. token
    end
    local cf_id, cf_secret = self:get("cf_client_id", ""), self:get("cf_client_secret", "")
    if cf_id ~= "" and cf_secret ~= "" then
        headers["CF-Access-Client-Id"] = cf_id
        headers["CF-Access-Client-Secret"] = cf_secret
    end
    for k, v in pairs(extra or {}) do
        headers[k] = v
    end
    return headers
end

-- Plain http is only allowed to loopback/private IPv4 literals and *.local hosts.
local function isLocalHost(host)
    host = (host or ""):lower()
    if host == "localhost" or host:match("%.local$") then
        return true
    end
    local a, b = host:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if not a then
        return false
    end
    return a == 10 or a == 127 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
end

-- Returns base URL, or nil + error if it is unset or uses an unsafe transport.
function Paperless:checkedBaseUrl()
    local base = self:getBaseUrl()
    if not base then
        return nil, _("Set the Paperless server URL first (Settings).")
    end
    local scheme, host = base:match("^(%a+)://([^/:]+)")
    scheme = scheme and scheme:lower()
    if scheme == "https" then
        return base
    end
    if scheme == "http" and isLocalHost(host) then
        return base
    end
    return nil, _("Refusing to connect: use an https:// server URL. Plain http is only allowed to local network IP addresses, because it would send your token unencrypted.")
end

function Paperless:getCaFile()
    local custom = self:get("ca_file", "")
    return custom ~= "" and custom or BUNDLED_CA
end

-- All HTTP goes through here: redirects are never followed (they would forward
-- the Authorization and Cloudflare headers to whatever host the redirect names),
-- and https connections verify the certificate chain and hostname.
function Paperless:httpRequest(reqt)
    reqt.redirect = false
    if reqt.url:lower():match("^https://") then
        local cafile = self:getCaFile()
        if not lfs.attributes(cafile, "mode") then
            -- Same shape as a network failure: (error string, nil, nil).
            return T(_("CA certificate file not found: %1"), cafile), nil, nil
        end
        reqt.create = TLS.create(cafile)
    end
    return socket.skip(1, http.request(reqt))
end

function Paperless:describeError(code, status, headers)
    if type(code) ~= "number" then
        local msg = tostring(code or status or "unreachable")
        if msg:find("CA certificate file not found", 1, true) then
            return msg
        end
        if msg:find("certificate", 1, true) then
            return T(_("Secure connection refused: %1\n\nThe server's TLS certificate is not trusted or does not match the server name. Nothing was sent. If the server uses a private CA, set a custom CA file in Settings."), msg)
        end
        return T(_("Network error: %1"), msg)
    end
    if code >= 300 and code < 400 then
        local location = headers and (headers["location"] or headers["Location"]) or "?"
        return T(_("Server redirected (HTTP %1) to:\n%2\n\nThe plugin does not follow redirects. Check the server URL, or a proxy/login page in front of Paperless."), tostring(code), tostring(location))
    end
    local known = {
        [401] = _("Authentication failed (401). Check the API token."),
        [403] = _("Access denied (403). The user may lack permission, or a proxy such as Cloudflare Access rejected the request."),
        [404] = _("Not found (404). Check the server URL."),
        [406] = _("The server rejected the request format (406)."),
    }
    return known[code] or T(_("Server returned HTTP %1."), tostring(code))
end

function Paperless:showError(message)
    UIManager:show(InfoMessage:new{ text = message })
end

-- GET a JSON endpoint. Returns decoded table, or nil + error message.
function Paperless:apiGet(path)
    local base, base_err = self:checkedBaseUrl()
    if not base then
        return nil, base_err
    end
    if self:get("token", "") == "" then
        return nil, _("No API token set (Settings).")
    end
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = self:httpRequest{
        url = base .. path,
        method = "GET",
        headers = self:buildHeaders(),
        sink = ltn12.sink.table(sink),
    }
    socketutil:reset_timeout()
    if code ~= 200 then
        return nil, self:describeError(code, status, resp_headers)
    end
    local ok, data = pcall(JSON.decode, table.concat(sink))
    if not ok or type(data) ~= "table" then
        return nil, _("The server did not return JSON. Check the URL; if the server is behind Cloudflare Access, set the Access headers in Settings.")
    end
    return data
end

-- Exchange username/password for an API token. Returns token or nil + error.
function Paperless:requestToken(username, password)
    local base, base_err = self:checkedBaseUrl()
    if not base then
        return nil, base_err
    end
    local body = JSON.encode({ username = username, password = password })
    local headers = self:buildHeaders({
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
    })
    headers["Authorization"] = nil
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = self:httpRequest{
        url = base .. "/api/token/",
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    }
    socketutil:reset_timeout()
    if code ~= 200 then
        if code == 400 then
            return nil, _("Login failed: wrong username or password.")
        end
        return nil, self:describeError(code, status, resp_headers)
    end
    local ok, data = pcall(JSON.decode, table.concat(sink))
    if ok and type(data) == "table" and type(data.token) == "string" then
        return data.token
    end
    return nil, _("Login response did not contain a token.")
end

function Paperless:fetchDocuments(params, page)
    local query = {}
    for i, p in ipairs(params) do
        query[#query + 1] = p
    end
    query[#query + 1] = "page=" .. page
    query[#query + 1] = "page_size=" .. self:get("page_size", DEFAULT_PAGE_SIZE)
    query[#query + 1] = "fields=" .. DOC_FIELDS
    return self:apiGet("/api/documents/?" .. table.concat(query, "&"))
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

function Paperless:showMenu(title, items, handlers)
    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(menu_self, item)
            if handlers.select then
                handlers.select(menu, item)
            elseif item.action then
                item.action(menu)
            end
            return true
        end,
        onMenuHold = function(menu_self, item)
            if handlers.hold then
                handlers.hold(menu, item)
            end
            return true
        end,
        close_callback = function()
            for i = #self.menus, 1, -1 do
                if self.menus[i] == menu then
                    table.remove(self.menus, i)
                end
            end
            UIManager:close(menu)
        end,
    }
    table.insert(self.menus, menu)
    UIManager:show(menu)
    return menu
end

function Paperless:closeAllMenus()
    for i = #self.menus, 1, -1 do
        UIManager:close(self.menus[i])
        self.menus[i] = nil
    end
end

function Paperless:showHome()
    local items = {
        { text = _("Recently added"), action = function() self:showRecent() end },
        { text = _("Browse by tag"), action = function() self:showTags() end },
        { text = _("Search"), action = function() self:showSearchDialog() end },
        { text = _("Downloaded documents"), action = function() self:showDownloaded() end },
        { text = _("Settings"), action = function() self:showSettings() end },
    }
    self:showMenu(_("Paperless-ngx"), items, {})
end

function Paperless:showRecent()
    self:showDocumentList(_("Recently added"), { "ordering=-added" })
end

function Paperless:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search documents"),
        input_hint = _("Full-text search"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local text = util.trim(dialog:getInputText())
                    UIManager:close(dialog)
                    if text ~= "" then
                        self:showDocumentList(T(_("Search: %1"), text), { "query=" .. util.urlEncode(text) })
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Paperless:showTags()
    NetworkMgr:runWhenConnected(function()
        local items = {}
        local page = 1
        while page <= 20 do
            local data, err = self:apiGet("/api/tags/?ordering=name&page_size=100&page=" .. page)
            if not data then
                self:showError(err)
                return
            end
            local results = data.results or {}
            for i, tag in ipairs(results) do
                items[#items + 1] = {
                    text = tag.name or ("#" .. tostring(tag.id)),
                    mandatory = tag.document_count and tostring(tag.document_count) or "",
                    tag = tag,
                }
            end
            if type(data.next) ~= "string" or #results == 0 then
                break
            end
            page = page + 1
        end
        if #items == 0 then
            UIManager:show(InfoMessage:new{ text = _("No tags found.") })
            return
        end
        self:showMenu(_("Tags"), items, {
            select = function(menu, item)
                if item.tag then
                    self:showDocumentList(item.tag.name, {
                        "tags__id__all=" .. tostring(item.tag.id),
                        "ordering=-created",
                    })
                end
            end,
        })
    end)
end

---------------------------------------------------------------------------
-- Document lists
---------------------------------------------------------------------------

function Paperless:localPath(id)
    local path = self:get("downloads", {})[tostring(id)]
    if path and lfs.attributes(path, "mode") == "file" then
        return path
    end
end

function Paperless:docItem(doc)
    local created = type(doc.created) == "string" and doc.created:sub(1, 10) or ""
    local title = (type(doc.title) == "string" and doc.title ~= "") and doc.title or ("#" .. tostring(doc.id))
    local mark = self:localPath(doc.id) and "\u{2B07} " or ""
    return { text = title, mandatory = mark .. created, doc = doc }
end

function Paperless:showDocumentList(title, params)
    NetworkMgr:runWhenConnected(function()
        local data, err = self:fetchDocuments(params, 1)
        if not data then
            self:showError(err)
            return
        end
        local docs = data.results or {}
        if #docs == 0 then
            UIManager:show(InfoMessage:new{ text = _("No documents found.") })
            return
        end
        local state = { page = 1, loaded = #docs, total = tonumber(data.count) or #docs }
        local menu_title = title .. " (" .. state.total .. ")"
        local function moreItem()
            return { text = T(_("Load more… (%1 left)"), state.total - state.loaded), is_more = true }
        end
        local items = {}
        for i, doc in ipairs(docs) do
            items[#items + 1] = self:docItem(doc)
        end
        if state.loaded < state.total then
            items[#items + 1] = moreItem()
        end
        self:showMenu(menu_title, items, {
            select = function(menu, item)
                if item.is_more then
                    self:loadMore(menu, menu_title, params, state, moreItem)
                elseif item.doc then
                    self:openDocument(item.doc)
                end
            end,
            hold = function(menu, item)
                if item.doc then
                    self:showDocActions(item.doc, menu)
                end
            end,
        })
    end)
end

function Paperless:loadMore(menu, menu_title, params, state, moreItem)
    local data, err = self:fetchDocuments(params, state.page + 1)
    if not data then
        self:showError(err)
        return
    end
    local docs = data.results or {}
    local items = menu.item_table
    table.remove(items) -- drop the "load more" row
    for i, doc in ipairs(docs) do
        items[#items + 1] = self:docItem(doc)
    end
    state.page = state.page + 1
    state.loaded = state.loaded + #docs
    if #docs > 0 and state.loaded < state.total then
        items[#items + 1] = moreItem()
    end
    menu:switchItemTable(menu_title, items, -1)
end

---------------------------------------------------------------------------
-- Download / open
---------------------------------------------------------------------------

local MIME_EXT = {
    ["application/pdf"] = "pdf",
    ["image/jpeg"] = "jpg",
    ["image/png"] = "png",
    ["image/tiff"] = "tif",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["text/plain"] = "txt",
    ["application/epub+zip"] = "epub",
}

local function pickExtension(resp_headers, doc)
    local ctype = ((resp_headers and resp_headers["content-type"]) or ""):lower()
    for mime, ext in pairs(MIME_EXT) do
        if ctype:find(mime, 1, true) then
            return ext
        end
    end
    local disposition = (resp_headers and resp_headers["content-disposition"]) or ""
    local fname = disposition:match('filename="([^"]+)"') or disposition:match("filename=([^;]+)")
    local ext = fname and util.getFileNameSuffix(fname)
    if not ext or ext == "" then
        ext = util.getFileNameSuffix(doc.original_file_name or "")
    end
    -- Server-supplied: allow only a short alphanumeric extension so it can
    -- never contain path separators or "..".
    ext = (ext or ""):lower()
    if not ext:match("^%w+$") or #ext > 8 then
        ext = "pdf"
    end
    return ext
end

local function safeTitle(title)
    title = util.replaceAllInvalidChars(title or "document")
    if #title > 80 then
        title = title:sub(1, 80):gsub("[\192-\255][\128-\191]*$", "")
    end
    title = util.trim(title)
    return title ~= "" and title or "document"
end

function Paperless:downloadDocument(doc, on_done)
    local base, base_err = self:checkedBaseUrl()
    if not base then
        self:showError(base_err)
        return
    end
    if self:get("token", "") == "" then
        self:showError(_("No API token set (Settings)."))
        return
    end
    local doc_id = tonumber(doc.id)
    if not doc_id or doc_id < 0 or doc_id % 1 ~= 0 then
        self:showError(_("The server returned an invalid document ID."))
        return
    end
    NetworkMgr:runWhenConnected(function()
        local info = InfoMessage:new{ text = T(_("Downloading “%1”…"), doc.title or tostring(doc.id)) }
        UIManager:show(info)
        UIManager:forceRePaint()

        local url = string.format("%s/api/documents/%d/download/", base, doc_id)
        if self:get("use_original", false) then
            url = url .. "?original=true"
        end
        local dir = self:getDownloadDir()
        local tmp = string.format("%s/.paperless-%d.part", dir, doc_id)
        local fh, ferr = io.open(tmp, "wb")
        if not fh then
            UIManager:close(info)
            self:showError(T(_("Cannot write to %1: %2"), dir, tostring(ferr)))
            return
        end
        local headers = self:buildHeaders()
        headers["Accept"] = "*/*"
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local code, resp_headers, status = self:httpRequest{
            url = url,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.file(fh),
        }
        socketutil:reset_timeout()
        UIManager:close(info)
        if code ~= 200 then
            os.remove(tmp)
            self:showError(self:describeError(code, status, resp_headers))
            return
        end

        local ext = pickExtension(resp_headers, doc)
        local final = string.format("%s/%d - %s.%s", dir, doc_id, safeTitle(doc.title), ext)
        os.remove(final)
        local renamed, rerr = os.rename(tmp, final)
        if not renamed then
            os.remove(tmp)
            self:showError(T(_("Could not save file: %1"), tostring(rerr)))
            return
        end
        local downloads = self:get("downloads", {})
        downloads[tostring(doc_id)] = final
        self:set("downloads", downloads)

        if on_done then
            -- Show follow-up UI on the next tick to avoid e-ink rendering congestion.
            UIManager:nextTick(function()
                on_done(final)
            end)
        else
            UIManager:show(InfoMessage:new{ text = T(_("Saved to:\n%1"), final) })
        end
    end)
end

function Paperless:openFile(path)
    self:closeAllMenus()
    UIManager:nextTick(function()
        if self.ui.document then
            self.ui:switchDocument(path)
        else
            self.ui:openFile(path)
        end
    end)
end

function Paperless:openDocument(doc)
    local path = self:localPath(doc.id)
    if path then
        self:openFile(path)
        return
    end
    self:downloadDocument(doc, function(downloaded)
        self:openFile(downloaded)
    end)
end

function Paperless:showDocActions(doc, menu)
    local dialog
    local path = self:localPath(doc.id)
    dialog = ButtonDialog:new{
        title = doc.title or tostring(doc.id),
        buttons = {
            {{
                text = path and _("Re-download and open") or _("Download and open"),
                callback = function()
                    UIManager:close(dialog)
                    self:downloadDocument(doc, function(downloaded)
                        self:openFile(downloaded)
                    end)
                end,
            }},
            {{
                text = _("Download only"),
                callback = function()
                    UIManager:close(dialog)
                    self:downloadDocument(doc, function(downloaded)
                        UIManager:show(InfoMessage:new{ text = T(_("Saved to:\n%1"), downloaded) })
                    end)
                end,
            }},
            {{
                text = _("Delete local copy"),
                enabled = path ~= nil,
                callback = function()
                    UIManager:close(dialog)
                    os.remove(path)
                    local downloads = self:get("downloads", {})
                    downloads[tostring(doc.id)] = nil
                    self:set("downloads", downloads)
                end,
            }},
            {{
                text = _("Details"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = table.concat({
                        T(_("Title: %1"), tostring(doc.title)),
                        T(_("Created: %1"), tostring(doc.created):sub(1, 10)),
                        T(_("Pages: %1"), tostring(doc.page_count or "?")),
                        T(_("Original file: %1"), tostring(doc.original_file_name or "?")),
                        T(_("Document ID: %1"), tostring(doc.id)),
                    }, "\n") })
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Paperless:showDownloaded()
    local dir = self:getDownloadDir()
    local files = {}
    for entry in lfs.dir(dir) do
        if entry:sub(1, 1) ~= "." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                files[#files + 1] = { text = entry, path = path, mtime = attr.modification or 0 }
            end
        end
    end
    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = T(_("No downloaded documents in:\n%1"), dir) })
        return
    end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    self:showMenu(_("Downloaded documents"), files, {
        select = function(menu, item)
            self:openFile(item.path)
        end,
    })
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

function Paperless:inputSetting(title, key, hint, refresh)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self:get(key, ""),
        input_hint = hint,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    self:set(key, util.trim(dialog:getInputText()))
                    UIManager:close(dialog)
                    refresh()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Paperless:loginDialog(refresh)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Log in to Paperless"),
        fields = {
            { hint = _("Username") },
            { hint = _("Password"), text_type = "password" },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Log in"),
                callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    NetworkMgr:runWhenConnected(function()
                        local token, err = self:requestToken(fields[1], fields[2])
                        if token then
                            self:set("token", token)
                            UIManager:show(InfoMessage:new{ text = _("Logged in. API token saved (password not stored).") })
                            refresh()
                        else
                            self:showError(err)
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Paperless:cloudflareDialog(refresh)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Cloudflare Access headers (optional)"),
        fields = {
            { text = self:get("cf_client_id", ""), hint = _("CF-Access-Client-Id") },
            { text = self:get("cf_client_secret", ""), hint = _("CF-Access-Client-Secret") },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                callback = function()
                    local fields = dialog:getFields()
                    self:set("cf_client_id", util.trim(fields[1]))
                    self:set("cf_client_secret", util.trim(fields[2]))
                    UIManager:close(dialog)
                    refresh()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Paperless:settingsItems(refresh)
    local cf_set = self:get("cf_client_id", "") ~= "" and self:get("cf_client_secret", "") ~= ""
    return {
        {
            text = _("Server URL"),
            mandatory = self:get("server_url", "") ~= "" and self:get("server_url") or _("not set"),
            action = function()
                self:inputSetting(_("Server URL"), "server_url", _("https://paperless.example.com"), refresh)
            end,
        },
        {
            text = _("API token"),
            mandatory = self:get("token", "") ~= "" and _("set") or _("not set"),
            action = function()
                self:inputSetting(_("API token"), "token", _("Paste token from Paperless > My Profile"), refresh)
            end,
        },
        {
            text = _("Log in with username/password"),
            action = function()
                self:loginDialog(refresh)
            end,
        },
        {
            text = _("Cloudflare Access headers"),
            mandatory = cf_set and _("set") or _("not set"),
            action = function()
                self:cloudflareDialog(refresh)
            end,
        },
        {
            text = _("Custom CA certificate file"),
            mandatory = self:get("ca_file", "") ~= "" and self:get("ca_file") or _("bundled"),
            action = function()
                self:inputSetting(_("CA certificate file (PEM); empty = bundled public CAs"), "ca_file", "/mnt/us/koreader/my-ca.pem", refresh)
            end,
        },
        {
            text = _("Download folder"),
            mandatory = self:getDownloadDir(),
            action = function()
                require("ui/downloadmgr"):new{
                    onConfirm = function(path)
                        self:set("download_dir", path)
                        refresh()
                    end,
                }:chooseDir(self:getDownloadDir())
            end,
        },
        {
            text = _("Documents per page"),
            mandatory = tostring(self:get("page_size", DEFAULT_PAGE_SIZE)),
            action = function()
                UIManager:show(SpinWidget:new{
                    title_text = _("Documents per page"),
                    value = self:get("page_size", DEFAULT_PAGE_SIZE),
                    value_min = 10,
                    value_max = 100,
                    value_step = 10,
                    default_value = DEFAULT_PAGE_SIZE,
                    ok_text = _("Save"),
                    callback = function(spin)
                        self:set("page_size", spin.value)
                        refresh()
                    end,
                })
            end,
        },
        {
            text = _("Download original files (not archived PDF)"),
            mandatory = self:get("use_original", false) and _("on") or _("off"),
            action = function()
                self:set("use_original", not self:get("use_original", false))
                refresh()
            end,
        },
    }
end

function Paperless:showSettings()
    local menu
    local function refresh()
        if menu then
            menu:switchItemTable(nil, self:settingsItems(refresh), -1)
        end
    end
    menu = self:showMenu(_("Paperless settings"), self:settingsItems(refresh), {})
end

return Paperless
