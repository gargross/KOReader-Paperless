local PLUGIN, D = arg[1], arg[2]
local WORK = os.tmpname(); os.remove(WORK); require("lfs").mkdir(WORK)
local function widget() local w = {}; function w:extend(o) o = o or {}; setmetatable(o, {__index = self}); return o end; function w:new(o) return self:extend(o) end; return w end
local stubs = {
  gettext = function(s) return s end,
  ["ffi/util"] = { template = function(s, ...) local a = {...}; return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end },
  ["ui/widget/buttondialog"] = widget(), ["ui/widget/infomessage"] = widget(), ["ui/widget/inputdialog"] = widget(),
  ["ui/widget/multiinputdialog"] = widget(), ["ui/widget/spinwidget"] = widget(), ["ui/widget/menu"] = widget(),
  ["ui/uimanager"] = { show = function() end, close = function() end, nextTick = function(_, f) f() end, forceRePaint = function() end },
  ["ui/network/manager"] = { runWhenConnected = function(_, f) f() end },
  dispatcher = { registerAction = function() end },
  datastorage = { getSettingsDir = function() return WORK end },
  luasettings = { open = function() local t = { d = {} }; function t:readSetting(k) return self.d[k] end; function t:saveSetting(k, v) self.d[k] = v end; function t:flush() end; return t end },
  json = { decode = require("cjson").decode, encode = require("cjson").encode },
  ["ui/widget/container/widgetcontainer"] = widget(),
  socketutil = { set_timeout = function() end, reset_timeout = function() end },
  ["libs/libkoreader-lfs"] = require("lfs"),
  util = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end, makePath = function() end, replaceAllInvalidChars = function(s) return (s:gsub('[\\/:*?"<>|]', "_")) end, getFileNameSuffix = function(f) return f:match("%.([^.]*)$") or "" end, urlEncode = function(s) return s end },
}
for k, v in pairs(stubs) do package.preload[k] = function() return v end end
G_reader_settings = { readSetting = function() return WORK end }
local Paperless = dofile(PLUGIN .. "/main.lua")
local p = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = Paperless })
p:init()
local pass, fail = 0, 0
local function check(c, name, extra) if c then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name, extra or "") end end
p:set("token", "SECRET"); p:set("cf_client_id", "cid.access"); p:set("cf_client_secret", "CFSECRET")

-- 1. bundled public CAs reject the test server's private CA; nothing sent
p:set("server_url", "https://localhost:8443")
local data, err = p:apiGet("/api/documents/?x=1")
check(not data and err:find("Secure connection refused"), "untrusted CA rejected", err)
-- 2. custom CA accepted
p:set("ca_file", D .. "/ca.pem")
data, err = p:apiGet("/api/documents/?x=2")
check(data and data.ok == true, "custom CA accepted", err)
-- 3. hostname mismatch rejected
p:set("server_url", "https://127.0.0.1:8443")
data, err = p:apiGet("/api/documents/?x=3")
check(not data and err:find("does not match host"), "hostname mismatch rejected", err)
-- 4. self-signed rejected
p:set("server_url", "https://localhost:8444")
data, err = p:apiGet("/api/documents/?x=4")
check(not data and err:find("verify failed"), "self-signed rejected", err)
-- 5. redirect not followed, target shown
p:set("server_url", "https://localhost:8443/redirect-base")
data, err = p:apiGet("/api/documents/?x=5")
check(not data and err:find("302") and err:find("localhost:8446/steal", 1, true), "redirect not followed", err)
-- 6. plain http to public host refused before connecting
p:set("server_url", "http://paperless.example.com")
data, err = p:apiGet("/api/documents/?x=6")
check(not data and err:find("Refusing to connect"), "public http refused", err)
-- 7. missing CA file
p:set("server_url", "https://localhost:8443"); p:set("ca_file", "/nonexistent.pem")
data, err = p:apiGet("/api/documents/?x=7")
check(not data and err:find("CA certificate file not found"), "missing CA file", err)
-- 8. login over verified TLS refused with untrusted CA
p:set("ca_file", "")
local tok, terr = p:requestToken("testuser", "pw")
check(not tok and terr:find("Secure connection refused"), "login refused on untrusted CA", terr)
print(("RESULT pass=%d fail=%d"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
