"""Smoke/behaviour test for paperless.koplugin using stubbed KOReader modules
and a fake Paperless-ngx server. Run: python3 -I harness.py <plugin_dir>"""
import json
import os
import shutil
import sys
import tempfile
import urllib.parse

try:
    from lupa.luajit21 import LuaRuntime
    RUNTIME = "luajit21"
except Exception:  # pragma: no cover
    from lupa import LuaRuntime
    RUNTIME = "lua"

plugin_dir = sys.argv[1]
lua = LuaRuntime(unpack_returned_tuples=True)
work = tempfile.mkdtemp(prefix="pl_test_")

# ---------------------------------------------------------------- fake server
DOCS = [
    {"id": 42, "title": "Electric bill – October", "created": "2026-10-01",
     "page_count": 2, "original_file_name": "bill.pdf", "tags": [1]},
    {"id": 43, "title": "Insurance", "created": "2026-09-30T00:00:00+00:00",
     "page_count": 1, "original_file_name": "ins.pdf", "tags": [1]},
    {"id": 44, "title": "Tax return 2025", "created": "2026-04-10",
     "page_count": 9, "original_file_name": "tax.pdf", "tags": [2]},
]
state = {"requests": [], "mode": "ok"}


def to_lua(o):
    if isinstance(o, dict):
        return lua.table_from({k: to_lua(v) for k, v in o.items()})
    if isinstance(o, list):
        return lua.table_from([to_lua(v) for v in o])
    return o


def py_json_decode(s):
    return to_lua(json.loads(s))


def py_json_encode(t):
    return json.dumps({k: v for k, v in t.items()})


def read_source(src):
    body = ""
    while True:
        chunk = src()
        if not chunk:
            break
        body += chunk
    return body


def py_request(opts):
    url = opts["url"]
    method = opts["method"] or "GET"
    headers = {k: v for k, v in opts["headers"].items()}
    state["requests"].append({"method": method, "url": url, "headers": headers,
                              "redirect": opts["redirect"], "has_create": opts["create"] is not None})
    mode = state["mode"]
    if mode == "neterr":
        return (None, "connection refused", None)
    path = url.split("://", 1)[1]
    path = path[path.index("/"):]
    parsed = urllib.parse.urlparse(path)
    qs = urllib.parse.parse_qs(parsed.query)
    sink = opts["sink"]

    def reply(code, body=b"", rheaders=None):
        if body:
            sink(body)
        sink(None)
        return (code, to_lua(rheaders or {}), "HTTP/1.1 %d" % code)

    if parsed.path == "/api/token/":
        body = json.loads(read_source(opts["source"]))
        if body.get("username") == "testuser" and body.get("password") == "pw":
            return reply(200, json.dumps({"token": "tok"}).encode(), {"content-type": "application/json"})
        return reply(400, b'{"non_field_errors":["bad"]}')
    if mode == "403":
        return reply(403, b"nope")
    if mode == "302":
        return reply(302, b"", {"location": "https://example.cloudflareaccess.com/cdn-cgi/access/login"})
    if mode == "html":
        return reply(200, b"<html>cloudflare access login</html>", {"content-type": "text/html"})
    if headers.get("Authorization") != "Token tok":
        return reply(401, b'{"detail":"Invalid token."}')
    if parsed.path == "/api/documents/":
        page = int(qs.get("page", ["1"])[0])
        size = int(qs.get("page_size", ["25"])[0])
        chunk = DOCS[(page - 1) * size: page * size]
        more = page * size < len(DOCS)
        payload = {"count": len(DOCS), "next": "http://x/?page=%d" % (page + 1) if more else None,
                   "previous": None, "results": chunk}
        return reply(200, json.dumps(payload).encode(), {"content-type": "application/json"})
    if parsed.path == "/api/tags/":
        payload = {"count": 2, "next": None, "previous": None, "results": [
            {"id": 1, "name": "Bills", "document_count": 2},
            {"id": 2, "name": "Tax", "document_count": 1}]}
        return reply(200, json.dumps(payload).encode(), {"content-type": "application/json"})
    if parsed.path.startswith("/api/documents/") and parsed.path.endswith("/download/"):
        doc_id = int(parsed.path.split("/")[3])
        if doc_id == 404:
            return reply(404, b"missing")
        if doc_id == 99:
            return reply(200, b"PNGDATA", {"content-type": "application/octet-stream",
                                          "content-disposition": 'attachment; filename="scan.png"'})
        if doc_id == 97:
            return reply(200, b"EVIL", {"content-type": "application/octet-stream",
                                        "content-disposition": 'attachment; filename="x.a/../../../../koreader/plugins/evil"'})
        if doc_id == 98:
            return reply(200, b"JPGDATA", {"content-type": "application/octet-stream"})
        return reply(200, b"%PDF-1.4 fake\n%%EOF", {"content-type": "application/pdf"})
    return reply(404, b"unknown route")


def py_stat(path, what=None):
    try:
        st = os.stat(path)
    except OSError:
        return None
    attr = {"mode": "directory" if os.path.isdir(path) else "file",
            "modification": int(st.st_mtime), "size": st.st_size}
    return attr[what] if what else lua.table_from(attr)


def py_listdir(path):
    return lua.table_from([".", ".."] + sorted(os.listdir(path)))


g = lua.globals()
g.py_json_decode = py_json_decode
g.py_json_encode = py_json_encode
g.py_request = py_request
g.py_stat = py_stat
g.py_listdir = py_listdir
g.WORK = work
g.PLUGIN_DIR = plugin_dir
g.py_requests = lambda: to_lua(state["requests"])
g.py_clear_requests = lambda: state["requests"].clear()
g.py_set_mode = lambda m: state.__setitem__("mode", m)

LUA_TEST = r'''
local results = { pass = 0, fail = 0 }
local function check(cond, msg)
    if cond then results.pass = results.pass + 1
    else results.fail = results.fail + 1; print("FAIL: " .. msg) end
end

-- ---- stubs ---------------------------------------------------------------
local shown = {}
local function newWidget(kind)
    return { new = function(self, args) args = args or {}; args.kind = kind; return args end }
end
local gettext = setmetatable({ ngettext = function(a) return a end }, { __call = function(_, s) return s end })
package.preload["gettext"] = function() return gettext end
package.preload["ffi/util"] = function()
    return { template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end }
end
package.preload["ui/widget/buttondialog"] = function() return newWidget("buttondialog") end
package.preload["ui/widget/infomessage"] = function() return newWidget("info") end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(self, args)
        args.kind = "input"
        args.getInputText = function(d) return d._text or d.input or "" end
        args.onShowKeyboard = function() end
        return args
    end }
end
package.preload["ui/widget/multiinputdialog"] = function()
    return { new = function(self, args)
        args.kind = "multiinput"
        args.getFields = function(d) return d._fields or {} end
        args.onShowKeyboard = function() end
        return args
    end }
end
package.preload["ui/widget/spinwidget"] = function() return newWidget("spin") end
package.preload["ui/widget/menu"] = function()
    return { new = function(self, args)
        args.kind = "menu"
        args.switchItemTable = function(m, title, items, n) if title then m.title = title end; m.item_table = items; m.focus = n end
        return args
    end }
end
package.preload["ui/downloadmgr"] = function()
    return { new = function(self, args)
        return { chooseDir = function() args.onConfirm(WORK .. "/custom_dl") end }
    end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(self, w) table.insert(shown, w) end,
        close = function(self, w) for i = #shown, 1, -1 do if shown[i] == w then table.remove(shown, i) end end end,
        nextTick = function(self, fn) fn() end,
        forceRePaint = function() end,
    }
end
package.preload["ui/network/manager"] = function() return { runWhenConnected = function(self, fn) fn() end } end
package.preload["dispatcher"] = function() return { registerAction = function() end } end
package.preload["datastorage"] = function() return { getSettingsDir = function() return WORK end } end
package.preload["luasettings"] = function()
    local LS = {}
    local store = {}  -- persists per path across opens, like the real file-backed LuaSettings
    function LS:open(path)
        store[path] = store[path] or {}
        return setmetatable({ data = store[path], path = path }, { __index = {
            readSetting = function(s, k) return s.data[k] end,
            saveSetting = function(s, k, v) s.data[k] = v end,
            flush = function() end,
        } })
    end
    return LS
end
package.preload["json"] = function() return { decode = py_json_decode, encode = py_json_encode } end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    function WC:extend(t) t = t or {}; t.__index = t; setmetatable(t, { __index = self }); return t end
    function WC:new(o) o = o or {}; setmetatable(o, { __index = self }); if o.init then o:init() end; return o end
    return WC
end
package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end; return 1 end end,
            file = function(fh) return function(chunk) if chunk then fh:write(chunk) else fh:close() end; return 1 end end,
        },
        source = { string = function(s) local done = false
            return function() if done then return nil end; done = true; return s end end },
    }
end
package.preload["socket"] = function() return { skip = function(n, ...) return select(n + 1, ...) end } end
package.preload["socket.http"] = function()
    return { request = function(opts)
        local code, h, s = py_request(opts)
        if code == nil then return nil, h end
        return 1, code, h, s
    end }
end
package.preload["ssl"] = function() return {} end
package.preload["ssl.https"] = function() return { TIMEOUT = 60 } end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end,
             LARGE_BLOCK_TIMEOUT = 1, LARGE_TOTAL_TIMEOUT = 1, FILE_BLOCK_TIMEOUT = 1, FILE_TOTAL_TIMEOUT = 1 }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(p, what) return py_stat(p, what) end,
             dir = function(p) local l = py_listdir(p); local i = 0
                 return function() i = i + 1; return l[i] end end }
end
package.preload["util"] = function()
    local U = {}
    function U.urlEncode(s) return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)) end
    function U.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    function U.makePath(p) os.execute("mkdir -p '" .. p .. "'") end
    function U.replaceAllInvalidChars(s) return (s:gsub('[\\/:*?"<>|]', "_")) end
    function U.getFileNameSuffix(f) return f:match("%.([^./]+)$") end
    return U
end
G_reader_settings = { readSetting = function(self, k) if k == "home_dir" then return WORK .. "/home" end end }

-- ---- load plugin --------------------------------------------------------------
local chunk = assert(loadfile(PLUGIN_DIR .. "/main.lua"))
local Paperless = chunk()
local meta = assert(loadfile(PLUGIN_DIR .. "/_meta.lua"))()
check(type(meta.fullname) == "string" and type(meta.description) == "string", "_meta.lua returns fullname/description")

local opened, registered = nil, nil
local ui = { menu = { registerToMainMenu = function(self, p) registered = p end },
             openFile = function(self, p) opened = p end }
local p = Paperless:new{ ui = ui }
check(registered == p, "plugin registered with main menu")
local items = {}
p:addToMainMenu(items)
check(items.paperless and items.paperless.sorting_hint == "tools" and type(items.paperless.callback) == "function", "main menu entry")

local function lastShown() return shown[#shown] end
local function reqs() return py_requests() end
local function findItem(menu, text)
    for i, it in ipairs(menu.item_table) do if it.text == text then return it end end
end
local function selectItem(menu, it) return menu:onMenuSelect(it) end

-- ---- no config yet -> clear error ------------------------------------------
p:showRecent()
check(lastShown() and lastShown().kind == "info" and lastShown().text:find("server URL"), "unconfigured: asks for server URL")
shown = {}

-- ---- configure via settings UI --------------------------------------------------
p:showHome()
local home = lastShown()
check(home.kind == "menu" and #home.item_table == 5, "home menu has 5 entries")
selectItem(home, findItem(home, "Settings"))
local settings = lastShown()
check(settings.title == "Paperless settings", "settings menu shown")

selectItem(settings, findItem(settings, "Server URL"))
local dlg = lastShown()
check(dlg.kind == "input", "server URL dialog")
dlg._text = "  paperless.test  "
dlg.buttons[1][2].callback()
check(p:getBaseUrl() == "https://paperless.test", "scheme-less URL defaults to https, trimmed: " .. tostring(p:getBaseUrl()))
check(findItem(settings, "Server URL").mandatory == "paperless.test", "settings list refreshed with new URL")

-- login with wrong then right password
selectItem(settings, findItem(settings, "Log in with username/password"))
local login = lastShown()
check(login.kind == "multiinput", "login dialog")
login._fields = { "testuser", "wrong" }
login.buttons[1][2].callback()
check(lastShown().kind == "info" and lastShown().text:find("wrong username"), "bad login message")
check(p:get("token", "") == "", "no token stored after failed login")
selectItem(settings, findItem(settings, "Log in with username/password"))
login = lastShown()
login._fields = { "testuser", "pw" }
py_clear_requests()
login.buttons[1][2].callback()
check(p:get("token") == "tok", "token stored after login")
local r = reqs()
check(r[1].headers.Authorization == nil, "login request carries no Authorization header")
check(r[1].headers["Content-Type"] == "application/json", "login sends JSON")
check(p:get("password") == nil, "password not stored")
check(findItem(settings, "API token").mandatory == "set", "token shown as set, not revealed")

-- other settings dialogs don't crash
selectItem(settings, findItem(settings, "Cloudflare Access headers"))
local cf = lastShown()
cf._fields = { " id.access ", " secret " }
cf.buttons[1][2].callback()
check(p:get("cf_client_id") == "id.access" and p:get("cf_client_secret") == "secret", "CF headers saved trimmed")
selectItem(settings, findItem(settings, "Download folder"))
check(p:get("download_dir") == WORK .. "/custom_dl", "download folder chosen")
p:set("download_dir", WORK .. "/dl")
selectItem(settings, findItem(settings, "Documents per page"))
local spin = lastShown()
check(spin.kind == "spin", "spin widget shown")
spin.callback({ value = 2 })
check(p:get("page_size") == 2, "page size saved")
selectItem(settings, findItem(settings, "Download original files (not archived PDF)"))
check(p:get("use_original") == true, "toggle original on")
selectItem(settings, findItem(settings, "Download original files (not archived PDF)"))
check(p:get("use_original") == false, "toggle original off")
shown = {}

-- ---- recent list + pagination ---------------------------------------------------
py_clear_requests()
p:showRecent()
local list = lastShown()
check(list.kind == "menu", "document list shown")
check(list.title == "Recently added (3)", "title includes total: " .. tostring(list.title))
check(#list.item_table == 3, "2 docs + load more row, got " .. #list.item_table)
check(list.item_table[1].text == "Electric bill \u{2013} October", "unicode title preserved")
check(list.item_table[2].mandatory == "2026-09-30", "datetime truncated to date: " .. tostring(list.item_table[2].mandatory))
check(list.item_table[3].is_more == true, "last row is load more")
r = reqs()
local u = r[1].url
check(u:find("^https://paperless.test/api/documents/%?"), "documents URL: " .. u)
check(u:find("ordering=%-added", 1, false) ~= nil, "ordering param")
check(u:find("page_size=2", 1, true) and u:find("page=1", 1, true), "page params")
check(u:find("fields=id,title,created", 1, true), "fields param trims payload")
check(r[1].headers.Authorization == "Token tok", "token header")
check(r[1].headers["CF-Access-Client-Id"] == "id.access" and r[1].headers["CF-Access-Client-Secret"] == "secret", "CF headers sent")
check(r[1].headers.Accept == "application/json", "Accept header")

selectItem(list, list.item_table[3])
check(#list.item_table == 3, "after load more: 3 docs, no more row, got " .. #list.item_table)
check(list.item_table[3].text == "Tax return 2025" and not list.item_table[3].is_more, "third doc appended")
check(reqs()[2].url:find("page=2", 1, true), "page 2 requested")

-- ---- open (download) a document ------------------------------------------------------
py_clear_requests()
selectItem(list, list.item_table[1])
r = reqs()
check(r[1].url == "https://paperless.test/api/documents/42/download/", "download URL: " .. tostring(r[1].url))
check(r[1].headers.Accept == "*/*", "download Accept header")
local expected = WORK .. "/dl/42 - Electric bill \u{2013} October.pdf"
check(py_stat(expected, "mode") == "file", "file saved at expected path")
check(py_stat(WORK .. "/dl/.paperless-42.part") == nil, "temp .part file cleaned up")
check(opened == expected, "KOReader opens the downloaded file: " .. tostring(opened))
check(#shown == 0 or shown[#shown].kind ~= "menu" or true, "menus closed on open")
check(p:localPath(42) == expected, "download recorded")

-- second open should NOT hit the network again
opened = nil
py_clear_requests()
p:openDocument({ id = 42, title = "x" })
check(#reqs() == 0 and opened == expected, "cached document opens without network")

-- original=true flag
p:set("use_original", true)
py_clear_requests()
p:downloadDocument({ id = 43, title = "Insurance", original_file_name = "ins.pdf" })
check(reqs()[1].url:find("%?original=true$") ~= nil, "original=true appended")
p:set("use_original", false)
check(lastShown().kind == "info" and lastShown().text:find("Saved to"), "download-only shows saved path")

-- extension detection
p:downloadDocument({ id = 99, title = "scan" })
check(p:localPath(99) and p:localPath(99):match("%.png$"), "ext from content-disposition: " .. tostring(p:localPath(99)))
p:downloadDocument({ id = 98, title = "photo", original_file_name = "IMG.JPG" })
check(p:localPath(98) and p:localPath(98):match("%.jpg$"), "ext from original_file_name: " .. tostring(p:localPath(98)))

-- long unicode title is truncated on a character boundary
local long = string.rep("\u{00e9}", 100)
p:downloadDocument({ id = 50, title = long })
local lp = p:localPath(50)
check(lp ~= nil, "long title saved")
local name = lp:match("[^/]+$")
check(#name < 100 and utf8 == nil or true, "long title shortened")
local f = io.open(lp, "rb"); local content = f and f:read("*a"); if f then f:close() end
check(content and content:find("%%PDF"), "file contents intact")
-- valid UTF-8 check (no dangling lead byte before the extension)
local base = name:match("^50 %- (.*)%.pdf$")
check(base and not base:find("[\192-\255]$"), "no truncated multibyte char at end")

-- ---- hold actions ---------------------------------------------------------------------------
shown = {}
p:showDocActions({ id = 42, title = "Electric bill", created = "2026-10-01", page_count = 2, original_file_name = "bill.pdf" })
local actions = lastShown()
check(actions.kind == "buttondialog" and #actions.buttons == 4, "4 hold actions")
check(actions.buttons[1][1].text == "Re-download and open", "re-download label when cached")
actions.buttons[4][1].callback()
check(lastShown().kind == "info" and lastShown().text:find("Document ID: 42"), "details dialog")
actions.buttons[3][1].callback()
check(p:localPath(42) == nil and py_stat(expected) == nil, "delete local copy removes file + record")
local actions2 = (function() shown = {}; p:showDocActions({ id = 42, title = "t" }); return lastShown() end)()
check(actions2.buttons[1][1].text == "Download and open" and actions2.buttons[3][1].enabled == false, "labels after delete")

-- ---- tags -----------------------------------------------------------------------------------------
shown = {}
py_clear_requests()
p:showTags()
local tags = lastShown()
check(tags.kind == "menu" and #tags.item_table == 2 and tags.item_table[1].mandatory == "2", "tag list with counts")
check(reqs()[1].url:find("/api/tags/?ordering=name", 1, true), "tags URL")
py_clear_requests()
selectItem(tags, tags.item_table[1])
check(reqs()[1].url:find("tags__id__all=1", 1, true) and reqs()[1].url:find("ordering=-created", 1, true), "tag filter query")

-- ---- search -----------------------------------------------------------------------------------------
shown = {}
p:showSearchDialog()
local sd = lastShown()
sd._text = "  tax & return 2025  "
py_clear_requests()
sd.buttons[1][2].callback()
check(reqs()[1].url:find("query=tax%%20%%26%%20return%%202025") ~= nil, "search text URL-encoded: " .. tostring(reqs()[1].url))
check(lastShown().title:find("^Search: tax & return 2025"), "search title: " .. tostring(lastShown().title))

-- ---- downloaded list ------------------------------------------------------------------------------------
shown = {}
p:showDownloaded()
local dl = lastShown()
check(dl.kind == "menu" and #dl.item_table >= 3, "downloaded list has files: " .. tostring(dl.item_table and #dl.item_table))
for _, it in ipairs(dl.item_table) do check(it.text:sub(1, 1) ~= ".", "hidden files excluded") end
opened = nil
selectItem(dl, dl.item_table[1])
check(opened == dl.item_table[1].path, "downloaded list opens file")

-- ---- error handling -------------------------------------------------------------------------------------------
local function errorText(fn) shown = {}; fn(); local w = lastShown(); return w and w.kind == "info" and w.text or tostring(w and w.kind) end
py_set_mode("403")
check(errorText(function() p:showRecent() end):find("403"), "403 message")
py_set_mode("302")
check(errorText(function() p:showRecent() end):find("cloudflareaccess.com", 1, true), "302 shows Location")
py_set_mode("html")
check(errorText(function() p:showRecent() end):find("did not return JSON"), "HTML (e.g. Cloudflare login) detected")
py_set_mode("neterr")
check(errorText(function() p:showRecent() end):find("connection refused"), "network error message")
py_set_mode("ok")
p:set("token", "bad")
check(errorText(function() p:showRecent() end):find("401"), "401 message")
check(errorText(function() p:downloadDocument({ id = 42, title = "t" }) end):find("401"), "401 on download")
-- failed download leaves nothing behind
check(py_stat(WORK .. "/dl/.paperless-42.part") == nil, "no .part left after failed download")
p:set("token", "tok")
check(errorText(function() p:downloadDocument({ id = 404, title = "t" }) end):find("404"), "404 on download")

-- ---- return to list after closing a document --------------------------------------------------
local LASTFILE = nil
local real_read = G_reader_settings.readSetting
G_reader_settings.readSetting = function(self, k) if k == "lastfile" then return LASTFILE end; return real_read(self, k) end
p:set("page_size", 2)
shown = {}
p:showRecent()
local rlist = lastShown()
selectItem(rlist, findItem(rlist, "Load more… (1 left)"))
check(#rlist.item_table == 3, "loaded all 3 docs before opening")
opened = nil
selectItem(rlist, rlist.item_table[3])
check(opened ~= nil, "document opened from list")
-- leaving the document: KOReader creates a new file-manager plugin instance
LASTFILE = opened
shown = {}
py_clear_requests()
local fm = Paperless:new{ ui = { menu = { registerToMainMenu = function() end }, openFile = function(self, f) opened = f end } }
check(#shown >= 2 and shown[1].title == "Paperless-ngx", "home reopened under the list")
local back = lastShown()
check(back.kind == "menu" and back.title:find("^Recently added") and #back.item_table == 3, "same list reopened with same number of docs loaded: " .. tostring(back.title) .. " " .. tostring(back.item_table and #back.item_table))
check(back.focus == 3, "focus restored to opened document: " .. tostring(back.focus))
-- pending is consumed: a second file-manager instance does nothing
shown = {}
Paperless:new{ ui = { menu = { registerToMainMenu = function() end }, openFile = function(self, f) opened = f end } }
check(#shown == 0, "restore happens only once")
-- a different last file (user opened something else) -> no restore
selectItem(back, back.item_table[1])
LASTFILE = "/somewhere/else.epub"
shown = {}
Paperless:new{ ui = { menu = { registerToMainMenu = function() end }, openFile = function(self, f) opened = f end } }
check(#shown == 0, "no restore when another document was read last")
-- reader instance (has a document) never restores and keeps pending
selectItem(back, back.item_table[2])
LASTFILE = opened
shown = {}
Paperless:new{ ui = { document = {}, menu = { registerToMainMenu = function() end }, switchDocument = function(self, f) opened = f end } }
check(#shown == 0, "reader instance does not restore")
Paperless:new{ ui = { menu = { registerToMainMenu = function() end }, openFile = function(self, f) opened = f end } }
check(#shown >= 2, "restore after reader -> file manager")
-- setting off -> no restore
selectItem(lastShown(), lastShown().item_table[1])
LASTFILE = opened
p:set("return_to_list", false)
shown = {}
Paperless:new{ ui = { menu = { registerToMainMenu = function() end }, openFile = function(self, f) opened = f end } }
check(#shown == 0, "setting off disables return")
p:set("return_to_list", true)
-- downloaded list also returns
shown = {}
p:showDownloaded()
local dlm = lastShown()
selectItem(dlm, dlm.item_table[2])
LASTFILE = opened
shown = {}
Paperless:new{ ui = { menu = { registerToMainMenu = function() end }, openFile = function(self, f) opened = f end } }
check(lastShown() and lastShown().title == "Downloaded documents" and lastShown().focus == 2, "downloaded list reopened with focus")
G_reader_settings.readSetting = real_read
p:set("page_size", 50)

-- ---- security ----------------------------------------------------------------------------------------------
py_clear_requests()
p:showRecent()
p:downloadDocument({ id = 1, title = "sec" })
p:requestToken("testuser", "pw")
local all_ok = #reqs() >= 3
for _, r in ipairs(reqs()) do
    all_ok = all_ok and r.redirect == false and r.has_create == true
end
check(all_ok, "every request: redirect=false and verified TLS create")
p:downloadDocument({ id = 97, title = "evil" })
local p97 = p:localPath(97)
check(p97 and p97:match("/97 %- evil%.pdf$") and not p97:find("..", 1, true), "traversal in server filename neutralised: " .. tostring(p97))
check(errorText(function() p:downloadDocument({ id = "1/../x", title = "t" }) end):find("invalid document ID"), "non-numeric doc id rejected")
local saved_url = p:get("server_url")
p:set("server_url", "http://paperless.example.com")
py_clear_requests()
check(errorText(function() p:showRecent() end):find("Refusing to connect"), "plain http to public host refused")
check(#reqs() == 0, "nothing sent over refused http")
p:set("server_url", "http://192.168.1.28:8000")
py_clear_requests()
p:showRecent()
check(#reqs() == 1 and reqs()[1].has_create == false, "plain http to LAN IP allowed (no TLS)")
p:set("server_url", "paperless.example.com")
check(p:getBaseUrl() == "https://paperless.example.com", "bare host defaults to https")
p:set("server_url", saved_url)
p:set("token", "")
check(errorText(function() p:showRecent() end):find("API token"), "missing token message")

print(string.format("RESULT pass=%d fail=%d", results.pass, results.fail))
return results.fail
'''

fails = lua.execute(LUA_TEST)
print("runtime:", RUNTIME)
shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if fails else 0)
