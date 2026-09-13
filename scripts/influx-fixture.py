"""HTTP contract fixture, not a substitute for testing against a live InfluxDB server."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
import json
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        parsed = urlparse(self.path)
        if self.headers.get('Authorization') != 'Token test-token' or parse_qs(parsed.query).get('org') != ['test org']:
            self.send_error(401); return
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps({'buckets':[{'name':'metrics'}]}).encode())
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.headers.get('Authorization') != 'Token test-token' or self.headers.get('Content-Type') != 'application/vnd.flux' or b'from(bucket:' not in body:
            self.send_error(400); return
        self.send_response(200); self.send_header('Content-Type', 'application/csv'); self.end_headers()
        self.wfile.write(b'#datatype,string,long,double\n#default,_result,,\n,result,table,_value\n,,0,42\n')
HTTPServer(('127.0.0.1', 18089), Handler).serve_forever()
