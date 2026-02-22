## Composable health component for entities with damage, healing, and invincibility.
##
## Attach to any entity via composition. Call process(delta) each frame to tick
## the invincibility timer. Emits signals through SignalBus when the owning
## entity takes damage, heals, or dies.
class_name HealthComponent extends RefCounted

var max_health: float = 100.0
var current_health: float = 100.0
var invincibility_duration: float = 1.0

## Entity ID of the owner, used for signal emission.
var entity_id: int = -1

var _invincibility_timer: float = 0.0


func _init(p_max_health: float = 100.0, p_entity_id: int = -1) -> void:
	max_health = p_max_health
	current_health = p_max_health
	entity_id = p_entity_id


## Tick the invincibility timer. Call each frame.
func process(delta: float) -> void:
	if _invincibility_timer > 0.0:
		_invincibility_timer -= delta
		if _invincibility_timer < 0.0:
			_invincibility_timer = 0.0


## Attempts to deal damage. Returns false if currently invincible.
## knockback_direction is passed through the signal for the owner to apply.
func take_damage(amount: float, knockback_direction: Vector2 = Vector2.ZERO) -> bool:
	if amount <= 0.0 or is_invincible() or is_dead():
		return false

	current_health = maxf(current_health - amount, 0.0)
	_invincibility_timer = invincibility_duration
	SignalBus.entity_damaged.emit(entity_id, amount, knockback_direction)

	if is_dead():
		SignalBus.entity_died.emit(entity_id)

	return true


## Heals the entity, clamped to max_health.
func heal(amount: float) -> void:
	if amount <= 0.0 or is_dead():
		return
	var old_health = current_health
	current_health = minf(current_health + amount, max_health)
	if current_health > old_health:
		SignalBus.entity_healed.emit(entity_id, current_health - old_health)


## Returns true if health is zero.
func is_dead() -> bool:
	return current_health <= 0.0


## Returns true if the invincibility timer is active.
func is_invincible() -> bool:
	return _invincibility_timer > 0.0


## Returns health as a 0.0-1.0 fraction.
func get_health_percent() -> float:
	if max_health <= 0.0:
		return 0.0
	return current_health / max_health


## Resets health to max and clears invincibility.
func reset() -> void:
	current_health = max_health
	_invincibility_timer = 0.0
