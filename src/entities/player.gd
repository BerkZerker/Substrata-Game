class_name Player extends CharacterBody2D

# Movement Parameters (forwarded to MovementController)
@export var speed: float = 180.0
@export var acceleration: float = 1500.0
@export var friction: float = 2000.0
@export var jump_velocity: float = -400.0
@export var gravity: float = 800.0
@export var step_height: float = 6.0
@export var coyote_time: float = 0.1

# Health Parameters
@export var max_health: float = 100.0
@export var fall_damage_threshold: float = 500.0
@export var fall_damage_scale: float = 0.02
@export var knockback_strength: float = 200.0

# Collision / World
@export var collision_box_size: Vector2 = Vector2(10, 16)

var _current_chunk: Vector2i = Vector2i.ZERO
var _movement: MovementController = null
var _health: HealthComponent = null

# Fall damage tracking
var _prev_velocity_y: float = 0.0

# Death / respawn
var _spawn_position: Vector2 = Vector2.ZERO
var _death_timer: float = 0.0
var _is_dead: bool = false
const _RESPAWN_DELAY: float = 1.0

# Torch light
var _torch_light_id: int = -1
var _torch_enabled: bool = true
@export var torch_radius: float = 12.0
@export var torch_intensity: float = 0.9
@export var torch_color: Color = Color(1.0, 0.9, 0.7)


func _ready() -> void:
	_spawn_position = position
	await get_tree().process_frame
	_update_current_chunk()


func _physics_process(delta: float) -> void:
	if not _movement:
		if not _try_init_movement():
			return

	# Handle death/respawn timer
	if _is_dead:
		_death_timer -= delta
		if _death_timer <= 0.0:
			_respawn()
		return

	# Health tick
	_health.process(delta)

	# Invincibility visual: oscillate alpha between 0.3 and 1.0
	if _health.is_invincible():
		var t = fmod(_health._invincibility_timer * 10.0, 1.0)
		modulate.a = 0.3 + 0.7 * absf(sin(t * PI))
	elif modulate.a != 1.0:
		modulate.a = 1.0

	var input_axis = Input.get_axis("move_left", "move_right")
	var jump_pressed = Input.is_action_just_pressed("jump")

	_prev_velocity_y = _movement.velocity.y

	var result = _movement.move(position, input_axis, jump_pressed, delta)
	position = result.position

	# Fall damage: was falling fast, now on floor
	if result.is_on_floor and _prev_velocity_y > fall_damage_threshold:
		var damage = (_prev_velocity_y - fall_damage_threshold) * fall_damage_scale
		_health.take_damage(damage, Vector2.ZERO)

	# Tile damage (per-second scaling)
	if result.tile_damage > 0.0:
		_health.take_damage(result.tile_damage * delta)

	_update_current_chunk()
	_update_torch_light()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_T:
			_toggle_torch()


func _toggle_torch() -> void:
	var dlm = GameServices.dynamic_light_manager
	if dlm == null:
		return
	_torch_enabled = not _torch_enabled
	if _torch_enabled:
		_torch_light_id = dlm.add_light(global_position, torch_radius, torch_intensity, torch_color)
	elif _torch_light_id >= 0:
		dlm.remove_light(_torch_light_id)
		_torch_light_id = -1


func _update_torch_light() -> void:
	if not _torch_enabled:
		return
	var dlm = GameServices.dynamic_light_manager
	if dlm == null:
		return
	if _torch_light_id < 0:
		_torch_light_id = dlm.add_light(global_position, torch_radius, torch_intensity, torch_color)
	else:
		dlm.update_light_position(_torch_light_id, global_position)


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

	_health = HealthComponent.new(max_health)
	SignalBus.entity_damaged.connect(_on_entity_damaged)
	SignalBus.entity_died.connect(_on_entity_died)
	return true


func _update_current_chunk() -> void:
	var new_chunk = Vector2i(
		int(floor(global_position.x / GlobalSettings.CHUNK_SIZE)),
		int(floor(global_position.y / GlobalSettings.CHUNK_SIZE))
	)
	if new_chunk != _current_chunk:
		_current_chunk = new_chunk
		SignalBus.emit_signal("player_chunk_changed", _current_chunk)


func _on_entity_damaged(entity_id: int, _amount: float, knockback_direction: Vector2) -> void:
	if entity_id != _health.entity_id:
		return
	if knockback_direction != Vector2.ZERO and _movement:
		_movement.velocity += knockback_direction.normalized() * knockback_strength


func _on_entity_died(entity_id: int) -> void:
	if entity_id != _health.entity_id:
		return
	_is_dead = true
	_death_timer = _RESPAWN_DELAY
	visible = false


func _respawn() -> void:
	_is_dead = false
	visible = true
	modulate.a = 1.0
	position = _spawn_position
	_health.reset()
	if _movement:
		_movement.velocity = Vector2.ZERO
