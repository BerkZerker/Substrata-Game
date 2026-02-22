## Reusable physics controller for gravity, movement, step-up, and collision.
##
## Handles horizontal acceleration/friction, gravity, coyote jump timing, and
## step-up mechanics using swept AABB collision. Composed into entities as a
## RefCounted dependency.
class_name MovementController extends RefCounted

# Movement parameters
var speed: float = 180.0
var acceleration: float = 1500.0
var friction: float = 2000.0
var jump_velocity: float = -400.0
var gravity: float = 800.0
var step_height: float = 6.0
var coyote_time: float = 0.1

# Collision
var collision_box_size: Vector2 = Vector2(10, 16)

# State (read by the owning entity)
var velocity: Vector2 = Vector2.ZERO
var is_on_floor: bool = false

# Internal
var _collision_detector: CollisionDetector
var _coyote_timer: float = 0.0
var _floor_tile_friction: float = 1.0
var _floor_speed_modifier: float = 1.0


func _init(collision_detector: CollisionDetector) -> void:
	_collision_detector = collision_detector


## Applies gravity, horizontal movement, step-up, and collision.
## Returns Dictionary: { position: Vector2, velocity: Vector2, is_on_floor: bool, floor_tile_id: int, tile_damage: float }
func move(current_pos: Vector2, input_axis: float, jump_pressed: bool, delta: float) -> Dictionary:
	# Coyote timer
	if is_on_floor:
		_coyote_timer = coyote_time
	else:
		_coyote_timer -= delta

	# Gravity
	velocity.y += gravity * delta

	# Horizontal movement with tile friction and speed modifiers
	var effective_friction = friction * _floor_tile_friction
	var effective_speed = speed * _floor_speed_modifier
	var effective_accel = acceleration * clampf(_floor_tile_friction, 0.3, 1.0)
	if input_axis != 0:
		velocity.x = move_toward(velocity.x, input_axis * effective_speed, effective_accel * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, effective_friction * delta)

	# Jump
	if jump_pressed and (is_on_floor or _coyote_timer > 0.0):
		velocity.y = jump_velocity
		is_on_floor = false
		_coyote_timer = 0.0

	# Horizontal sweep
	var start_pos = current_pos
	var x_move = Vector2(velocity.x * delta, 0)
	var result_x = _collision_detector.sweep_aabb(current_pos, collision_box_size, x_move)

	if result_x.collided and is_on_floor and abs(velocity.x) > 0.1:
		var stepped = _try_step_up(x_move, start_pos)
		if stepped != Vector2.ZERO:
			current_pos = stepped
		else:
			current_pos = result_x.position
			velocity.x = 0
	else:
		current_pos = result_x.position
		if result_x.collided:
			velocity.x = 0

	# Vertical sweep
	var y_move = Vector2(0, velocity.y * delta)
	var result_y = _collision_detector.sweep_aabb(current_pos, collision_box_size, y_move)

	current_pos = result_y.position

	if result_y.collided:
		velocity.y = 0
		if result_y.normal.y < -0.5:
			is_on_floor = true
	else:
		is_on_floor = false

	# Determine floor tile and update friction/speed modifiers
	var floor_tile_id: int = 0
	if is_on_floor:
		var feet_y = current_pos.y + collision_box_size.y * 0.5 + 0.1
		var feet_pos = Vector2(current_pos.x, feet_y)
		var tile_data = GameServices.chunk_manager.get_tile_at_world_pos(feet_pos)
		floor_tile_id = tile_data[0]
		_floor_tile_friction = TileIndex.get_friction(floor_tile_id)
		_floor_speed_modifier = TileIndex.get_speed_modifier(floor_tile_id)
	else:
		_floor_tile_friction = 1.0
		_floor_speed_modifier = 1.0

	# Check for damage tiles overlapping the entity
	var tile_damage: float = 0.0
	var half_size = collision_box_size * 0.5
	var entity_min = Vector2i(int(floor(current_pos.x - half_size.x)), int(floor(current_pos.y - half_size.y)))
	var entity_max = Vector2i(int(ceil(current_pos.x + half_size.x)), int(ceil(current_pos.y + half_size.y)))
	for tx in range(entity_min.x, entity_max.x):
		for ty in range(entity_min.y, entity_max.y):
			var check_pos = Vector2(tx + 0.5, ty + 0.5)
			var td = GameServices.chunk_manager.get_tile_at_world_pos(check_pos)
			var dmg = TileIndex.get_damage(td[0])
			if dmg > 0.0:
				tile_damage = maxf(tile_damage, dmg)

	return {
		"position": current_pos,
		"velocity": velocity,
		"is_on_floor": is_on_floor,
		"floor_tile_id": floor_tile_id,
		"tile_damage": tile_damage,
	}


# Attempts to step up a small obstacle. Returns new position or Vector2.ZERO if failed.
func _try_step_up(intended_move: Vector2, original_pos: Vector2) -> Vector2:
	var lifted_pos = original_pos + Vector2(0, -step_height)

	if _collision_detector.intersect_aabb(lifted_pos, collision_box_size):
		return Vector2.ZERO

	var result_fwd = _collision_detector.sweep_aabb(lifted_pos, collision_box_size, intended_move)

	if result_fwd.position.distance_squared_to(lifted_pos) < 0.1:
		return Vector2.ZERO

	var snap_vec = Vector2(0, step_height * 2.0)
	var result_down = _collision_detector.sweep_aabb(result_fwd.position, collision_box_size, snap_vec)

	if result_down.collided and result_down.normal.y < -0.5:
		return result_down.position

	return Vector2.ZERO
