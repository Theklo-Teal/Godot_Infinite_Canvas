@tool
extends ColorRect
class_name InfiCanvas

## A window to an area that has as much space as you need.
## Should implement spatial partitioning of child objects.

@export var partition_size : float = 100  ## Bigger number makes searching objects in the canvas faster, but less accurate.

@export_group("Style")
@export var cell_size : int = 50 ## The nominal size for the background pattern.
@export var min_cell_size : int = 8 ## As you zoom out and cells become smaller, how small until we just don't bother rendering?
@export var grid_thick : int = 2 ## Width of the lines for drawing background pattern.
@export var orig_thick : int = 4 ## Width of the lines for drawing the origin indicator.
@export var lasso_thick : int = 6 ## Width of the lines of the selection box.
@export var grid_color := Color.BLACK  ## Color of background pattern lines.
@export var orig_color := Color.RED ## Color of the lines for the origin indicator.
@export var lasso_main_color := Color.WEB_GREEN  ## First color for the selection box.
@export var lasso_alter_color := Color.YELLOW  ## Second color for the selection box.
@export var chirality := CHIRAL.NONE ## What type of selection can be done.

enum CHIRAL{
	NONE, ## Just a main color selection lasso is used.
	HORIZONTAL, ## Lasso type is different if dragging starts from right or left.
	VERTICAL, ## Lasso type is different if dragging starts from the top or the bottom.
}


@warning_ignore("unused_private_class_variable")
var _parti : Dictionary[Vector2i, Array]  ## Index of objects at each partition.
@warning_ignore("unused_private_class_variable")
var _objs : Dictionary[Variant, Dictionary]  ## Back index for `_parti`. The dictionary includes the index "idx" and true coordinate of the object "coord".
var origin := Vector2.ZERO ## position in Canvas frame of reference.
var zoom : float = 1.0 : ## Scaling of the Canvas.
	set(val):
		var target = to_canvas_position(center)  #NOTE: This needs to be called before changing the zoom.
		zoom = snappedf(max(val, 0.5), 0.001)
		go_to(target)  #NOTE: This needs to be called relative to the new zoom.

func _init() -> void:
	item_rect_changed.connect(__on_rect_changed)
	await ready
	go_to.call_deferred(Vector2.ZERO)

func __on_rect_changed():
	center = get_rect().get_center()


var center : Vector2
var lasso_chiral : bool
var lasso_rect : Rect2
var is_dragging : bool = false
var ini_origin : Vector2  # The origin before panning
var ini_mouse : Vector2  # The mouse local position before panning
var mouse_pos : Vector2  # Current mouse position


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_released():
				if not is_dragging:
					if abs(lasso_rect.size.x) > partition_size * zoom and abs(lasso_rect.size.y) > partition_size * zoom:
						lasso_select()
						is_dragging = false
				queue_redraw()
			elif event.is_pressed():
				is_dragging = object_pressed()
				ini_mouse = event.position
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			ini_mouse = event.position
			ini_origin = origin
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom -= 0.2 * zoom
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom += 0.2 * zoom
	
	if event is InputEventMouseMotion:
		mouse_pos = event.position
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			var displacement = event.position - ini_mouse
			origin = ini_origin + to_canvas_position(displacement, origin)
			queue_redraw()
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not is_dragging:
			queue_redraw()


func _draw():
	var local_orig = to_local_position(Vector2.ZERO)
	var view_x = local_orig.x > 0 and local_orig.x < size.x
	var view_y = local_orig.y > 0 and local_orig.y < size.y
	
	draw_background(local_orig, to_local_position(Vector2.ONE * cell_size, -origin).x)
	
	if view_x:  # Vertical Origin Line
		draw_dashed_line(Vector2(local_orig.x, 0), Vector2(local_orig.x, size.y), orig_color, orig_thick, cell_size * 0.2)
	if view_y:  # Horizontal Origin Line
		draw_dashed_line(Vector2(0, local_orig.y), Vector2(size.x, local_orig.y), orig_color, orig_thick, cell_size * 0.2)
	
	draw_geometry(to_canvas_rect(get_rect()))
	
	draw_selection_lasso()
	
	if not (view_x and view_y):
		draw_compass()

#region Draw Functions
## The grid pattern, or whatever else, if overriden.
func draw_background(offset:Vector2, spacing:float):
	if spacing > min_cell_size:  # Don't draw stuff if it all gets bunched up.
		
		offset.x = fmod(offset.x, spacing)
		offset.y = fmod(offset.y, spacing)
		
		var grid : PackedVector2Array
		var coverage : float = 0
		while coverage < size.x + spacing:
			var stride = coverage + offset.x
			grid.append(Vector2(stride, 0))
			grid.append(Vector2(stride, size.y))
			coverage += spacing
		coverage = 0
		while coverage < size.y + spacing:
			var stride = coverage + offset.y
			grid.append(Vector2(0, stride))
			grid.append(Vector2(size.x, stride))
			coverage += spacing
		
		var true_thick = float(grid_thick) / zoom
		if true_thick <= 1:  # if line thickness is less than one pixel, just render always at one pixel
			true_thick = -1
		draw_multiline(grid, grid_color, true_thick)

## How a box for selecting objects is rendered.
func draw_selection_lasso():
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not is_dragging:
		var displacement = mouse_pos - ini_mouse 
		lasso_rect = Rect2(
			ini_mouse,
			displacement
			)
		
		match chirality:
			CHIRAL.NONE:
				lasso_chiral = false
			CHIRAL.HORIZONTAL:
				lasso_chiral = displacement.dot(Vector2.LEFT) > 0
			CHIRAL.VERTICAL:
				lasso_chiral = displacement.dot(Vector2.UP) > 0
		
		draw_rect(lasso_rect, [lasso_main_color, lasso_alter_color][int(lasso_chiral)], false, lasso_thick)

## Draw a Compass towards the origin.
func draw_compass():
	var compass_dir : Vector2 = center.direction_to(origin)
	
	var max_axis = compass_dir.abs().max_axis_index()
	var sticky_side : float = [Vector2.RIGHT, Vector2.DOWN][max_axis].dot(compass_dir)
	sticky_side = [50, size[max_axis] - 50][int(sticky_side >= 0)]
	
	var min_axis = compass_dir.abs().min_axis_index()
	var sliding_side : float = [Vector2.RIGHT, Vector2.DOWN][min_axis].dot(compass_dir) + 1
	sliding_side = sliding_side * (size[min_axis] - 50) * 0.5

	var compass_pos : Vector2
	compass_pos[min_axis] = sliding_side
	compass_pos[max_axis] = sticky_side
	
	var arc_span : float = PI * 0.35
	draw_arc(compass_pos, 27, compass_dir.angle() - arc_span, compass_dir.angle() + arc_span, 3, orig_color, 12)

## Draw the placed objects which are meant to be rendered with Godot `draw_*` calls.
## `canvas_rect` of the view area is supplied for use with `find_objects()` to decide which objects to render.
func draw_geometry(_canvas_rect:Rect2):
	pass
#endregion


#region Utility Functions

## What's the position in Canvas frame of a local position value.
func to_canvas_position(local_pos:Vector2, offset:=Vector2.ZERO) -> Vector2:
	local_pos *= zoom
	return local_pos - origin + offset

## What's the position local to the ColorRect of the Canvas frame origin.
func to_local_position(canvas_pos:Vector2, offset:=Vector2.ZERO) -> Vector2:
	return (canvas_pos + origin + offset) / zoom

func to_canvas_rect(local_rect:Rect2) -> Rect2:
	var canvas : Rect2
	canvas.position = to_canvas_position(local_rect.position)
	canvas.end = to_canvas_position(local_rect.end)
	return canvas

func to_local_rect(canvas_rect:Rect2) -> Rect2:
	var local : Rect2
	local.position = to_local_position(canvas_rect.position)
	local.end = to_local_position(canvas_rect.end)
	return local

## Set the center of the view on this Canvas coordinate.
func go_to(canvas_pos:Vector2):
	origin = canvas_pos + (center * zoom)
	queue_redraw()
#endregion

#region Handling and Searching Objects with Spatial Partitioning

## Returns the Vector2i index of the partition this object is found at.
func get_obj_idx(obj, parti_name:StringName="_"):
	var data : Dictionary = get(parti_name + "objs").get(obj, null)
	if data != null:
		return data.get("idx", null)

## Returns the true coordinate of the object on the canvas.
func get_obj_coord(obj, parti_name:StringName="_"):
	var data : Dictionary = get(parti_name + "objs").get(obj, null)
	if data != null:
		return data.get("coord", null)

## Return a Rect2 in to object allowing use to tell if an object still counts as within selection, even if it's origin coordinate would be excluded.
func get_obj_rect(obj, parti_name:StringName="_") -> Rect2:
	var data : Dictionary = get(parti_name + "objs").get(obj, null)
	if data != null:
		return _get_obj_rect(obj, parti_name, data)
	else:
		return Rect2()

## Override this function with the appropriate calculation of the Rect for the particular type of objects you are placing on the canvas.
## By default, it assumes a point entity at the same position as the coordinate.
func _get_obj_rect(_obj, _parti_name:StringName="_", data:={}) -> Rect2:
	return Rect2(data.coord,
				Vector2.ZERO)

## Register object as belonging to the Canvas. If it's a Node, use `add_child()` separatedly.
## You may choose to select from your own partition by setting `parti_name`.
## `parti_name` is the variable name for a Dictionary[Vector2i, Variant], which name ends in "parti", and a Dictionary[Variant, Vector2i], which name ends in "objs".
func place_object(obj, canvas_pos:Vector2, parti_name:StringName="_"):
	var index : Vector2i = canvas_pos.snappedf(partition_size) as Vector2i
	var objs : Dictionary = get(parti_name + "objs")
	var part : Dictionary = get(parti_name + "parti")
	if not index in part:
		part[index] = []
	part[index].append(obj)
	objs[obj] = {"idx": index, "coord": canvas_pos}

## Change coordinate of an already registered object.
func move_object(obj, new_coord:Vector2, parti_name:StringName="_"):
	var old_idx = get_obj_idx(obj, parti_name)
	if old_idx != null:
		var new_idx : Vector2i = new_coord.snappedf(partition_size).round() as Vector2i
		var part : Dictionary = get(parti_name + "parti")
		var objs : Dictionary = get(parti_name + "objs")
		part[old_idx].erase(obj)
		if not new_idx in part:
			part[new_idx] = []
		part[new_idx].append(obj)
		objs[obj] = {"idx": new_idx, "coord": new_coord}

## Unregister objects from belonging to the Canvas. If it's a Node, use `remove_child()` separatedly.
## You may choose to select from your own partition by setting `parti_name`.
## `parti_name` is the variable name for a Dictionary[Vector2i, Variant], which name ends in "parti", and a Dictionary[Variant, Vector2i], which name ends in "objs".
func remove_objects(objs:Array, parti_name:StringName="_"):
	var part : Dictionary = get(parti_name + "parti")
	var curr : Dictionary = get(parti_name + "objs")
	for each in objs:
		var index : Vector2i = get_obj_idx(each)
		part[index].erase(each)
		curr.erase(each)
		if part[index].is_empty():
			part.erase(index)

## Performs a `remove_objects()` to all objects at given index, eventually removing the index from the partition.
func remove_indexes(idxs:Array, parti_name:StringName="_"):
	var part : Dictionary = get(parti_name + "parti")
	for index in idxs:
		var these = part.get(index, [])
		remove_objects(these, parti_name)

## Return all objects that are within a rectangle.
## You may choose to select from your own partition by setting `parti_name`.
## `parti_name` is the variable name for a Dictionary[Vector2i, Variant], which name ends in "parti", and a Dictionary[Variant, Vector2i], which name ends in "objs".
func find_objects(canvas_rect:Rect2, parti_name:StringName="_") -> Array:
	canvas_rect = canvas_rect.abs()
	var objs : Array[Variant] = []
	var part : Dictionary[Vector2i, Array] = get(parti_name + "parti")
	var start : Vector2i = canvas_rect.position.snappedf(partition_size).round() as Vector2i
	var stop : Vector2i = canvas_rect.end.snappedf(partition_size).round() as Vector2i
	#NOTE We add or subtract `partition_size` to grow selection area which avoids false negatives. False positives are handled by wrapper functions.
	start -= Vector2i.ONE * roundi(partition_size)
	stop += Vector2i.ONE * roundi(partition_size)
	for x in range(start.x, stop.x, partition_size):
		for y in range(start.y, stop.y, partition_size):
			@warning_ignore("narrowing_conversion")
			var index = Vector2i(x, y)
			objs += part.get(index, [])
	
	return objs

## A wrapper for searching objects while counting them in if their Rect2 intersects `canvas_rect`.
func find_objects_lazy(canvas_rect:Rect2, parti_name:StringName="_") -> Array:
	var objs : Array[Variant] = []
	for each in find_objects(canvas_rect, parti_name):
		if canvas_rect.intersects(get_obj_rect(each, parti_name), true):
			objs.append(each)
	return objs

## A wrapper for searching objects while counting them in only if their Rect2 is enclosed by `canvas_rect`.
func find_objects_greedy(canvas_rect:Rect2, parti_name:StringName="_") -> Array:
	var objs : Array[Variant] = []
	for each in find_objects(canvas_rect, parti_name):
		if canvas_rect.encloses(get_obj_rect(each, parti_name)):
			objs.append(each)
	return objs

#endregion

#region Override 
## Is some object in the canvas being clicked, so we should inhibit regular canvas mouse handling?
func object_pressed() -> bool:
	return false

## A lasso operation was performed. Get its Rect2 with `lasso_rect` and mode of lasso with `lasso_chiral`.
func lasso_select():
	pass
#endregion
