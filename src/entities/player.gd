class_name Player extends CharacterBody2D

# Movement Parameters (forwarded to MovementController)
@export var speed: float = 180.0
@export var acceleration: float = 1500.0
@export var friction: float = 2000.0
@export var jump_velocity: float = -400.0
@export var gravity: float = 800.0
@export var step_height: float = 6.0
@export var coyote_time: float = 0.1

# Collision / World
@export var collision_box_size: Vector2 = Vector2(10, 16)

var _current_chunk: Vector2i = Vector2i.ZERO
var _movement: MovementController = null


func _ready() -> void:
	await get_tree().process_frame
	_update_current_chunk()


func _physics_process(delta: float) -> void:
	if not _movement:
		if not _try_init_movement():
			return

	var input_axis = Input.get_axis("move_left", "move_right")
	var jump_pressed = Input.is_action_just_pressed("jump")

	position = _movement.move(position, input_axis, jump_pressed, delta)

	_update_current_chunk()


func _try_init_movement() -> bool:
	if not GameServices.chunk_manager:
		return false
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
	return true


## Returns the player's current movement velocity vector.
func get_movement_velocity() -> Vector2:
	if _movement:
		return _movement.velocity
	return Vector2.ZERO


## Returns true if the player is on the floor.
func get_on_floor() -> bool:
	if _movement:
		return _movement.is_on_floor
	return false


func _update_current_chunk() -> void:
	var new_chunk = Vector2i(
		int(floor(global_position.x / GlobalSettings.CHUNK_SIZE)),
		int(floor(global_position.y / GlobalSettings.CHUNK_SIZE))
	)
	if new_chunk != _current_chunk:
		_current_chunk = new_chunk
		SignalBus.player_chunk_changed.emit(_current_chunk)
