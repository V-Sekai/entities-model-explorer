extends Node
## Starts the FoundationDB server that ships beside the runtime and stops it when the app quits.
##
## The database the SQLite module uses lives in FoundationDB, so the package carries the server
## (fdbserver) and its command line (fdbcli) next to the runtime and libfdb_c. Nothing is installed:
## no launchd job, no package, no root. State lives in one per-user folder:
##   <user data dir>/fdb/   fdb.cluster, machine-id, data/, logs/
## WEFT_FDB_STATE_DIR overrides that folder, WEFT_FDB_BIN_DIR the folder holding fdbserver and fdbcli.
##
## It always passes a stored random machine id (-i). Without one, fdbserver on macOS opens a root-owned
## shared-memory file under /tmp and exits with "Could not open shared memory" for any other user.
##
## `-- --fdb-selftest` makes the app prove the whole chain and quit: it starts the server, opens a
## database through the SQLite module, writes a row, reads it back and exits 0 or 1. With
## `--fdb-selftest-plant` the expected value is wrong on purpose, so the run must exit 1.

signal finished(ok: bool)

const CLUSTER_DESC := "weftviewer"
const FALLBACK_PORT := 4791

var state := "idle"  # idle, starting, ready, failed
var detail := ""
var cluster_file := ""

var _pid := -1
var _spawned := false
var _stopping := false
var _thread: Thread


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var dir := _state_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	cluster_file = dir.path_join("fdb.cluster")
	if not FileAccess.file_exists(cluster_file):
		var f := FileAccess.open(cluster_file, FileAccess.WRITE)
		if f == null:
			_done("failed", "cannot write " + cluster_file)
		else:
			f.store_string(_fresh_cluster_line() + "\n")
			f.close()
	if state == "failed":
		if args.has("--fdb-selftest"):
			_selftest.call_deferred(args)
		return
	# The SQLite module reads this once, when the first database opens: set it before anything can.
	OS.set_environment("WEFT_FDB_CLUSTER_FILE", cluster_file)
	OS.set_environment("FDB_CLUSTER_FILE", cluster_file)
	state = "starting"
	_thread = Thread.new()
	_thread.start(_run.bind(dir))
	if args.has("--fdb-selftest"):
		_selftest.call_deferred(args)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop()


func _exit_tree() -> void:
	stop()


## Kills the server this app started. A server that was already running is left alone.
func stop() -> void:
	_stopping = true
	if _spawned and _pid > 0:
		OS.kill(_pid)
		_spawned = false
	# Join always: freeing a Thread that is still running aborts the engine. The waits inside _run are
	# bounded by fdbcli's --timeout (30 s at the longest), and a killed server ends them at once.
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()


func _state_dir() -> String:
	var over := OS.get_environment("WEFT_FDB_STATE_DIR")
	if over != "":
		return over
	return OS.get_user_data_dir().path_join("fdb")


func _bin_dir() -> String:
	var over := OS.get_environment("WEFT_FDB_BIN_DIR")
	if over != "":
		return over
	return OS.get_executable_path().get_base_dir()


func _exe(name: String) -> String:
	return _bin_dir().path_join(name + (".exe" if OS.get_name() == "Windows" else ""))


func _fresh_cluster_line() -> String:
	var port := 0
	var tcp := TCPServer.new()
	if tcp.listen(0, "127.0.0.1") == OK:
		port = tcp.get_local_port()
		tcp.stop()
	if port <= 0:
		port = FALLBACK_PORT
	var id := Crypto.new().generate_random_bytes(8).hex_encode()
	return "%s:%s@127.0.0.1:%d" % [CLUSTER_DESC, id, port]


func _port() -> int:
	var line := FileAccess.get_file_as_string(cluster_file).strip_edges()
	return int(line.get_slice(":", line.get_slice_count(":") - 1))


# fdbcli exits 0 whether or not the database is up, so the answer is read from its text.
func _available(cli: String, timeout_s: int) -> bool:
	var out := []
	OS.execute(
		cli,
		["-C", cluster_file, "--exec", "status minimal", "--timeout", str(timeout_s)],
		out,
		true
	)
	return "\n".join(out).contains("The database is available")


# Runs on the thread. fdbcli's own --timeout paces every wait, so there is no sleep.
func _run(dir: String) -> void:
	var server := _exe("fdbserver")
	var cli := _exe("fdbcli")
	if not FileAccess.file_exists(server) or not FileAccess.file_exists(cli):
		_done.call_deferred("failed", "fdbserver and fdbcli not found in " + _bin_dir())
		return
	if _available(cli, 3):
		_done.call_deferred("ready", "a server was already answering on " + cluster_file)
		return
	var id_path := dir.path_join("machine-id")
	if not FileAccess.file_exists(id_path):
		var idf := FileAccess.open(id_path, FileAccess.WRITE)
		if idf == null:
			_done.call_deferred("failed", "cannot write " + id_path)
			return
		idf.store_string(Crypto.new().generate_random_bytes(8).hex_encode())
		idf.close()
	var data := dir.path_join("data")
	var logs := dir.path_join("logs")
	DirAccess.make_dir_recursive_absolute(data)
	DirAccess.make_dir_recursive_absolute(logs)
	var args := PackedStringArray(
		[
			"-p",
			"127.0.0.1:%d" % _port(),
			"-C",
			cluster_file,
			"-d",
			data,
			"-L",
			logs,
			"-i",
			FileAccess.get_file_as_string(id_path).strip_edges(),
			"--memory",
			"1GiB",
			"--storage-memory",
			"512MiB",
			"--cache-memory",
			"256MiB",
			"--maxlogssize",
			"100MiB"
		]
	)
	_pid = OS.create_process(server, args)
	if _pid <= 0:
		_done.call_deferred("failed", "could not start " + server)
		return
	_spawned = true
	# A new database needs configuring once. On an existing one this answers "already exists", which is fine.
	var out := []
	OS.execute(
		cli,
		["-C", cluster_file, "--exec", "configure new single ssd", "--timeout", "30"],
		out,
		true
	)
	for i in 12:
		if _stopping:
			return
		if not OS.is_process_running(_pid):
			_done.call_deferred("failed", "fdbserver exited; see " + logs)
			return
		if _available(cli, 5):
			_done.call_deferred("ready", "fdbserver %d on port %d" % [_pid, _port()])
			return
	_done.call_deferred("failed", "the database did not become available")


func _done(new_state: String, new_detail: String) -> void:
	state = new_state
	detail = new_detail
	if state == "failed":
		push_warning("FdbServer: " + detail)
	finished.emit(state == "ready")


func _roundtrip(plant: bool) -> String:
	if not ClassDB.class_exists("SQLite"):
		return "the engine has no SQLite class"
	var db = ClassDB.instantiate("SQLite")
	if not db.open("user://fdb-selftest.db"):
		return "SQLite.open failed"
	var want := str(Time.get_unix_time_from_system()) + "-" + str(randi())
	db.create_query("CREATE TABLE IF NOT EXISTS t(k TEXT PRIMARY KEY, v TEXT)").execute()
	db.create_query("INSERT OR REPLACE INTO t VALUES(?, ?)").execute(["row", want])
	var rows = db.create_query("SELECT v FROM t WHERE k = ?").execute(["row"])
	db.close()
	if rows == null or rows.size() != 1:
		return "expected one row, got %s" % str(rows)
	var got := str(rows[0][0])
	if plant:
		want += "-planted"
	if got != want:
		return "read back %s, wanted %s" % [got, want]
	return ""


# Reads the row an earlier run wrote. A fresh state dir has none, so this must fail there.
func _read_only() -> String:
	if not ClassDB.class_exists("SQLite"):
		return "the engine has no SQLite class"
	var db = ClassDB.instantiate("SQLite")
	if not db.open("user://fdb-selftest.db"):
		return "SQLite.open failed"
	var rows = db.create_query("SELECT v FROM t WHERE k = ?").execute(["row"])
	db.close()
	if rows == null or rows.size() != 1:
		return "no row from an earlier run: %s" % str(rows)
	return ""


func _selftest(args: PackedStringArray) -> void:
	if state == "starting":
		await finished
	var problem := detail
	var plant := args.has("--fdb-selftest-plant")
	var mode := "roundtrip"
	if state == "ready":
		if args.has("--fdb-selftest-read"):
			mode = "read"
			problem = _read_only()
		else:
			problem = _roundtrip(plant)
	var ok := state == "ready" and problem == ""
	# plant= and mode= are printed so a harness that forgot a flag fails its own regex.
	var verdict := (
		"FDB-SELFTEST %s plant=%s mode=%s %s"
		% ["PASS" if ok else "FAIL", str(plant).to_lower(), mode, problem if not ok else detail]
	)
	print(verdict)
	# The Windows runtime is a GUI program with no stdout to capture, so the verdict is also a file.
	var vf := FileAccess.open(_state_dir().path_join("selftest-result.txt"), FileAccess.WRITE)
	if vf != null:
		vf.store_string(verdict + "\n")
		vf.close()
	stop()
	get_tree().quit(0 if ok else 1)
