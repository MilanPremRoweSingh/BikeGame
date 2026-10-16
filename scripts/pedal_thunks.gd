class_name PedalThunks
extends AudioStreamPlayer3D

## Played in random order from the rear hub, over the click mix. Each clip plays once before any repeat.
@export var thunk_samples: Array[AudioStream] = []
@export var gain_db: float = 0.0

var original_position

var _bag: Array[AudioStream] = []
var _last: AudioStream


func _ready() -> void:
	volume_db = gain_db
	original_position = position 


## Plays one thunk. A new call cuts off a thunk that is still sounding.
func play_thunk(right: bool) -> void:
	var sample := _take_thunk()
	if sample == null:
		return
	stream = sample
	volume_db = gain_db

	if right:
		position = original_position + Vector3.RIGHT	
	else:
		position = original_position + Vector3.LEFT
	play()


func _take_thunk() -> AudioStream:
	if _bag.is_empty():
		_refill_bag()
	if _bag.is_empty():
		return null
	var pick: AudioStream = _bag.pop_front()
	_last = pick
	return pick


func _refill_bag() -> void:
	_bag.clear()
	for sample in thunk_samples:
		if sample != null:
			_bag.append(sample)
	if _bag.size() < 2:
		return
	_bag.shuffle()
	if _bag[0] == _last:
		var swap_at := (randi() % (_bag.size() - 1)) + 1
		var first: AudioStream = _bag[0]
		_bag[0] = _bag[swap_at]
		_bag[swap_at] = first
