@tool
extends ColorRect
class_name InfiCanvas

## A window to an area that always has as much space as you need.[br]
## It takes SpatialPartition instances to track contained objects and quickly find them or cull them (implemented by an extending this class).[br]
## Use [code]place_object()[/code] for what is to be added to the canvas, then override [code]draw_*_geometry()[/code] to tell how to display that object with custom draw calls if necessary.[br]
## You can find the objects in view by applying the provided [code]canvas_rect[/code] to [code]SpatialPartition.find_objects_*()[/code.[br]
## Other UI details like the background pattern and the compass arrow can also be changed by overriding their functions.[br]
## Remember to use coordinates translated into canvas coordinates with [code]to_canvas_coord()[/code], or things will looks fixed on the screen. Then convert back with [code]to_screen_coord()[/code], for them to display in the correct place on screen.[br]
## There are equivalent functions for Rect2, [code]to_canvas_rect()[/code], [code]to_screen_rect()[/code], which will resize a rect according to zoom.[br]
## If you are seeing background patterns being drawn outside the visible area, set "Layout/Clip Contents" in the inspector.

#TODO Make zoom into the center
#FIXME go_to(Vector2.ZERO) doesn't seem to work if InfiCanvas isn't root node.


const DEBUGGING = false
const MINIMUM_LASSO = Vector2(16,16)  # A lasso operation is only performed if its rect size is larger than this. Otherwise, a click was probably intended.
const SCROLL_SPEED = Vector2(20, 20)
const ZOOM_SPEED = 0.2

@export var parti : Dictionary[Variant, SpatialPartition] ## Partition spaces available, indexed by a String or an Enum.

var all_objs : Dictionary[Variant, SpatialPartition]  # Track which partitions objects are in.

@export_enum("Mouse Motion", "Input Event", "Process", "Physics")  var overlay_mode : String = "Mouse Motion" ##  Method that updates the overlay. It will always update when this class redraws.
@export_group("Appearance")
@export_range(1, 200, 1, "or_greater") var cell_size : int = 50 :   ## The nominal size for the background pattern.
	set(val):
		cell_size = val
		queue_redraw()
@export var min_cell_size : int = 8 :  ## As you zoom out and cells become smaller, how small until we just don't bother rendering?
	set(val):
		min_cell_size = clamp(val, 1, cell_size)
		queue_redraw() 
@export var grid_thick : int = 2 :  ## Width of the lines for drawing background pattern.
	set(val):
		grid_thick = clamp(val, -1, min_cell_size)
		queue_redraw() 
@export var orig_thick : int = 4 :  ## Width of the lines for drawing the origin indicator.
	set(val):
		orig_thick = clamp(val, -1, min_cell_size)
		queue_redraw() 
@export var lasso_thick : int = 6 ## Width of the lines of the selection box.
@export var grid_color := Color.BLACK :  ## Color of background pattern lines.
	set(val):
		grid_color = val
		queue_redraw() 
@export var orig_color := Color.RED :  ## Color of the lines for the origin indicator.
	set(val):
		orig_color = val
		queue_redraw() 
@export var lasso_main_color := Color.WEB_GREEN  ## First color for the selection box.
@export var lasso_alter_color := Color.YELLOW  ## Second color for the selection box.
@export var chirality := CHIRAL.NONE ## What type of selection can be done.

enum CHIRAL{
	NONE, ## Just a main color selection lasso is used.
	HORIZONTAL, ## Lasso type is different if dragging starts from right or left.
	VERTICAL, ## Lasso type is different if dragging starts from the top or the bottom.
}

#region Boilerplate
var _camera : Camera2D
var _nodes : Node
var forecanvas : Control
var overlay : Control
var center : Vector2
func _init():
	if not item_rect_changed.is_connected(_on_rect_changed):
		item_rect_changed.connect(_on_rect_changed)
	_camera = Camera2D.new()
	_camera.limit_enabled = false
	_camera.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	zoom = _camera.zoom.x
	_nodes = Node.new()
	_nodes.name = "_NODES_"
	var subviewportcontainer := SubViewportContainer.new()
	subviewportcontainer.stretch = true
	var subviewport := SubViewport.new()
	subviewport.transparent_bg = true
	subviewportcontainer.add_child(subviewport)
	subviewport.add_child(_camera)
	subviewport.add_child(_nodes)
	add_child(subviewportcontainer)
	_nodes.owner = self
	subviewportcontainer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	forecanvas = Control.new()
	forecanvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(forecanvas)
	forecanvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	forecanvas.draw.connect(_draw_fore_geometry)
	overlay = Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE 
	add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.draw.connect(_draw_overlay)
	
	await ready
	go_to(Vector2.ZERO)

func _process(_delta: float) -> void:
	if overlay_mode == "Process": overlay.queue_redraw()
func _physics_process(_delta: float) -> void:
	if overlay_mode == "Physics": overlay.queue_redraw()

func _on_rect_changed():
	center = get_rect().get_center()
	#_camera.offset = center

var _selected : Array : set=set_selected  ## Objects in the canvas that the user selects as a group or individually.[br] InfiCanvas doesn't actually select objects. Either the script objects sets them to be selected or an extension of InfiCanvas decides what objects to select and how, based on lasso Rect2 or not.
var _selected_positions : Array  ## Initial position of selected objects before drag-moving them.

var is_moving_obj : bool = false  # Are selected objects in the canvas supposed to move in space? Activation flag.
var move_obj_allowed : bool = true  # May the selected objects in canvas move? Inhibition flag.

var pan_allowed : bool = true  # Is scrolling the view allowed?

var lasso_allowed : bool = true
var lasso_mode : bool  ## Type of selection last drawn. Depends on [code]chirality[/code].
var lasso_screen_rect : Rect2  ## This is the area of the last box selection. Only updated when the selection operation ends. Even when the [code]lasso_allowed[/code] is [code]false[/code], this variable is still computed as it provides utility to mouse drag operations in general.
var lasso_canvas_rect : Rect2  ## This the area of the last box selection performed, and is being performed; it updates as the box is drawn. Even when the [code]lasso_allowed[/code] is [code]false[/code], this variable is still computed as it provides utility to mouse drag operations in general.

var _ini_origin : Vector2
var ini_mouse : Vector2  ## Coordinate of the mouse when the left button was last pressed.
var fin_mouse : Vector2  ## Coordinate of the mouse when the left button was last released. Current mouse button can be found with [code]get_local_mouse_position()[/code].

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.is_pressed():
			match event.button_index:
				MOUSE_BUTTON_LEFT:
					pass
				MOUSE_BUTTON_MIDDLE:
					_ini_origin = origin
				MOUSE_BUTTON_WHEEL_UP:
					if Input.is_key_pressed(KEY_CTRL):
						zoom += ZOOM_SPEED
					else:
						origin.y += SCROLL_SPEED.y
				MOUSE_BUTTON_WHEEL_DOWN:
					if Input.is_key_pressed(KEY_CTRL):
						zoom -= ZOOM_SPEED
					else:
						origin.y -= SCROLL_SPEED.y
				MOUSE_BUTTON_WHEEL_LEFT:
					origin.x += SCROLL_SPEED.x
				MOUSE_BUTTON_WHEEL_RIGHT:
					origin.x -= SCROLL_SPEED.x

func _input(event: InputEvent) -> void:
	if overlay_mode == "Input Event": overlay.queue_redraw()
	
	if event is InputEventKey and event.is_released():
		if event.keycode == KEY_ESCAPE:
			escape_key_action()
	
	if event is InputEventMouseButton:
		if event.is_pressed():
			match event.button_index:
				MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
					ini_mouse = get_local_mouse_position()
					# Reset Rects
					lasso_screen_rect = Rect2()
					lasso_canvas_rect = Rect2()
		elif event.is_released():
			match event.button_index:
				MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
					fin_mouse = get_local_mouse_position()
					lasso_canvas_rect = to_canvas_rect(lasso_screen_rect)
					queue_redraw()
	
	if event is InputEventMouseMotion:
		if overlay_mode == "Mouse Motion": overlay.queue_redraw()
		if lasso_allowed and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			queue_redraw()
			
		var displacement = get_local_mouse_position() - ini_mouse
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			lasso_screen_rect = Rect2(ini_mouse, displacement).abs()
			if pan_allowed:
				origin = _ini_origin + displacement / zoom
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			lasso_screen_rect = Rect2(ini_mouse, displacement).abs()
			match chirality:
				CHIRAL.NONE:
					lasso_mode = false
				CHIRAL.HORIZONTAL:
					lasso_mode = displacement.x < 0
				CHIRAL.VERTICAL:
					lasso_mode = displacement.y < 0
		
		if is_moving_obj and move_obj_allowed:
			queue_redraw()  # Update highlighting
			for i in range(_selected.size()):
				var obj = _selected[i]
				var data : Dictionary = get_obj_data(obj)
				data.position = obj_movement_modulate(_selected_positions[i] + displacement / zoom)
				if "position" in obj:
					obj.position = data.position

## Override this function to implement things like grid snapping.
func obj_movement_modulate(new_position:Vector2) -> Vector2:
	return new_position

## Call this function if selected objects are about to be moved.
func selected_obj_movement_start():
	if move_obj_allowed:
		lasso_allowed = false
		is_moving_obj = true
		_selected_positions.clear()
		for each in _selected:
			if get_obj_data(each).centered:
				_selected_positions.append(get_obj_rect(each).get_center())
			else:
				_selected_positions.append(get_obj_rect(each).position)

## You need to call this when the movement operations has finished.[br]
## This calls a [code]_canvas_reposition()[/code] method on each moved object,
## if implemented.
func selected_obj_movement_stop():
	queue_redraw()
	lasso_allowed = true
	if is_moving_obj:
		is_moving_obj = false
		for i in range(_selected.size()):
			var obj = _selected[i]
			var data : Dictionary = get_obj_data(obj)
			all_objs[obj].update_object(obj)
			if obj.has_method("_canvas_reposition"):
				obj._canvas_reposition(data)

func set_selected(val:Array):
		_selected = val
		if not val.is_empty():
			queue_redraw()  # Update the highlighting
#endregion

#region Canvas Handling
var origin := Vector2.ZERO :  ## position in Canvas frame of reference.
	set(val):
		_origin_moved(origin, val)
		origin = val
		_camera.position = -val
		queue_redraw()
	get():
		return -_camera.position
var zoom : float = 0.0 : set=set_zoom

func set_zoom(val:float):
		zoom = clamp(val, 0.25, 4)
		_camera.zoom = Vector2.ONE * zoom
		queue_redraw()

func go_to(canvas_coord:Vector2):
	origin = canvas_coord + center * zoom

## What's the position local to the ColorRect of the Canvas frame origin.
func to_screen_coord(canvas_coord:Vector2, offset := Vector2.ZERO) -> Vector2:
	return (origin + offset + canvas_coord) * zoom

## What's the position in Canvas frame of a local position value.
func to_canvas_coord(screen_coord:Vector2, offset:=Vector2.ZERO) -> Vector2:
	screen_coord /= zoom
	return screen_coord - origin + offset

func to_screen_rect(canvas_rect:Rect2) -> Rect2:
	var rect = Rect2()
	rect.position = to_screen_coord(canvas_rect.position)
	rect.end = to_screen_coord(canvas_rect.end)
	return rect

func to_canvas_rect(screen_rect:Rect2) -> Rect2:
	var rect = Rect2()
	rect.position = to_canvas_coord(screen_rect.position)
	rect.end = to_canvas_coord(screen_rect.end)
	return rect

## Register an object to a partition. If no partition is provided, it uses a default one.[br]
## Objects can be anything which contains a [code]position[/code] key or property, and optionally a [code]get_rect()[/code] method.
## This includes Dictionaries like [code]{"position"=Vector2.ZERO}[/code], instances of inner classes and obviously, normal classes like Godot nodes.
## Returns the partition data of that object, where options can be changed. If the object changes position, call [code]SpatialPartition.update_object()[/code].
func place_object(obj, canvas_coord:Vector2, partition:SpatialPartition=parti[0 as Variant]) -> Dictionary:
	all_objs[obj] = partition
	var data = partition.add_object(obj, canvas_coord)
	obj.position = canvas_coord
	if obj is Node:
		_nodes.add_child(obj)
		obj.owner = self
	return data

func remove_object(obj) -> Dictionary:
	var partition = all_objs.get(obj, parti[0 as Variant])
	all_objs.erase(obj)
	var data = partition.remove_object(obj)
	if obj is Node:
		_nodes.remove_child(obj)
	return data
#endregion

#region Drawing Functions
var _view_rect : Rect2
func _draw():
	var local_origin = to_screen_coord(Vector2.ZERO)
	var view_x = local_origin.x > 0 and local_origin.x < size.x
	var view_y = local_origin.y > 0 and local_origin.y < size.y
	
	_view_rect = to_canvas_rect(Rect2(Vector2.ZERO, size))
	
	draw_background_pattern(local_origin, to_screen_coord(Vector2.ONE * cell_size, -origin).x)
	draw_origin_axis(view_x, view_y, local_origin)
	if not (view_x and view_y):
		draw_compass()
	
	draw_back_geometry(_view_rect)
	highlight_selection(_selected)
	forecanvas.queue_redraw()
	overlay.queue_redraw()
	
	if lasso_allowed and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		draw_lasso()
	
	if DEBUGGING:
		## This shows a blue rectangle of the `canvas_rect` given to `draw_*_geometry()` (a little shrunk for better visibility).
		## Then checkered green and orange squares are the partitions being being searched according to that `canvas_rect`.
		## The red squares are also searched, but are at the limits of what is searched, so there's no doubt about whether the search area is too big or not.
		## `find_objects()` will return any object in any of the squares.
		## `find_objects_simple()` will return those which top-left corner (position coordinate) stay inside the blue.
		## `find_objects_tolerant()` will return the objects which bounding rect still touches the blue, but not if completely outside.
		## `find_objects_zealous()` will return the objects which bounding rect is completely inside the blue.
		
		
		var start = parti[0 as Variant].make_partition_id(_view_rect.position) - Vector2i.ONE * 1
		var stop = parti[0 as Variant].make_partition_id(_view_rect.end) + Vector2i.ONE * 1
		var parti_size = Vector2.ONE * parti[0 as Variant].root_size
		for x in range(start.x, stop.x):
			for y in range(start.y, stop.y):
				var rect = Rect2(
					Vector2(x,y) * parti_size,
					parti_size
					)
				var c = [Color.LIME_GREEN, Color.ORANGE][int(x % 2 == 0) ^ int(y % 2 == 0)]
				if x <= start.x or x >= stop.x - 1 or y <= start.y or y >= stop.y - 1:
					c = Color.DARK_RED
				rect = to_screen_rect(rect).grow(-6)
				draw_rect(rect, c, false, 6)
		draw_rect(to_screen_rect(_view_rect).grow(-20), Color.BLUE, false, 2)

## The grid pattern, or whatever else, if overriden.
func draw_background_pattern(offset:Vector2, spacing:float):
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
		
		var true_thick = float(grid_thick) * zoom
		if true_thick <= 1:  # if line thickness is less than one pixel, just render always at one pixel
			true_thick = -1
		draw_multiline(grid, grid_color, true_thick)

## Draw lines towards the origin.
func draw_origin_axis(x_visible:bool, y_visible:bool, offset:Vector2):
	if x_visible:  # Vertical Origin Line
		draw_dashed_line(Vector2(offset.x, 0), Vector2(offset.x, size.y), orig_color, orig_thick, cell_size * 0.2)
	if y_visible:  # Horizontal Origin Line
		draw_dashed_line(Vector2(0, offset.y), Vector2(size.x, offset.y), orig_color, orig_thick, cell_size * 0.2)

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

func draw_lasso():
	draw_rect(lasso_screen_rect, [lasso_main_color, lasso_alter_color][int(lasso_mode)], false, lasso_thick)

## Draw highlight effect on selected objects.
func highlight_selection(selected_objs:Array):
	for obj in selected_objs:
		var rect = get_obj_rect(obj)
		rect.position = to_screen_coord(rect.position)
		rect.size *= zoom
		draw_rect(rect, Saliko.negate_color(color), false, lasso_thick)
#endregion

#region Helper Functions
func get_obj_data(obj) -> Dictionary:
	return all_objs[obj].get_obj_data(obj)


## Return a Rect2 for object, enabling a way to tell if an object still counts as within selection, even if it's origin coordinate would be excluded.
func get_obj_rect(obj) -> Rect2:
	return all_objs[obj].get_obj_rect(obj)

#endregion

#region Override Functions
## Decide if something happens when the canvas origin is changed.
@warning_ignore("unused_parameter")
func _origin_moved(past:Vector2, future:Vector2):
	pass

## Cancel operations or exit some action.
func escape_key_action():
	if is_moving_obj:
		selected_obj_movement_stop()
		is_moving_obj = false
		lasso_allowed = true
		return
	if not _selected.is_empty():
		queue_redraw()
		_selected.clear()
		_selected_positions.clear()
		return

## Objects in partitions might not have an intrinsic visual representation, like Godot Nodes do.
## How you override [code]draw_*_geometry()[/code] defines how to interpret the object's data.[br]
## This draws behind child nodes.
@warning_ignore("unused_parameter")
func draw_back_geometry(viewed_canvas_rect:Rect2):
	pass

func _draw_fore_geometry():
	draw_fore_geometry(forecanvas, _view_rect)

## Objects in partitions might not have an intrinsic visual representation, like Godot Nodes do.
## How you override [code]draw_*_geometry()[/code] defines how to interpret the object's data.[br]
## This draws in front child nodes, by using draw calls on [code]canvas[/code].
@warning_ignore("unused_parameter")
func draw_fore_geometry(canvas:Control, viewed_canvas_rect:Rect2):
	pass

@warning_ignore("unused_parameter")
func _draw_overlay():
	draw_overlay(overlay, _view_rect)

## This draws in front of everything, by using draw calls on [code]canvas[/code].[br]
## This is similar to [code]draw_fore_geometry[/code], but updates independently,
## intended for re-drawing at high frequency, like effects on mouse motion.[br]
## See [code]overlay[/code] for more information.
@warning_ignore("unused_parameter")
func draw_overlay(canvas:Control, viewed_canvas_rect:Rect2):
	pass

#endregion
