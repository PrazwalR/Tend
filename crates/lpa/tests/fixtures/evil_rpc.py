#!/usr/bin/env python3
"""JSON-RPC man-in-the-middle for the DM-* audit PoCs. Forwards to a local
anvil and misbehaves the way a malicious or flaky RPC / private relay can.

  --feed ADDR        answer eth_call to ADDR as a Chainlink ETH/USD aggregator ($3000)
  --tip WEI          rewrite eth_feeHistory rewards (and eth_maxPriorityFeePerGas) to WEI
  --chain-id N       lie about eth_chainId
  --drop-sends N     accept the first N eth_sendRawTransaction calls but never forward them
                     (what a private relay does with a tx it will not include)
  --log FILE         append every eth_sendRawTransaction payload to FILE
Local anvil only. Never point this at a real network.
"""
import argparse, json, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, required=True)
ap.add_argument("--upstream", required=True)
ap.add_argument("--feed")
ap.add_argument("--feed-answer", type=int, default=3000 * 10**8)
ap.add_argument("--tip", type=int)
ap.add_argument("--chain-id", type=int)
ap.add_argument("--drop-sends", type=int, default=0)
ap.add_argument("--log")
args = ap.parse_args()
state = {"dropped": 0}


def word(n):
    return (n % (1 << 256)).to_bytes(32, "big").hex()


def feed_answer(data):
    sel = data[2:10]
    now = int(time.time())
    if sel == "7284e416":  # description()
        s = b"ETH / USD"
        return "0x" + word(32) + word(len(s)) + s.hex().ljust(64, "0")
    if sel == "313ce567":  # decimals()
        return "0x" + word(8)
    if sel == "feaf968c":  # latestRoundData()
        return "0x" + word(1) + word(args.feed_answer) +word(now) + word(now) + word(1)
    return None


def upstream(req):
    body = json.dumps(req).encode()
    r = urllib.request.Request(args.upstream, body, {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(r, timeout=30).read())


def one(req):
    m, p = req.get("method"), req.get("params") or []
    rid = req.get("id")

    def ok(res):
        return {"jsonrpc": "2.0", "id": rid, "result": res}

    if m == "eth_chainId" and args.chain_id is not None:
        return ok(hex(args.chain_id))
    if m == "eth_call" and args.feed and p and (p[0].get("to") or "").lower() == args.feed.lower():
        a = feed_answer(p[0].get("input") or p[0].get("data") or "0x")
        if a is not None:
            return ok(a)
    if m == "eth_sendRawTransaction":
        if args.log:
            with open(args.log, "a") as f:
                f.write(p[0] + "\n")
        if state["dropped"] < args.drop_sends:
            state["dropped"] += 1
            return ok("0x" + "ab" * 32)
    if m == "eth_maxPriorityFeePerGas" and args.tip is not None:
        return ok(hex(args.tip))
    res = upstream(req)
    if m == "eth_feeHistory" and args.tip is not None and "result" in res:
        n = len(res["result"].get("gasUsedRatio") or [1])
        res["result"]["reward"] = [[hex(args.tip)] for _ in range(max(n, 1))]
    return res


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        out = [one(r) for r in req] if isinstance(req, list) else one(req)
        b = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


ThreadingHTTPServer(("127.0.0.1", args.port), H).serve_forever()
