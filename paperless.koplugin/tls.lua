--[[
Verified TLS connections for LuaSocket's http.request.

KOReader's HTTPS path (socket.http -> ssl.https.tcp from LuaSec) defaults to
verify = "none", and LuaSec never checks the certificate's hostname. This module
supplies a `create` function for http.request that:
  * requires the server certificate to chain to a trusted CA (verify = "peer"),
  * checks the certificate's subjectAltName against the requested host,
  * refuses SSLv2/SSLv3/TLS 1.0.
--]]

local socket = require("socket")

local M = {}

-- Wildcards are only honoured as the entire left-most label ("*.example.com"),
-- matching exactly one label, per RFC 6125.
function M.hostMatches(pattern, host)
    if type(pattern) ~= "string" or type(host) ~= "string" then
        return false
    end
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then
        return true
    end
    local suffix = pattern:match("^%*(%.[^%*]+)$")
    if suffix and suffix:find(".", 2, true) and #host > #suffix and host:sub(-#suffix) == suffix then
        local label = host:sub(1, #host - #suffix)
        return not label:find(".", 1, true)
    end
    return false
end

local function isIpLiteral(host)
    return host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil or host:find(":", 1, true) ~= nil
end

-- cert is a LuaSec x509 object. Only subjectAltName is consulted (no CN fallback).
function M.certMatchesHost(cert, host)
    local ok, ext = pcall(function() return cert:extensions() end)
    if not ok or type(ext) ~= "table" then
        return false
    end
    local san = ext["2.5.29.17"]
    if type(san) ~= "table" then
        return false
    end
    if isIpLiteral(host) then
        for _, ip in ipairs(san.iPAddress or {}) do
            if ip == host then
                return true
            end
        end
        return false
    end
    for _, name in ipairs(san.dNSName or {}) do
        if M.hostMatches(name, host) then
            return true
        end
    end
    return false
end

-- Copy every method of the wrapped SSL socket onto the connection object,
-- the same way LuaSec's own ssl.https does.
local function forwardMethods(conn)
    local mt = getmetatable(conn.sock).__index
    for name, method in pairs(mt) do
        if type(method) == "function" then
            conn[name] = function(self, ...)
                return method(self.sock, ...)
            end
        end
    end
end

-- Returns a `create` function suitable for http.request{ create = ... }.
function M.create(cafile)
    local ssl = require("ssl")
    local https = require("ssl.https")
    local params = {
        mode = "client",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = "peer",
        cafile = cafile,
    }
    return function()
        local conn = {}
        conn.sock = socket.try(socket.tcp())
        local raw_settimeout = getmetatable(conn.sock).__index.settimeout
        function conn:settimeout(...)
            return raw_settimeout(self.sock, https.TIMEOUT)
        end
        function conn:connect(host, port)
            socket.try(self.sock:connect(host, port))
            self.sock = socket.try(ssl.wrap(self.sock, params))
            self.sock:sni(host)
            self.sock:settimeout(https.TIMEOUT)
            socket.try(self.sock:dohandshake())
            local cert = self.sock:getpeercertificate()
            if not cert or not M.certMatchesHost(cert, host) then
                self.sock:close()
                socket.try(nil, "certificate does not match host " .. tostring(host))
            end
            forwardMethods(self)
            return 1
        end
        return conn
    end
end

return M
