extends CharacterBody3D
class_name FirstPersonBike

enum PedalFoot 
{
	LEFT,
	RIGHT
}

const  MAX_FLOAT = 1.79769e308
const  MIN_FLOAT = -1.79769e308

@export_group("Speed")
@export var coast_drag: float = 0.5
@export var front_brake_drag: float = 5
@export var back_brake_drag: float = 2.5
@export var reverse_speed: float = 0.5
@export var base_pedal_speed: float = 720
@export var max_pedal_speed: float = 1080
@export var base_revolution_to_acceleration: float = 3.0
@export var ineffective_resistance_ramp: float = 2
@export var transfer_smoothing: float = 5
@export var gears: Array[BikeGearData] 
@export var gears_start_index: int = 0
@export var gear_shift_delay: float = 0

@export_group("Steering")
@export var steer_speed: float = 2.4
@export var steer_speed_at_max: float = 0.9
@export var steering_reference_max_speed: float = 16
@export var max_lean: float = 0.42
@export var lean_smooth: float = 8.0
@export var min_steer_factor: float = 0.2

@export_group("Look")
@export var look_sensitivity: float = 0.015
@export var max_look_yaw: float = 1.15
@export var max_look_pitch: float = 0.75

@export_group("Feel")
@export var gravity: float = 22.0
@export var base_fov: float = 70.0
@export var zoom_fov: float = 120.0
@export var zoom_fov_start_speed = 10.0
@export var wheel_radius: float = 0.33
@export var pedal_haptic_strength: float = 0.1
@export var pedal_swap_overlap: float = 0.1

@export_group("Sound")
@export var pedal_sound_grace_period: float = 0.25

@onready var _visuals: Node3D = $Visuals
@onready var _head: Node3D = $Head
@onready var _camera: Camera3D = $Head/Camera3D
@onready var _front_wheel: Node3D = $Visuals/FrontWheel
@onready var _rear_wheel: Node3D = $Visuals/RearWheel
@onready var _handlebars: Node3D = $Visuals/Handlebars

@onready var _hub: FreeWheelHub = $Visuals/RearWheel/Hub
@onready var _thunks: PedalThunks = $Visuals/RearWheel/Thunks
@onready var _gear_chunk: AudioStreamPlayer3D = $GearChunk
@onready var _gear_click_high: AudioStreamPlayer3D = $HighGearClick
@onready var _gear_click_low: AudioStreamPlayer3D = $LowGearClick
@onready var _gear_click_failed: AudioStreamPlayer3D = $FailedGearClick



var _yaw: float = 0.0
var _speed: float = 0.0
var _look_yaw: float = 0.0
var _look_pitch: float = 0.0
var _lean: Vector2 = Vector2.ZERO
var _steer_input: float = 0.0
# 0 is right foot at its apex
var _pedal_angle = 0
var _pedal_speed = 0
var _is_pedalling = false
var _t_last_pedalled = 0.0
var _gear: BikeGearData = null
var _gear_index = 0
var _staged_gear_index = 0
var _gear_change_time = 0



# GD FUNCTIONS ###########################################
func _ready() -> void:
	_yaw = rotation.y
	rotation = Vector3(0.0, _yaw, 0.0)
	_head.position = Vector3(0.0, 1.42, 0.18)
	_camera.fov = base_fov
	_gear_index = gears_start_index
	_staged_gear_index  = gears_start_index
	_gear = gears[_gear_index]

func _process(delta: float) -> void:
	_update_camera(delta)
	_update_lean(delta)
	_update_pedal_speed(delta)
	_update_speed(delta)
	_steer(delta)
	_apply_gravity(delta)
	
	_play_sounds(delta)
	_update_gear(delta)

func _physics_process(delta: float) -> void:
	_steer_input = _lean.x

	_move()
	_update_visuals(delta)

# LOCAL FUNCTION ###########################################

func _stage_gear_change(delta : int):
	var old_staged = _staged_gear_index
	_staged_gear_index = max(0, min(gears.size() - 1, _staged_gear_index + delta))
	if _staged_gear_index > old_staged:
		_gear_click_high.play()
	elif _staged_gear_index < old_staged:
		_gear_click_low.play()
	else:
		_gear_click_failed.play()
	_gear_change_time = 0
	


func _update_gear(delta: float):
	if Input.is_action_just_pressed("shift_up"):
		_stage_gear_change(1)
	if Input.is_action_just_pressed("shift_down"):
		_stage_gear_change(-1)

	if _gear_index != _staged_gear_index:
		if _is_pedalling:
			_gear_change_time += delta 
		if _gear_change_time > gear_shift_delay:
			_gear_index = _staged_gear_index
			_gear = gears[_gear_index]
			_gear_change_time = Time.get_ticks_msec() / 1000.0
			_gear_chunk.play()

func _update_speed(delta: float) -> void:
	var acceleration = base_revolution_to_acceleration * (_pedal_speed / 360.0) * _gear.get_transfer(_speed, transfer_smoothing)
	
	var starting_boost = 2
	acceleration = acceleration + starting_boost if _speed < 2 and _is_pedalling else acceleration
	if !_is_pedalling:
		acceleration -= coast_drag
	if Input.is_action_pressed("front_brake"):
		acceleration -= front_brake_drag
	if Input.is_action_pressed("back_brake"):
		acceleration -= back_brake_drag
	if -acceleration > _speed:
		acceleration = -_speed
	_speed = _speed + acceleration * delta

func _get_current_pedal():
	var curr_progress = fmod(_pedal_angle, 180) / 180.0
	if (int(_pedal_angle / 180) % 2) == 0:
		return [PedalFoot.RIGHT, curr_progress]
	else:
		return [PedalFoot.LEFT, curr_progress]


func _update_pedal_speed(delta: float) -> void:
	var right = Input.get_action_strength("right_foot")
	var left = Input.get_action_strength("left_foot")
		
	var pedal_info = _get_current_pedal()
	var pedal_drive = 0
	if pedal_info[0] == PedalFoot.RIGHT or pedal_info[1] < pedal_swap_overlap or 1 - pedal_info[1] < pedal_swap_overlap:
		pedal_drive += right
	if pedal_info[0] == PedalFoot.LEFT or pedal_info[1] < pedal_swap_overlap or 1 - pedal_info[1] < pedal_swap_overlap:
		pedal_drive += left
	if pedal_info[1] > pedal_swap_overlap and left > 0 and right > 0:
		pedal_drive = 0
	pedal_drive = clamp(pedal_drive, 0, 1)

	_is_pedalling = pedal_drive > 0.01

	Input.start_joy_vibration(0, pedal_drive * pedal_info[1] * pedal_info[1] * pedal_haptic_strength, 0, delta)

	_pedal_speed = min(max_pedal_speed, pedal_drive * base_pedal_speed / _gear.get_resistance(_speed, ineffective_resistance_ramp))
	_pedal_angle = _pedal_angle + _pedal_speed * delta

func _play_sounds(delta : float) -> void:	
	if floori(_pedal_angle) / 180 != floori(_pedal_angle-_pedal_speed*delta) / 180:
		_thunks.play_thunk(_get_current_pedal()[0] != PedalFoot.RIGHT)

	var pedalCycleLength = 180.0 / _pedal_speed

	var time_in_s : float = Time.get_ticks_msec() / 1000.0
	if _is_pedalling:
		_t_last_pedalled = time_in_s
		
	var forgiving_is_pedalling : bool = _is_pedalling or (time_in_s - _t_last_pedalled) < pedal_sound_grace_period
	
	_hub.is_pedaling = forgiving_is_pedalling
	_hub.speed = _speed
		


func _steer(delta: float) -> void:
	var speed_ratio := clampf(absf(_speed) / steering_reference_max_speed, 0.0, 1.0)
	var turn_rate := lerpf(steer_speed, steer_speed_at_max, speed_ratio)
	var moving := clampf(absf(_speed) / 2.2, min_steer_factor, 1.0)
	var reverse_sign := -1.0 if _speed < -0.2 else 1.0
	_yaw += -_steer_input * turn_rate * moving * reverse_sign * delta
	rotation = Vector3(0.0, _yaw, 0.0)


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= gravity * delta


func _move() -> void:
	var forward := Vector3.FORWARD.rotated(Vector3.UP, _yaw)
	velocity.x = forward.x * _speed
	velocity.z = forward.z * _speed
	move_and_slide()


func _update_visuals(delta: float) -> void:
	_visuals.rotation = Vector3(0.0, 0.0, -_lean.x)

	var spin := (_speed / wheel_radius) * delta
	_front_wheel.rotate_x(spin)
	_rear_wheel.rotate_x(spin)
	_handlebars.rotation.y = _steer_input * 0.35

	var speed_ratio := clampf((_speed - zoom_fov_start_speed) / (steering_reference_max_speed - zoom_fov_start_speed), 0.0, 1.0)
	_camera.fov = lerpf(_camera.fov, lerpf(base_fov, zoom_fov, speed_ratio), 1.0 - exp(-4.0 * delta))


func _update_camera(delta: float) -> void:
	var look_x = Input.get_axis("look_horz_neg", "look_horz_pos")
	var look_y = Input.get_axis("look_vert_neg", "look_vert_pos")

	_look_yaw = clampf(_look_yaw - look_x * look_sensitivity, -max_look_yaw, max_look_yaw)
	_look_pitch = clampf(_look_pitch + look_y * look_sensitivity, -max_look_pitch, max_look_pitch)
	_head.rotation = Vector3(_look_pitch, _look_yaw, -_lean.x * 0.25)

func _update_lean(delta: float) -> void:
	var lean_x = Input.get_axis("lean_left", "lean_right")
	var lean_y = Input.get_axis("lean_back", "lean_forward")

	_lean.x = lerpf(_lean.x, max_lean * lean_x, 1.0 - exp(-lean_smooth * delta))
	_lean.y = lerpf(_lean.y, max_lean * lean_y, 1.0 - exp(-lean_smooth * delta))
