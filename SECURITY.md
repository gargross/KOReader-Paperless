# Security notes

## Threat model

The plugin holds three secrets: the Paperless API token, optional Cloudflare Access service-token credentials, and (only briefly, during *Log in*) the Paperless password. It talks to one server chosen by the user, possibly over untrusted networks such as hotel or café Wi-Fi.

## Audit findings (October 2026) and fixes

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | **Critical** | KOReader's HTTPS stack (LuaSocket → LuaSec 1.3.2 `ssl.https`) defaults to `verify = "none"`. Any machine on the network path could impersonate the server with a self-signed certificate and capture the token, the Cloudflare secret, and the login password. Reproduced with real LuaSec against a self-signed server. | `tls.lua` supplies a custom `create` for every request: `verify = "peer"` against the bundled Mozilla CA store, with SSLv2/v3 and TLS 1.0 disabled. |
| 2 | **Critical** | LuaSec does no hostname verification, even with `verify = "peer"`. Any valid certificate for *any* domain would be accepted. | `tls.lua` checks the peer certificate's subjectAltName (DNS, single-label left-most wildcard, or IP) against the requested host. There is no CN fallback; it fails closed. |
| 3 | **High** | LuaSocket follows GET redirects (up to 5) to any https host and re-sends the original headers. A redirect would forward `Authorization` and `CF-Access-Client-Secret` to the redirect target. Reproduced: secrets arrived at a second server. | `redirect = false` on every request; a 3xx is reported with its target URL. |
| 4 | Medium | An `http://` server URL would send the token and password in cleartext. | Plain http is refused unless the host is a loopback/RFC 1918 IPv4 literal or `*.local`. Bare hostnames default to https. |
| 5 | Low | The download file extension came from server-controlled `Content-Disposition` or `original_file_name` and wasn't sanitized (path-separator injection; not practically exploitable because `os.rename` won't create directories). | The extension must match `^%w+$` and be at most 8 characters, otherwise it falls back to `pdf`. Titles were already sanitized. |
| 6 | Low | A non-integer document ID from the server would crash `string.format("%d")`. | IDs are validated as non-negative integers. |

## Residual risks (by design / out of scope)

- **Secrets at rest:** `koreader/settings/paperless.lua` is plaintext. Anyone with the device and a USB cable can read it, as with every KOReader plugin's settings. Mitigations: a view-only Paperless user, a dedicated Cloudflare service token, and revoking both if the device is lost.
- **Token scope:** a Paperless token has its user's full rights. The plugin only reads, but a stolen token could do more. Use a view-only user.
- **Trust in the server:** a legitimate but compromised Paperless server can send large or malicious files. Downloads are written only inside the download folder and opened by KOReader's normal document engines.
- **CA bundle age:** `cacert.pem` is a snapshot (certifi 2026.07.22). Refresh it periodically (see README).
- **Device OS:** the jailbreak runs code as root on the Kindle; keep KOReader updated through KPM.

## Verification

- `tests/run_tls_tests.sh` uses real LuaJIT + LuaSocket + LuaSec 1.3.2 (the same LuaSec version KOReader ships) against local HTTPS servers. It checks that an untrusted CA, a self-signed certificate, a hostname mismatch and a missing CA file are all refused before any request is sent, that a trusted CA works, and that a redirect is not followed and leaks nothing.
- `tests/harness.py`: every request carries `redirect = false` and the verified-TLS `create`; path-traversal filenames are neutralized; public `http://` is refused with nothing sent.
- Not verified here: the bundled CA store against your real server from the device. Test on the device by opening the plugin; a certificate error means the chain isn't covered.
