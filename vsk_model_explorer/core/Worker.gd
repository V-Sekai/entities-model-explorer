class_name Worker

var _thread: Thread
var _callable: Callable


func _init(cb: Callable):
	_callable = cb


func start():
	_thread = Thread.new()
	var _discard = _thread.start(_callable)

	call_deferred("_done")


func _done():
	if not _thread.is_alive():
		_thread.wait_to_finish()
