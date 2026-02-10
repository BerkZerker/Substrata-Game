class_name Player extends CharacterBody2D

# Movement Parameters (forwarded to MovementController)
@export var speed: float = 180.0
@export var acceleration: float = 1500.0
@export var friction: float = 2000.0
@export var jump_velocity: float = -400.0
@export var gravity: float = 800.0
@export var step_height: float = 6.0
@export var coyote_time: float = 0.1

# Camera / View
@export var zoom_amount: float = 0.1
@export var minimum_zoom: Vector2 = Vector2(0.01, 0.01)
@export var maximum_zoom: Vector2 = Vector2(10.0, 10.0)

# Collision / World
@export var collision_box_size: Vector2 = Vector2(10, 16)

@onready var _camera: Camera2D = $Camera2D

var _current_chunk: Vector2i = Vector2i.ZERO
var _movement: MovementController = null


func _ready() -> void:
	await get_tree().process_frame
	_update_current_chunk()


func _physics_process(delta: float) -> void:
	if not _movement:
		if not GameServices.chunk_manager:
			return
		var detector = CollisionDetector.new(GameServices.chunk_manager)
		_movement = MovementController.new(detector)
		_movement.speed = speed
		_movement.acceleration = acceleration
		_movement.friction = friction
		_movement.jump_velocity = jump_velocity
		_movement.gravity = gravity
		_movement.step_height = step_height
		_movement.coyote_time = coyote_time
		_movement.collision_box_size = collision_box_size

	var input_axis = Input.get_axis("move_left", "move_right")
	var jump_pressed = Input.is_action_just_pressed("jump")

	position = _movement.move(position, input_axis, jump_pressed, delta)

	_update_current_chunk()


func _update_current_chunk() -> void:
	var new_chunk = Vector2i(
		int(floor(global_position.x / GlobalSettings.CHUNK_SIZE)),
		int(floor(global_position.y / GlobalSettings.CHUNK_SIZE))
	)
	if new_chunk != _current_chunk:
		_current_chunk = new_chunk
		SignalBus.emit_signal("player_chunk_changed", _current_chunk)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.zoom *= (1 + zoom_amount)
			if _camera.zoom.x > maximum_zoom.x:
				_camera.zoom = maximum_zoom
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.zoom *= (1 - zoom_amount)
			if _camera.zoom.x < minimum_zoom.x:
				_camera.zoom = minimum_zoom
