@tool
extends RefCounted
class_name MCPCommandBuffer
## Constant-work command buffer for the in-editor MCP server.
##
## Motivation (AWS Builders' Library, "Reliability and constant work"): the
## editor poll must NOT do work proportional to incoming MCP load, or a burst of
## requests spikes a frame and stalls the editor. So we decouple ingestion from
## execution: commands are RECORDED into a FIXED-CAPACITY ring (bounded memory +
## explicit backpressure when full), and each frame we SUBMIT a CONSTANT budget
## of them — the per-frame cost has a fixed upper bound no matter how many queue.
##
## Graphics-API command-buffer vocabulary: record() to enqueue, submit() to drain
## a budget. FIFO. record() returns false (and bumps `dropped`) when full so the
## caller can answer the client immediately rather than growing unboundedly.

var _capacity: int
var _ring: Array
var _head := 0  # next write slot
var _tail := 0  # next read slot
var _size := 0
var dropped := 0  # count rejected by backpressure (observability)


func _init(capacity: int = 256) -> void:
	_capacity = max(1, capacity)
	_ring = []
	_ring.resize(_capacity)


func capacity() -> int:
	return _capacity


func pending() -> int:
	return _size


func is_full() -> bool:
	return _size >= _capacity


func is_empty() -> bool:
	return _size == 0


## Record one command. Returns false (and increments `dropped`) if full.
func record(item) -> bool:
	if _size >= _capacity:
		dropped += 1
		return false
	_ring[_head] = item
	_head = (_head + 1) % _capacity
	_size += 1
	return true


## Submit up to `budget` recorded commands in FIFO order — the constant per-frame
## work bound. Returns the submitted items (0..budget).
func submit(budget: int) -> Array:
	var out := []
	var n: int = min(max(0, budget), _size)
	for _i in n:
		out.append(_ring[_tail])
		_ring[_tail] = null  # release the reference
		_tail = (_tail + 1) % _capacity
		_size -= 1
	return out
