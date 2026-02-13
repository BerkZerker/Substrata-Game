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


func _init(collision_detector: CollisionDetector) -> void:
	_collision_detector = collision_detector


## Applies gravity, horizontal movement, step-up, and collision.
## Returns the new position after movement.
func move(current_pos: Vector2, input_axis: float, jump_pressed: bool, delta: float) -> Vector2:
	# Coyote timer
	if is_on_floor:
		_coyote_timer = coyote_time
	else:
		_coyote_timer -= delta

	# Gravity
	velocity.y += gravity * delta

	# Horizontal movement
	if input_axis != 0:
		velocity.x = move_toward(velocity.x, input_axis * speed, acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, friction * delta)

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

	return current_pos


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
