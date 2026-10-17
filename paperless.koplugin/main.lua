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
local MAX_RESTORE_DOCS = 300
-- Written by the "Paperless" home-screen scriptlet just before it launches KOReader.
local AUTOSTART_FILE = "/tmp/paperless.autostart"
local AUTOSTART_MAX_AGE = 120 -- seconds; ignore stale markers from failed launches

-- Module-level, so it survives KOReader switching between the reader and the
-- file manager (plugin modules are loaded once; instances are recreated per UI).
-- Holds where a document was opened from, so that list can be reopened when
-- the user leaves that document.
local session = { pending = nil }

local buildTagTree -- defined with the tag browser below

local function samePath(a, b)
    if not a or not b then
        return false
    end
    if a == b then
        return true
    end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil.realpath then
        local ra, rb = ffiutil.realpath(a), ffiutil.realpath(b)
        return ra ~= nil and ra == rb
    end
    return false
end
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
    -- Launched from the Paperless home-screen icon: open the menu straight away.
    if self:consumeAutostart() then
        session.pending = nil
        UIManager:nextTick(function()
            self:showHome()
        end)
        return
    end
    -- Back in the file manager after reading a document opened from Paperless:
    -- reopen the list it came from.
    if not self.ui.document and session.pending then
        local pending = session.pending
        session.pending = nil
        local lastfile = G_reader_settings:readSetting("lastfile")
        if self:get("return_to_list", true) and samePath(lastfile, pending.path) then
            UIManager:nextTick(function()
                self:restoreLocation(pending)
            end)
        end
    end
end

-- Returns true (once) if a fresh autostart marker exists; always removes it.
function Paperless:consumeAutostart(path)
    path = path or AUTOSTART_FILE
    local fh = io.open(path, "r")
    if not fh then
        return false
    end
    local stamp = tonumber((fh:read("*l") or ""):match("%d+"))
    fh:close()
    os.remove(path)
    return stamp ~= nil and math.abs(os.time() - stamp) <= AUTOSTART_MAX_AGE
end

function Paperless:restoreLocation(loc)
    self:showHome()
    if loc.kind == "docs" and loc.tag_path and #loc.tag_path > 0 then
        -- Rebuild the tag levels above the list so Back walks up the tree again.
        NetworkMgr:runWhenConnected(function()
            local tags = self:fetchAllTags()
            if tags then
                self.tag_tree = buildTagTree(tags)
                self:showTagLevel(nil, {})
                local prefix = {}
                for _i, id in ipairs(loc.tag_path) do
                    prefix[#prefix + 1] = id
                    local kids = self.tag_tree.children[id]
                    if self.tag_tree.by_id[id] and kids and #kids > 0 then
                        self:showTagLevel(id, { unpack(prefix) })
                    end
                end
            end
            self:showDocumentList(loc.title, loc.params, { count = loc.count, focus = loc.focus }, loc.tag_path)
        end)
    elseif loc.kind == "docs" then
        self:showDocumentList(loc.title, loc.params, { count = loc.count, focus = loc.focus })
    elseif loc.kind == "downloaded" then
        self:showDownloaded(loc.focus)
    end
end

local function itemIndex(menu, item)
    for i, it in ipairs(menu.item_table or {}) do
        if it == item then
            return i
        end
    end
    return 1
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

-- opts.subtitle: breadcrumb line; opts.back: show a back arrow (closes only
-- this level). The X button always leaves Paperless (closes every level).
function Paperless:showMenu(title, items, handlers, opts)
    opts = opts or {}
    local menu
    menu = Menu:new{
        title = title,
        subtitle = opts.subtitle,
        title_bar_left_icon = opts.back and "chevron.left" or nil,
        onLeftButtonTap = opts.back and function()
            self:closeMenu(menu)
        end or nil,
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
            if opts.back then
                self:closeAllMenus()
            else
                self:closeMenu(menu)
            end
        end,
    }
    table.insert(self.menus, menu)
    UIManager:show(menu)
    return menu
end

function Paperless:closeMenu(menu)
    for i = #self.menus, 1, -1 do
        if self.menus[i] == menu then
            table.remove(self.menus, i)
        end
    end
    UIManager:close(menu)
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

-- All tags, following pagination. Returns list or nil + error.
function Paperless:fetchAllTags()
    local tags = {}
    for page = 1, 20 do
        local data, err = self:apiGet("/api/tags/?ordering=name&page_size=100&page=" .. page)
        if not data then
            return nil, err
        end
        local results = data.results or {}
        for _i, tag in ipairs(results) do
            if tonumber(tag.id) then
                tags[#tags + 1] = tag
            end
        end
        if type(data.next) ~= "string" or #results == 0 then
            break
        end
    end
    return tags
end

-- Builds { by_id = {id -> tag}, children = {parent id | "root" -> sorted tags} }.
-- Paperless-ngx >= 2.19 sends `parent`; older servers don't, so every tag is
-- top-level. A tag whose parent isn't visible to this user is shown at the top.
function buildTagTree(tags)
    local by_id, children = {}, {}
    for _i, tag in ipairs(tags) do
        by_id[tag.id] = tag
    end
    for _i, tag in ipairs(tags) do
        local parent = tonumber(tag.parent)
        local key = (parent and by_id[parent] and parent ~= tag.id) and parent or "root"
        children[key] = children[key] or {}
        table.insert(children[key], tag)
    end
    for _i, list in pairs(children) do
        table.sort(list, function(a, b)
            return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
        end)
    end
    return { by_id = by_id, children = children }
end

local function tagName(tag)
    return (type(tag.name) == "string" and tag.name ~= "") and tag.name or ("#" .. tostring(tag.id))
end

local function tagCount(tag)
    return tag.document_count ~= nil and tostring(tag.document_count) or ""
end

-- "Tags › Recipe › Course › Main" for a document list reached through tags.
function Paperless:tagCrumbs(path)
    if not path or #path == 0 or not self.tag_tree then
        return nil
    end
    local crumbs = { _("Tags") }
    for _i, id in ipairs(path) do
        local tag = self.tag_tree.by_id[id]
        crumbs[#crumbs + 1] = tag and tagName(tag) or ("#" .. tostring(id))
    end
    return table.concat(crumbs, " \u{203A} ")
end

function Paperless:showTags()
    NetworkMgr:runWhenConnected(function()
        local tags, err = self:fetchAllTags()
        if not tags then
            self:showError(err)
            return
        end
        if #tags == 0 then
            UIManager:show(InfoMessage:new{ text = _("No tags found.") })
            return
        end
        self.tag_tree = buildTagTree(tags)
        self:showTagLevel(nil, {})
    end)
end

-- One level of the tag tree. path = ids from the top down to parent_id.
function Paperless:showTagLevel(parent_id, path)
    local tree = self.tag_tree
    local node = parent_id and tree.by_id[parent_id]
    local crumbs = { _("Tags") }
    for _i, id in ipairs(path) do
        crumbs[#crumbs + 1] = tagName(tree.by_id[id])
    end
    local items = {}
    if node then
        items[1] = { text = T(_("All %1 documents"), tagName(node)), mandatory = tagCount(node),
                     bold = true, open_tag = node, path = path }
    end
    for _i, tag in ipairs(tree.children[parent_id or "root"] or {}) do
        local kids = tree.children[tag.id]
        local child_path = { unpack(path) }
        child_path[#child_path + 1] = tag.id
        if kids and #kids > 0 then
            items[#items + 1] = { text = tagName(tag), mandatory = T(#kids == 1 and _("%1 tag \u{203A}") or _("%1 tags \u{203A}"), #kids),
                                  drill_tag = tag, path = child_path }
        else
            items[#items + 1] = { text = tagName(tag), mandatory = tagCount(tag),
                                  open_tag = tag, path = child_path }
        end
    end
    return self:showMenu(node and tagName(node) or _("Tags"), items, {
        select = function(menu, item)
            if item.drill_tag then
                self:showTagLevel(item.drill_tag.id, item.path)
            elseif item.open_tag then
                self:showTagDocuments(item.open_tag, item.path)
            end
        end,
    }, { subtitle = table.concat(crumbs, " \u{203A} "), back = true })
end

function Paperless:showTagDocuments(tag, path, restore)
    self:showDocumentList(tagName(tag), {
        "tags__id__all=" .. tostring(tag.id),
        "ordering=-created",
    }, restore, path)
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

function Paperless:showDocumentList(title, params, restore, tag_path)
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
        -- When returning from a document, load as many pages as were loaded before.
        local want = restore and math.min(tonumber(restore.count) or 0, MAX_RESTORE_DOCS) or 0
        while state.loaded < want and state.loaded < state.total do
            local more = self:fetchDocuments(params, state.page + 1)
            local more_docs = more and more.results or {}
            if #more_docs == 0 then
                break
            end
            for _i, d in ipairs(more_docs) do
                docs[#docs + 1] = d
            end
            state.page = state.page + 1
            state.loaded = state.loaded + #more_docs
        end
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
        local function returnInfo(menu, item)
            return { kind = "docs", title = title, params = params, tag_path = tag_path,
                     count = state.loaded, focus = itemIndex(menu, item) }
        end
        local list_menu = self:showMenu(menu_title, items, {
            select = function(menu, item)
                if item.is_more then
                    self:loadMore(menu, menu_title, params, state, moreItem)
                elseif item.doc then
                    self:openDocument(item.doc, returnInfo(menu, item))
                end
            end,
            hold = function(menu, item)
                if item.doc then
                    self:showDocActions(item.doc, menu, returnInfo(menu, item))
                end
            end,
        }, { back = true, subtitle = self:tagCrumbs(tag_path) })
        if restore and restore.focus and restore.focus > 1 then
            list_menu:switchItemTable(nil, items, math.min(restore.focus, #items))
        end
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

function Paperless:openFile(path, return_info)
    if return_info then
        return_info.path = path
        session.pending = return_info
    else
        session.pending = nil
    end
    self:closeAllMenus()
    UIManager:nextTick(function()
        if self.ui.document then
            self.ui:switchDocument(path)
        else
            self.ui:openFile(path)
        end
    end)
end

function Paperless:openDocument(doc, return_info)
    local path = self:localPath(doc.id)
    if path then
        self:openFile(path, return_info)
        return
    end
    self:downloadDocument(doc, function(downloaded)
        self:openFile(downloaded, return_info)
    end)
end

function Paperless:showDocActions(doc, menu, return_info)
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
                        self:openFile(downloaded, return_info)
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

function Paperless:showDownloaded(focus)
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
    local dl_menu = self:showMenu(_("Downloaded documents"), files, {
        select = function(menu, item)
            self:openFile(item.path, { kind = "downloaded", focus = itemIndex(menu, item) })
        end,
    }, { back = true })
    if focus and focus > 1 then
        dl_menu:switchItemTable(nil, files, math.min(focus, #files))
    end
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
            text = _("Return to the list after closing a document"),
            mandatory = self:get("return_to_list", true) and _("on") or _("off"),
            action = function()
                self:set("return_to_list", not self:get("return_to_list", true))
                refresh()
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
    menu = self:showMenu(_("Paperless settings"), self:settingsItems(refresh), {}, { back = true })
end

return Paperless
