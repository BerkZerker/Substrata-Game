## Day/night cycle controller.
##
## Tracks time of day (0.0=midnight, 0.5=noon) and provides an ambient light
## level via a sine curve. Advance each frame from LightManager.
class_name TimeOfDay extends RefCounted

## Current time (0.0 = midnight, 0.5 = noon, 1.0 = next midnight).
var time: float = 0.25 # Start at dawn

## Duration of a full day/night cycle in seconds.
var day_duration_seconds: float = 600.0


## Returns the ambient light level (0.05–1.0) based on current time.
func get_ambient_level() -> float:
	# Sine curve: peak at 0.5 (noon), trough at 0.0/1.0 (midnight)
	var sine_val = sin(time * TAU - PI * 0.5) # -1 at midnight, +1 at noon
	# Map [-1, 1] to [0.05, 1.0]
	return lerpf(0.05, 1.0, (sine_val + 1.0) * 0.5)


## Advances time by delta seconds. Wraps around at 1.0.
func advance(delta: float) -> void:
	if day_duration_seconds > 0.0:
		time += delta / day_duration_seconds
		time = fmod(time, 1.0)
