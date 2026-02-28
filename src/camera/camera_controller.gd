## Smooth-follow camera with mouse wheel zoom and zoom presets.
##
## Automatically follows the Player node using frame-rate independent smoothing.
## Supports mouse wheel zoom and Z key to cycle through zoom presets.
class_name CameraController extends Camera2D

## Smoothing factor for camera follow (higher = snappier).
@export var smoothing: float = 10.0

## Zoom presets cycled by the Z key.
@export var zoom_presets: Array[float] = [1.0, 2.0, 4.0, 8.0]

## Amount to multiply zoom per mouse wheel tick.
@export var zoom_step: float = 0.1

## Minimum zoom level (furthest out).
@export var min_zoom: Vector2 = Vector2(0.5, 0.5)

## Maximum zoom level (closest in).
@export var max_zoom: Vector2 = Vector2(10.0, 10.0)

var _target: Node2D = null
var _current_preset_index: int = 2 # Default to 4x

# Screen shake state
var _shake_intensity: float = 0.0
var _shake_duration: float = 0.0
var _shake_timer: float = 0.0


func _ready() -> void:
	zoom = Vector2(4, 4)
	# Find target on next frame so the scene tree is fully set up
	call_deferred("_find_target")


func _find_target() -> void:
	var scene = get_tree().current_scene
	if scene:
		_target = scene.get_node_or_null("Player")


func _process(delta: float) -> void:
	if _target == null:
		return
	# Frame-rate independent smoothing: 1.0 - exp(-smoothing * delta)
	var weight = 1.0 - exp(-smoothing * delta)
	global_position = global_position.lerp(_target.global_position, weight)

	# Apply screen shake offset
	if _shake_timer > 0.0:
		_shake_timer -= delta
		var decay = _shake_timer / _shake_duration if _shake_duration > 0.0 else 0.0
		var offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake_intensity * decay
		global_position += offset


## Triggers screen shake. Multiple rapid calls take the higher intensity and reset the timer.
func apply_shake(intensity: float, duration: float) -> void:
	_shake_intensity = maxf(_shake_intensity if _shake_timer > 0.0 else 0.0, intensity)
	_shake_duration = duration
	_shake_timer = duration


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			var new_val = clampf(zoom.x * (1.0 + zoom_step), min_zoom.x, max_zoom.x)
			zoom = Vector2(new_val, new_val)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var new_val = clampf(zoom.x * (1.0 - zoom_step), min_zoom.x, max_zoom.x)
			zoom = Vector2(new_val, new_val)

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Z:
			_cycle_zoom_preset()


func _cycle_zoom_preset() -> void:
	if zoom_presets.is_empty():
		return
	_current_preset_index = (_current_preset_index + 1) % zoom_presets.size()
	var preset = zoom_presets[_current_preset_index]
	zoom = Vector2(preset, preset)
