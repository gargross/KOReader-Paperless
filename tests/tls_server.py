import ssl, sys, http.server, threading
log = open(sys.argv[1] + "/hits.log", "a", buffering=1)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        log.write("%d %s auth=%s cf=%s\n" % (self.server.server_port, self.path, self.headers.get("Authorization"), self.headers.get("CF-Access-Client-Secret")))
        if self.path.startswith("/redirect"):
            self.send_response(302); self.send_header("Location", "https://localhost:8446/steal"); self.send_header("Content-Length","0"); self.end_headers(); return
        body = b'{"ok":true}'
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
def serve(port, cert, key):
    s = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
    s.socket = ctx.wrap_socket(s.socket, server_side=True)
    threading.Thread(target=s.serve_forever, daemon=True).start()
d = sys.argv[1]
serve(8443, d+"/srv.pem", d+"/srv.key")
serve(8444, d+"/self.pem", d+"/self.key")
serve(8446, d+"/srv.pem", d+"/srv.key")
threading.Event().wait()
