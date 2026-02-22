## Base class for all game entities with optional physics movement.
##
## Provides a velocity vector, collision box size, and optional MovementController
## composition. Override _entity_update() for per-entity logic and
## _get_movement_input() to supply movement inputs to the controller.
class_name BaseEntity extends Node2D

## Size of the entity's collision box.
@export var collision_box_size: Vector2 = Vector2(10, 16)

## Current velocity (readable by external systems).
var velocity: Vector2 = Vector2.ZERO

## Unique ID assigned by EntityManager.
var entity_id: int = -1

## Current chunk position, tracked by EntityManager.
var chunk_pos: Vector2i = Vector2i.ZERO

## Optional movement controller for physics-based movement.
var _movement: MovementController = null


## Called each physics frame by EntityManager. Runs movement (if controller
## exists) then calls _entity_update() for subclass logic.
func entity_process(delta: float) -> void:
	if _movement:
		var input = _get_movement_input()
		var result = _movement.move(position, input.x, input.y > 0, delta)
		position = result.position
		velocity = _movement.velocity
	_entity_update(delta)


## Override in subclasses for custom per-frame logic.
func _entity_update(_delta: float) -> void:
	pass


## Override in subclasses to provide movement input.
## Return Vector2 where x = horizontal axis (-1..1), y > 0 means jump.
func _get_movement_input() -> Vector2:
	return Vector2.ZERO


## Initializes the optional MovementController with a CollisionDetector.
func setup_movement(collision_detector: CollisionDetector) -> void:
	_movement = MovementController.new(collision_detector)
	_movement.collision_box_size = collision_box_size
