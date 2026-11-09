@tool
extends RefCounted
class_name MCPHttpServer
## MCP over HTTP in pure GDScript — lets Godot BE the MCP server with no external
## process. A minimal HTTP/1.1 server over TCPServer with both HTTP transports:
##
## - Streamable HTTP (MCP 2025-03-26 and later): `POST /mcp` with JSON-RPC, answered as
##   `application/json` or as one `text/event-stream` event, per the client's Accept header.
##   Stateless: no Mcp-Session-Id, and GET/DELETE answer 405, which the spec allows.
## - HTTP+SSE (MCP 2024-11-05): `GET /sse` opens an event stream whose first event,
##   `endpoint`, names `/messages?session_id=<id>`. The client POSTs JSON-RPC there, the POST
##   gets 202, and the answer arrives on the stream as an `event: message`.
##
## route() is transport-free (parsed request -> response parts) so it's unit-tested headless
## (tests/test_http.gd); poll() does the TCP/HTTP plumbing.

const MCPProtocolLib = preload("mcp_protocol.gd")
const BufferLib = preload("mcp_command_buffer.gd")
const PendingLib = preload("mcp_pending.gd")
const DEFAULT_PORT := 8788
const SUBMIT_PER_FRAME := 16  # constant per-frame execution budget
const KEEPALIVE_MSEC := 15000  # an SSE comment this often keeps proxies from closing a stream
## A request whose headers or body grow past this is refused (413), so one client cannot fill
## memory. Large enough for a model sent as base64.
const MAX_REQUEST_BYTES := 64 << 20

var protocol = MCPProtocolLib.new()
var _server := TCPServer.new()
var _clients: Array = []  # connections still reading a request
var _buffer = BufferLib.new(256)  # parsed requests awaiting constant-work submit
var _streams := {}  # 2024-11-05 session id -> { peer, last }
var in_flight := 0  # requests waiting on a tool that takes frames

# DNS-rebinding (Origin) protection. The MCP spec says servers MUST validate
# Origin, but the reference TypeScript/Python SDKs ship it DISABLED by default
# (enableDnsRebindingProtection=false; cf. CVE-2025-66414) and most real
# streamable-HTTP servers follow suit, relying on the localhost bind. We match
# that de-facto default (off) so we don't reject legitimate Origin-setting
# clients; flip enforce_origin=true to get spec-strict 403s.
var enforce_origin := false


func start(port: int = DEFAULT_PORT, host: String = "127.0.0.1") -> int:
	return _server.listen(port, host)


func stop() -> void:
	for c in _clients:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	for sid in _streams:
		var peer = _streams[sid].peer
		if peer is StreamPeerTCP:
			peer.disconnect_from_host()
	_streams.clear()
	_server.stop()


func is_listening() -> bool:
	return _server.is_listening()


# --- pure routing (testable) -------------------------------------------------

const SUPPORTED_VERSIONS := MCPProtocolLib.SUPPORTED_VERSIONS


## Produce { code, ctype, body } for a parsed HTTP request. No sockets.
## Two more shapes, which poll() finishes: { "open_stream": true } for GET /sse, and a
## "pending" key (with "sse") when a tool takes frames. A POST to /messages adds
## "deliver_to" (the 2024-11-05 session) and "payload" (the JSON-RPC answer to send there).
func route(method: String, path: String, headers: Dictionary, body: String) -> Dictionary:
	# Origin / DNS-rebinding protection — OFF by default to match the reference
	# SDKs and real-world servers (see enforce_origin above). When enabled, a
	# present non-localhost Origin is rejected; absent Origin (CLI clients) is
	# always allowed.
	if enforce_origin:
		var origin := String(headers.get("origin", ""))
		if origin != "" and not _origin_allowed(origin):
			return {"code": 403, "ctype": "text/plain", "body": "forbidden origin"}

	if method == "OPTIONS":
		return {"code": 204, "ctype": "text/plain", "body": ""}  # CORS preflight
	var bare := path.split("?")[0]
	if bare == "/sse":
		if method != "GET":
			return {
				"code": 405, "ctype": "text/plain", "body": "GET opens the 2024-11-05 event stream"
			}
		return {"open_stream": true}
	if bare == "/messages":
		return _route_message(method, path, body)
	if not bare.begins_with("/mcp"):
		return {"code": 404, "ctype": "text/plain", "body": "not found"}
	if method == "DELETE":
		# stateless: we don't manage sessions, so we don't allow termination.
		return {"code": 405, "ctype": "text/plain", "body": "session termination not supported"}
	if method == "GET":
		return {"code": 405, "ctype": "text/plain", "body": "no server stream"}
	if method != "POST":
		return {"code": 405, "ctype": "text/plain", "body": "method not allowed"}

	# Protocol version (MUST 400 on unsupported, when the header is present).
	var pv := String(headers.get("mcp-protocol-version", ""))
	if pv != "" and not (pv in SUPPORTED_VERSIONS):
		return _json(400, protocol.unsupported_version(null, pv))

	# Parse (MUST -32700 on an unparseable non-empty body).
	var req = JSON.parse_string(body)
	if req == null and body.strip_edges() != "":
		return {
			"code": 200,
			"ctype": "application/json",
			"body": JSON.stringify(protocol.parse_error_response(-32700, "parse error"))
		}

	# 2026-07-28: the body names its version in _meta, and the headers must repeat it.
	var modern := false
	if req is Dictionary:
		var version := MCPProtocolLib.request_version(req)
		modern = version != "" or pv in MCPProtocolLib.MODERN_VERSIONS
		if modern:
			var why := header_mismatch(req, headers, version)
			if why != "":
				var e: Dictionary = protocol.parse_error_response(
					MCPProtocolLib.HEADER_MISMATCH, why
				)
				e["id"] = MCPProtocolLib.json_id(req.get("id", null))
				return _json(400, e)

	var resp = protocol.handle_rpc(req)
	var sse := wants_sse(String(headers.get("accept", "")))
	if is_pending(resp):
		return {"pending": resp, "sse": sse}
	var status := error_status(resp, modern)
	if status != 200:
		return _json(status, resp)
	return format_response(resp, sse)


## Why a 2026-07-28 request's headers do not match its body, or "" when they do.
static func header_mismatch(req: Dictionary, headers: Dictionary, version: String) -> String:
	var pv := String(headers.get("mcp-protocol-version", ""))
	if pv != version:
		return "MCP-Protocol-Version header %s does not match _meta %s" % [pv, version]
	var method := String(req.get("method", ""))
	if not headers.has("mcp-method"):
		return "the Mcp-Method header is missing"
	if String(headers["mcp-method"]) != method:
		return "Mcp-Method header %s does not match method %s" % [headers["mcp-method"], method]
	var params = req.get("params", {})
	if method in ["tools/call", "resources/read", "prompts/get"] and params is Dictionary:
		var name := String(params.get("uri" if method == "resources/read" else "name", ""))
		if not headers.has("mcp-name"):
			return "the Mcp-Name header is missing"
		if decode_header(String(headers["mcp-name"])) != name:
			return "Mcp-Name header does not match " + name
	return ""


## The 2026-07-28 Base64 sentinel: =?base64?<UTF-8 as Base64>?=
static func decode_header(v: String) -> String:
	if v.begins_with("=?base64?") and v.ends_with("?="):
		return Marshalls.base64_to_raw(v.substr(9, v.length() - 11)).get_string_from_utf8()
	return v


## The HTTP status for a JSON-RPC error answer: 400 for a version or header error, and on a
## 2026-07-28 request 404 for an unknown method; 200 for everything else.
static func error_status(resp, modern: bool) -> int:
	if not (resp is Dictionary and resp.has("error")):
		return 200
	var code := int(resp.error.get("code", 0))
	if (
		code == MCPProtocolLib.UNSUPPORTED_PROTOCOL_VERSION
		or code == MCPProtocolLib.HEADER_MISMATCH
	):
		return 400
	if modern and code == -32601:
		return 404
	return 200


static func _json(code: int, msg) -> Dictionary:
	return {"code": code, "ctype": "application/json", "body": JSON.stringify(msg)}


## One JSON answer when the client takes JSON (MCP clients accept both): an SSE event carries the
## same bytes, and some clients cap an event's size (the Python SDK at 1 MiB), so a model sent
## back by get_file would not arrive. An event stream only for a client that takes nothing else.
static func wants_sse(accept: String) -> bool:
	return "text/event-stream" in accept and not ("application/json" in accept or "*/*" in accept)


## The HTTP parts for a finished JSON-RPC answer (null = nothing to answer).
func format_response(resp, sse: bool) -> Dictionary:
	if resp == null:
		return {"code": 202, "ctype": "text/plain", "body": ""}  # notification/response accepted
	var text := JSON.stringify(resp)
	if sse:
		return {"code": 200, "ctype": "text/event-stream", "body": sse_event("message", text)}
	return {"code": 200, "ctype": "application/json", "body": text}


static func sse_event(event: String, data: String) -> String:
	return "event: %s\ndata: %s\n\n" % [event, data]


func _route_message(method: String, path: String, body: String) -> Dictionary:
	if method != "POST":
		return {"code": 405, "ctype": "text/plain", "body": "POST JSON-RPC here"}
	var sid := query_param(path, "session_id")
	if sid == "":
		sid = query_param(path, "sessionId")
	if not _streams.has(sid):
		return {"code": 404, "ctype": "text/plain", "body": "unknown session; GET /sse first"}
	var req = JSON.parse_string(body)
	var resp = (
		protocol.parse_error_response(-32700, "parse error")
		if req == null
		else protocol.handle_rpc(req)
	)
	return {
		"code": 202, "ctype": "text/plain", "body": "Accepted", "deliver_to": sid, "payload": resp
	}


static func query_param(path: String, key: String) -> String:
	var q := path.split("?", true, 1)
	if q.size() < 2:
		return ""
	for kv in q[1].split("&"):
		var p := kv.split("=", true, 1)
		if p[0] == key:
			return p[1].uri_decode() if p.size() > 1 else ""
	return ""


static func is_pending(v) -> bool:
	if v is PendingLib:
		return true
	if v is Array:
		for x in v:
			if x is PendingLib:
				return true
	return false


func _origin_allowed(origin: String) -> bool:
	var o := origin.to_lower()
	return (
		o.begins_with("http://localhost")
		or o.begins_with("https://localhost")
		or o.begins_with("http://127.0.0.1")
		or o.begins_with("https://127.0.0.1")
		or o.begins_with("http://[::1]")
		or o.begins_with("https://[::1]")
	)


## Opens a 2024-11-05 session in the routing table (poll() owns the socket). Tests call it.
func open_session(peer) -> String:
	var sid := "%08x%08x" % [randi(), randi()]
	_streams[sid] = {"peer": peer, "last": Time.get_ticks_msec()}
	return sid


func session_count() -> int:
	return _streams.size()


# --- TCP / HTTP plumbing -----------------------------------------------------


func poll() -> void:
	# --- ingest: accept + parse complete requests into the buffer ----------
	# Bounded heavy work: parsing is cheap; the expensive part (route ->
	# protocol -> command dispatch) is deferred to the constant-budget submit.
	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buf": PackedByteArray()})
	for c in _clients.duplicate():
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.erase(c)
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			var got := peer.get_data(avail)
			if got[0] == OK:
				c.buf.append_array(got[1])
		if c.buf.size() > MAX_REQUEST_BYTES:
			_clients.erase(c)
			_write(peer, {"code": 413, "ctype": "text/plain", "body": "request too large"})
			continue
		var req = _try_parse(c.buf)
		if req != null:
			_clients.erase(c)  # request complete; leaves the reading set
			req["peer"] = peer
			if not _buffer.record(req):
				# backpressure: answer immediately rather than queueing unboundedly
				_write(peer, {"code": 503, "ctype": "text/plain", "body": "server busy"})

	# --- constant-work submit: execute at most SUBMIT_PER_FRAME requests ----
	for item in _buffer.submit(SUBMIT_PER_FRAME):
		var r := route(item.method, item.path, item.headers, item.body)
		if r.has("open_stream"):
			_open_stream(item.peer)
		elif r.has("pending"):
			_finish_later.call_deferred(item.peer, r)
		else:
			_write(item.peer, r)
			if r.has("deliver_to"):
				_deliver_later.call_deferred(r.deliver_to, r.payload)

	_poll_streams()


# Called deferred (from C++), so these coroutines need no awaiting caller.
func _finish_later(peer: StreamPeerTCP, r: Dictionary) -> void:
	in_flight += 1
	var resp = await PendingLib.settle(r.pending)
	in_flight -= 1
	_write(peer, format_response(resp, r.sse))


func _deliver_later(sid: String, payload) -> void:
	in_flight += 1
	var resp = await PendingLib.settle(payload)
	in_flight -= 1
	if resp == null or not _streams.has(sid):
		return
	var peer = _streams[sid].peer
	if peer is StreamPeerTCP:
		peer.put_data(sse_event("message", JSON.stringify(resp)).to_utf8_buffer())
	_streams[sid].last = Time.get_ticks_msec()


func _open_stream(peer: StreamPeerTCP) -> void:
	var h := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
	h += "Access-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n"
	peer.put_data(h.to_utf8_buffer())
	var sid := open_session(peer)
	peer.put_data(sse_event("endpoint", "/messages?session_id=" + sid).to_utf8_buffer())


func _poll_streams() -> void:
	var now := Time.get_ticks_msec()
	for sid in _streams.keys():
		var s: Dictionary = _streams[sid]
		var peer = s.peer
		if not (peer is StreamPeerTCP):
			continue  # a test's stand-in
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_streams.erase(sid)
			continue
		if peer.get_available_bytes() > 0:
			peer.get_data(peer.get_available_bytes())  # a stream carries nothing upward
		if now - s.last > KEEPALIVE_MSEC:
			peer.put_data(": keepalive\n\n".to_utf8_buffer())
			s.last = now


## Parse one complete HTTP request out of `buf` (mutating it), or null if more
## bytes are needed. Returns { method, path, headers, body }.
func _try_parse(buf: PackedByteArray):
	var sep := _find_seq(buf, "\r\n\r\n".to_utf8_buffer())
	if sep < 0:
		return null  # headers incomplete
	var header_text: String = buf.slice(0, sep).get_string_from_utf8()
	var lines := header_text.split("\r\n")
	var rl := lines[0].split(" ")
	var headers := {}
	for i in range(1, lines.size()):
		var idx := lines[i].find(":")
		if idx > 0:
			headers[lines[i].substr(0, idx).strip_edges().to_lower()] = (
				lines[i].substr(idx + 1).strip_edges()
			)
	var clen := int(headers.get("content-length", "0"))
	var body_start := sep + 4
	if buf.size() < body_start + clen:
		return null  # body incomplete
	var body: String = buf.slice(body_start, body_start + clen).get_string_from_utf8()
	# NOTE: callers drop the connection after one response; we don't reslice buf.
	return {
		"method": rl[0] if rl.size() > 0 else "",
		"path": rl[1] if rl.size() > 1 else "/",
		"headers": headers,
		"body": body,
	}


func _write(peer: StreamPeerTCP, r: Dictionary) -> void:
	var code := int(r.code)
	var status: String = (
		{
			200: "OK",
			202: "Accepted",
			204: "No Content",
			400: "Bad Request",
			403: "Forbidden",
			404: "Not Found",
			405: "Method Not Allowed",
			413: "Payload Too Large",
			503: "Service Unavailable",
		}
		. get(code, "OK")
	)
	var body_bytes := String(r.body).to_utf8_buffer()
	var h := "HTTP/1.1 %d %s\r\n" % [code, status]
	h += "Content-Type: %s\r\n" % r.ctype
	h += "Content-Length: %d\r\n" % body_bytes.size()
	# Stateless: no Mcp-Session-Id (we don't manage sessions). CORS for browser
	# clients; Origin itself is validated in route().
	h += "Access-Control-Allow-Origin: *\r\n"
	h += "Access-Control-Allow-Headers: *\r\n"
	h += "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
	h += "Connection: close\r\n\r\n"
	peer.put_data(h.to_utf8_buffer())
	if body_bytes.size() > 0:
		peer.put_data(body_bytes)
	peer.disconnect_from_host()


func _find_seq(buf: PackedByteArray, seq: PackedByteArray) -> int:
	var limit := buf.size() - seq.size()
	var i := 0
	while i <= limit:
		var ok := true
		for j in seq.size():
			if buf[i + j] != seq[j]:
				ok = false
				break
		if ok:
			return i
		i += 1
	return -1
