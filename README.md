# Paperless-ngx for KOReader

A [KOReader](https://github.com/koreader/koreader) plugin for browsing, searching and downloading documents from a [Paperless-ngx](https://docs.paperless-ngx.com/) server. Documents open directly in KOReader. It was built for and tested on a jailbroken 2022 Kindle Scribe, and should work on any device that runs KOReader.

**Features**
- Recently added, browse by tag, full-text search, and paged lists ("Load more…").
- Tap a document to download and open it; long-press for more actions (re-download, download only, delete local copy, details).
- Downloaded documents are cached in `documents/Paperless` and can be read offline.
- Verified HTTPS: the certificate chain and hostname are checked against a bundled CA store, and redirects are never followed (see [SECURITY.md](SECURITY.md)).
- Optional Cloudflare Access service-token headers, for servers published through Cloudflare Zero Trust.

---

## 1. Jailbreak the Kindle and install KOReader

Follow [kindlemodding.org](https://kindlemodding.org/jailbreaking/); the [Jailbreak Wizard](https://kindlemodding.org/jailbreak-wizard.html) picks the right method for your device. What worked for a 2022 Kindle Scribe on firmware 5.19.6 (October 2026):

1. **Block automatic updates before going online.** Newer Kindles connect over MTP, so the filler script doesn't work. Copy the pre-made [MTP filler files](https://github.com/Crosunt223/Kindle-Filler-Disk/tree/main/MTP) in File Explorer until only 30–90 MB is free, and delete any `update*.bin` files.
2. **Connect to Wi-Fi and register.** Then check *Settings → Device Options → Device Info* for the firmware version.
3. **Run [Véra](https://kindlemodding.org/jailbreaking/Vera/)**, which supports firmware up to 5.19.6, using the in-device browser at `kindlemodding.org/vera`. Pick **KS** for the 2022 Scribe or **KS2** for the 2024 model.
4. **Confirm the jailbreak.** Search `;kpm update` from the home screen; the package-manager screen means it worked. Then search `;kpm install koreader`.
5. **Clean up.** Once KOReader launches, delete the filler folder and any `.bin` files.

> Firmware newer than what the current jailbreaks support can't be jailbroken, and you can't downgrade without a jailbreak. Keep the Kindle offline, or keep its storage full, until it's done.

## 2. Install the plugin

1. Exit KOReader and connect the Kindle over USB.
2. Copy the `paperless.koplugin` folder into `koreader/plugins/`, so you end up with `koreader/plugins/paperless.koplugin/main.lua`. Watch for an accidental extra folder level when unzipping.
3. Relaunch KOReader. The plugin is in the top menu → **Tools** tab (wrench icon), at the bottom of the list (it may be on page 2).

To update later, replace the files in `koreader/plugins/paperless.koplugin/` with KOReader closed.

## 3. Configure

Open **Paperless-ngx → Settings**:

| Setting | Value |
|---|---|
| Server URL | `https://paperless.example.com`. Plain `http://` is refused except to private-LAN IPs. |
| API token | From Paperless: user menu → **My Profile** → the circular-arrow button next to API Auth Token. |
| Log in with username/password | Alternative to the token: fetches a token and stores only the token. |
| Cloudflare Access headers | Only if the server sits behind Cloudflare Access. Use a service token's Client ID (ends in `.access`) and Client Secret. |
| Custom CA certificate file | Leave empty; the bundled public CAs cover Let's Encrypt, Google Trust Services, and others. Set a PEM path only for a private CA such as Caddy `tls internal`. |
| Download folder / Documents per page / Download original files | Optional. "Original" downloads the uploaded file instead of the archived PDF. |

### Typing long secrets is painful — pre-seed the settings file instead

1. Exit KOReader.
2. Copy [`examples/paperless.lua.example`](examples/paperless.lua.example) to your computer as `paperless.lua` and paste in your values. Keep the quotes and commas; nothing may come before `return {` except `--` comments.
3. Copy it to `koreader/settings/paperless.lua` on the device.

Windows tip: turn on *View → Show → File name extensions*, so Notepad can't silently save `paperless.lua.txt`.

### Quick access

Assign a gesture: gear tab → **Taps and gestures** → **Gesture manager** → pick a gesture → **General** → **Paperless-ngx**.

## 4. Recommended server-side hardening

- Create a dedicated Paperless user for the Kindle with **view-only** permissions on the documents it needs, and use that user's token. The token is stored unencrypted on the device, and it has whatever rights its user has.
- If you expose Paperless over the internet, put it behind Cloudflare Access (or similar) and give the Kindle its own service token, so it can be revoked on its own if the device is lost.
- Revoke and regenerate the Paperless token if the Kindle is lost.

## Troubleshooting

| Message | Meaning |
|---|---|
| Secure connection refused: certificate verify failed | The certificate isn't from a trusted CA, or the network is intercepting traffic. Nothing was sent. For a private CA, set *Custom CA certificate file*. |
| …certificate does not match host… | The certificate is valid but issued for a different name. Check the server URL. |
| Server redirected (HTTP 302) to: … | Usually a login page in front of Paperless (e.g. Cloudflare Access without headers) or a wrong URL. The target URL is shown. |
| The server did not return JSON | A proxy login page answered instead of Paperless. |
| Authentication failed (401) | Bad or revoked token. |
| Settings show empty after editing the file | Syntax error in `koreader/settings/paperless.lua`, or it was saved as `.lua.txt`. |
| Crash | Copy `koreader/crash.log` from the device. |

## Development

```
paperless.koplugin/
  _meta.lua     plugin metadata
  main.lua      UI, Paperless API client, downloads
  tls.lua       verified TLS (chain + hostname) for LuaSocket
  cacert.pem    Mozilla CA bundle (from certifi)
tests/
  harness.py            87 checks: KOReader UI and Paperless API stubbed (pip install lupa)
  run_tls_tests.sh      real LuaSec against local HTTPS servers (trusted / self-signed / wrong host / redirect)
  tls_integration.lua, tls_server.py
examples/paperless.lua.example
```

Run the tests:

```bash
pip install lupa
python3 tests/harness.py paperless.koplugin
sudo apt install luajit lua-socket lua-sec lua-cjson lua-filesystem   # Debian/Ubuntu
bash tests/run_tls_tests.sh
```

Refresh the CA bundle occasionally: `pip install -U certifi && cp "$(python3 -c 'import certifi;print(certifi.where())')" paperless.koplugin/cacert.pem`

Paperless API reference: <https://docs.paperless-ngx.com/api/>
