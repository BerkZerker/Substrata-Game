class_name FrameGraph extends Control

const HISTORY_SIZE: int = 120
const GRAPH_WIDTH: float = 200.0
const GRAPH_HEIGHT: float = 80.0
const MARGIN: float = 8.0
const TARGET_16MS: float = 16.667
const TARGET_33MS: float = 33.333

var _frame_times: PackedFloat32Array = PackedFloat32Array()
var _label: Label


func _ready() -> void:
	visible = false
	custom_minimum_size = Vector2(GRAPH_WIDTH + MARGIN * 2, GRAPH_HEIGHT + MARGIN * 2 + 20)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 11)
	_label.position = Vector2(MARGIN, MARGIN)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)

	_frame_times.resize(HISTORY_SIZE)
	_frame_times.fill(0.0)


func _process(delta: float) -> void:
	if not visible:
		return

	# Shift history and record new frame time
	for i in range(HISTORY_SIZE - 1):
		_frame_times[i] = _frame_times[i + 1]
	_frame_times[HISTORY_SIZE - 1] = delta * 1000.0

	# Compute stats
	var total: float = 0.0
	var max_ft: float = 0.0
	var sorted_times: Array[float] = []
	for i in range(HISTORY_SIZE):
		var ft = _frame_times[i]
		if ft > 0.0:
			total += ft
			sorted_times.append(ft)
			if ft > max_ft:
				max_ft = ft

	var count = sorted_times.size()
	var avg: float = total / count if count > 0 else 0.0
	var fps: int = int(Engine.get_frames_per_second())

	# 1% low (99th percentile frame time)
	sorted_times.sort()
	var p99: float = 0.0
	if count > 0:
		var idx = int(count * 0.99)
		if idx >= count:
			idx = count - 1
		p99 = sorted_times[idx]

	_label.text = "FPS: %d  Avg: %.1f ms  1%%low: %.1f ms" % [fps, avg, p99]

	queue_redraw()


func _draw() -> void:
	# Background
	var bg_rect = Rect2(Vector2.ZERO, custom_minimum_size)
	draw_rect(bg_rect, Color(0, 0, 0, 0.6))

	var graph_origin = Vector2(MARGIN, MARGIN + 18)
	var max_display_ms: float = 50.0 # Cap at 50ms for scale

	# Threshold lines
	var y_16 = graph_origin.y + GRAPH_HEIGHT * (1.0 - TARGET_16MS / max_display_ms)
	var y_33 = graph_origin.y + GRAPH_HEIGHT * (1.0 - TARGET_33MS / max_display_ms)
	draw_line(Vector2(graph_origin.x, y_16), Vector2(graph_origin.x + GRAPH_WIDTH, y_16), Color(0.5, 0.5, 0.0, 0.4), 1.0)
	draw_line(Vector2(graph_origin.x, y_33), Vector2(graph_origin.x + GRAPH_WIDTH, y_33), Color(0.5, 0.0, 0.0, 0.4), 1.0)

	# Frame time bars
	var bar_width = GRAPH_WIDTH / float(HISTORY_SIZE)
	for i in range(HISTORY_SIZE):
		var ft = _frame_times[i]
		if ft <= 0.0:
			continue

		var height = clampf(ft / max_display_ms, 0.0, 1.0) * GRAPH_HEIGHT
		var x = graph_origin.x + i * bar_width

		var color: Color
		if ft < TARGET_16MS:
			color = Color(0.2, 0.8, 0.2) # green
		elif ft < TARGET_33MS:
			color = Color(0.9, 0.8, 0.1) # yellow
		else:
			color = Color(0.9, 0.2, 0.2) # red

		draw_rect(Rect2(x, graph_origin.y + GRAPH_HEIGHT - height, bar_width, height), color)
