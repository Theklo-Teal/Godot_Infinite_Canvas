@tool
extends ColorRect
class_name InfiCanvas

## A window to an area that has as much space as you need.[br]
## It implements Spatial Hash partioning to quickly find objects and enable culling (implemented by an user's extension).[br]
## Use [code]place_obj()[/code] to any data relative to an object to be placed in the canvas, then override [code]draw_*_geometry()[/code] to tell how to display that object with custom draw calls.[br]
## You can find the objects in view by applying the provided [code]canvas_rect[/code] to [code]find_objects_*()[/code].[br]
## Other UI details like the background pattern and the compass arrow can also be changed by overriding their functions.[br]
## Remember to use coordinates translated into canvas coordinates with [code]to_canvas_coord()[/code], or things will looks fixed on the screen.

# MODIFICATIONS

#TODO Make zoom into the center
#FIXME go_to(Vector2.ZERO) doesn't seem to work if InfiCanvas isn't root node.


const DEBUGGING = false
const MINIMUM_LASSO = Vector2(16,16)  # A lasso operation is only performed if its rect size is larger than this. Otherwise, a click was probably intended.
const SCROLL_SPEED = Vector2(20, 20)
const ZOOM_SPEED = 0.2

@export_range(50, 1000, 1, "or_greater") var partition_size : int = 1000  ## Bigger number makes searching objects in the canvas faster, but less accurate. Typically you want partitions to be larger (bounding box Rect2.size) than most objects placed on them, or there will be false negatives with some functions.
@export_range(1, 200, 1, "or_greater") var snap_val : int = 16  ## The coordinates of objects on the canvas are snapped to this value, if registered using [code]place_object_snap()[/code].

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
var center : Vector2
func _init():
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
	
	await ready
	go_to(Vector2.ZERO)

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
						zoom -= ZOOM_SPEED
					else:
						origin.y += SCROLL_SPEED.y
				MOUSE_BUTTON_WHEEL_DOWN:
					if Input.is_key_pressed(KEY_CTRL):
						zoom += ZOOM_SPEED
					else:
						origin.y -= SCROLL_SPEED.y
				MOUSE_BUTTON_WHEEL_LEFT:
					origin.x += SCROLL_SPEED.x
				MOUSE_BUTTON_WHEEL_RIGHT:
					origin.x -= SCROLL_SPEED.x

func _input(event: InputEvent) -> void:
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
		if lasso_allowed and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			queue_redraw()
			
		var displacement = get_local_mouse_position() - ini_mouse
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			lasso_screen_rect = Rect2(ini_mouse, displacement).abs()
			if pan_allowed:
				origin = _ini_origin + displacement
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
				data.position = _selected_positions[i] + displacement / zoom
				if "position" in obj:
					obj.position = data.position

func selected_obj_movement_start():
	if move_obj_allowed:
		lasso_allowed = false
		is_moving_obj = true
		_selected_positions.clear()
		for each in _selected:
			var data : Dictionary = get_obj_data(each)
			_selected_positions.append(data.alt_position)

## You need to call this when the movement operations has finished.
func selected_obj_movement_stop():
	queue_redraw()
	lasso_allowed = true
	if is_moving_obj:
		is_moving_obj = false
		for i in range(_selected.size()):
			var obj = _selected[i]
			var data : Dictionary = get_obj_data(obj)
			update_object(obj)
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
#endregion

#region Drawing Functions
func _draw():
	var local_origin = to_screen_coord(Vector2.ZERO)
	var view_x = local_origin.x > 0 and local_origin.x < size.x
	var view_y = local_origin.y > 0 and local_origin.y < size.y
	
	var view_rect = to_canvas_rect(Rect2(Vector2.ZERO, size))
	
	draw_background_pattern(local_origin, to_screen_coord(Vector2.ONE * cell_size, -origin).x)
	draw_origin_axis(view_x, view_y, local_origin)
	if not (view_x and view_y):
		draw_compass()
	
	draw_back_geometry(view_rect)
	highlight_selection(_selected)
	draw_fore_geometry(view_rect)
	
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
		
		
		var start = make_partition_id(view_rect.position) - Vector2i.ONE * 1
		var stop = make_partition_id(view_rect.end) + Vector2i.ONE * 1
		var parti_size = Vector2.ONE * partition_size
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
		draw_rect(to_screen_rect(view_rect).grow(-20), Color.BLUE, false, 2)

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
		draw_rect(rect, Theklo.negate_color(color), false, lasso_thick)
#endregion

#region Spatial Hash Partionining, Searching and Handling Objects.

var obj_intel : Dictionary[Variant, Dictionary]  ## Back index for [code]_parti[/code]. The dictionary includes the index "parti_id", the "parti_name", as well as information in common with all objects like positioning and constraints.
@warning_ignore("unused_private_class_variable")
var __parti : Dictionary[Vector2i, Array]  ## [partition_id][idx] -> object_instance; Index of objects at each partition.


## Defines the rules as to how a coordinate in space translates into a partition ID.
func make_partition_id(canvas_coord:Vector2) -> Vector2i:
	var id : Vector2i
	id.x = roundi(canvas_coord.x / partition_size)
	id.y = roundi(canvas_coord.y / partition_size)
	return id

#region Managing Objects

## Register object as belonging to the Canvas.[br]
## The Object can be anything, like inner class instances, a dictionary with
## parameters for custom drawing, or a Godot Node. How it is displayed depends on
## how you override [code]draw_geometry()[/code] and [code]_get_obj_rect()[/code]
## to interpret the object's data.[br]
## [b]NOTE: [/b][u]If the obj has the same data as an existing one, their hashes,
## thus index in the partition keys will be the same, leading to overwriting, so
## you should add some "unique id" or "hash" property to such objects.[/u][br]
## You may choose to select to use your own partition by setting
## [code]parti_name[/code].[br]
## [code]parti_name[/code] is the variable name for a Dictionary[Vector2i, Array],
## which name ends in "_parti". After adding an object, you might want to change
## parameters on it like [code]snap[/code] or [code]centered[/code], so the
## dictionary of all data on the object is returned.[br]
## Finally, a method [code]_parti_registered[/code] is called if it exists in
## the object.
## [b]NOTE: [/b][u]This function doesn't set an object's position in space, like
## if they have a [code]position[/code] property or [code]set_position()[/code]
## method. That as to be explicitly defined after calling this function. for objects
## that have positional constraints, call [code]update_object()[/code] to get
## the computed position as [code]data.alt_position[/code].[/u]
func add_object(obj, canvas_pos:Vector2, parti_name:StringName="_") -> Dictionary:
	var id: Vector2i = make_partition_id(canvas_pos)
	var parti : Dictionary = get(parti_name + "_parti")
	if not id in parti:
		parti[id] = []
	parti[id].append(obj)
	obj_intel[obj] = {"parti_name": parti_name, "parti_id": id, "registry_acknowledged":false, "position": canvas_pos, "snap": false, "centered": false}
	if obj is Node:
		_nodes.add_child(obj)
		obj.owner = self
	if typeof(obj) == TYPE_OBJECT and obj.has_method("_parti_registered"):
		obj._parti_registered(obj_intel[obj])
		
	return obj_intel[obj]

## Unregister object from belonging to the Canvas. If it's a Node, it will be
## removed from the scene tree. Use [code]queue_free()[/code] separatedly.[br]
## It returns the data stored about that object. It will also call a
## [code]_parti_unregistered()[/code] method in the object if it exists, along with
## its data as argument.
func remove_object(obj) -> Dictionary:
	var data = obj_intel[obj]
	var parti : Dictionary = get(data.parti_name + "_parti")
	
	_selected.erase(obj)
	obj_intel.erase(obj)
	
	parti[data.parti_id].erase(obj)
	if parti[data.parti_id].is_empty():
		parti.erase(data.parti_id)
	
	if obj is Node:
		_nodes.remove_child(obj)
		
	if typeof(obj) == TYPE_OBJECT and obj.has_method("_parti_unregistered"):
		obj._parti_removed(obj_intel[obj])
	
	return data

## Change partition details of an object, given position data has changed.[br]
## It also updates [code]alt_position[/code] from the [code]obj_intel[obj][/code]
## dictionary. That can then be used to place an object in the correct visual
## position, rather than nominal [code]position[/code] which doesn't account
## constraint options[br]
## You should edit the objects data, specifically the "position", from the dictionary
## [code]obj_intel[obj][/code] before calling this function for it to take effect.[br]
## Optionally You may also switch its partition if [code]new_partition[/code] is
## Provided. To place the object in the default partition use "_".[br]
## If the object includes a [code]_parti_moved()[/code] method, it will be called
## with its data as argument.[br]
## The data is returned, in case you need it to get computed positions.
func update_object(obj, new_partition="") -> Dictionary:
	var data : Dictionary = obj_intel[obj]
	if not data.is_empty():
		
		# Update position as constrained by options.
		var pos : Vector2 = data.position
		if data.get("snap", false):
			pos = pos - Vector2(0.5, 0.5) * snap_val
			pos = pos.snappedf(snap_val)
		if data.get("centered", false):
			pos += get_obj_rect(obj).size / 2
		data["alt_position"] = pos
	
		# Find if we changed partition, whether by ID or the partition name.
		var new_id = make_partition_id(data.position)
		if data.parti_id == new_id:  # If ID doesn't change
			if new_partition.is_empty() or new_partition == data.parti_name:  # If we are staying in the same partition.
				return data  # No need to update

		var parti : Dictionary = get(data.parti_name + "_parti")
		
		# Remove obsolete entry
		parti[data.parti_id].erase(obj)
		if parti[data.parti_id].is_empty():
			parti.erase(data.parti_id)
		# Add updated entry
		data.parti_id = new_id
		if not new_partition.is_empty():
			parti = get(new_partition + "_parti")
		if not new_id in parti:
			parti[new_id] = []
		parti[new_id].append(obj)
		
		if typeof(obj) == TYPE_OBJECT and obj.has_method("_parti_moved"):
			obj._parti_changed(obj_intel[obj])
		
	return data


## Performs a [code]remove_object()[/code] to all objects at given ID,
## eventually removing the partition with that ID.
func remove_at_parti_ids(ids:Array, parti_name:StringName="_") -> void:
	var parti : Dictionary = get(parti_name + "_parti")
	for id in ids:
		for each in parti.get(id, []):
			if not each.is_empty():
				remove_object(each)

## Performs [code]remove_object()[/code] to all objects of a partition.
func clear_parti(parti_name="_") -> void:
	var parti : Dictionary = get(parti_name + "_parti")
	for id in parti:
		if parti[id].is_empty():
			parti.erase(id)
		for obj in parti[id]:
			remove_object(obj)

#endregion

#region Get Object Information

## Helper function to get all the data stored by the partition on an object.
func get_obj_data(obj) -> Dictionary:
	return obj_intel.get(obj, {})

## Helper function to find which partition Dictionary ([code]parti_name[/code]) is found in.
func get_obj_parti_name(obj) -> String:
	var data = get_obj_data(obj)
	return data.get("parti_name", "_")

## Helper function that returns the partition ID ([code]parti_id[/code]) of the partition the object is found at.
func get_obj_parti_id(obj) -> Vector2i:
	var data = get_obj_data(obj)
	return data.get("parti_id") #NOTE This is meant raise an error if `parti_id`is not found.

## Return a Rect2 for object, enabling a way to tell if an object still counts as within selection, even if it's origin coordinate would be excluded.
func get_obj_rect(obj) -> Rect2:
	var data : Dictionary = get_obj_data(obj)
	if not data.is_empty():
		return _get_obj_rect(obj, data)
	else:
		return Rect2(data.position, Vector2.ONE)

#endregion

#region Find Objects

## find objects of a single partition.
func find_objects_partition(canvas_coord:Vector2, parti_name:StringName="_") -> Array:
	var id : Vector2i = make_partition_id(canvas_coord)
	var parti : Dictionary[Vector2i, Array] = get(parti_name + "_parti")
	return parti.get(id, [])

## Finds if there's an object at the given coordinate, accounting its size, and
## returns it if found.[br]
## This function has the possibility of false negative, for objects which Rect2
## crosses partition borders.[br]
## For example the coordinate of a click on the object, but its origin coordinate
## is in a different partition from the partition at the click.[br]
## Larger [code]partition_size[/code] values make this less probable. If searching
## an object within the viewable area, prefer using
## [code]find_object_at_visible()[/code].
func find_object_at(canvas_coord: Vector2, parti_name:StringName="_") -> Variant:
	var candidates : Array = find_objects_partition(canvas_coord, parti_name)
	for each in candidates:
		var each_rect = get_obj_rect(each)
		if each_rect.has_point(canvas_coord):
			return each
	return null

## Similar to [code]find_object_at()[/code], but it searches all partitions within
## the visible area, not just the single partition enclosing the given coordinate.
func find_object_at_visible(canvas_coord: Vector2, parti_name:StringName="_") -> Variant:
	var candidates : Array = find_objects(to_canvas_rect(get_rect()), parti_name)
	for each in candidates:
		var each_rect = get_obj_rect(each)
		if each_rect.has_point(canvas_coord):
			return each
	return null

## Return all objects that are within the partitions intersected by the given rectangle.
## It is biased to give false positives (includes objects that aren't in the 
## selection area), rather than false negatives (exclude objects that are in the
## selection area). Other functions will provide ways to further filter the results.[br]
## You may choose to select from your own partition by setting
## [code]parti_name[/code].[br]
## [code]parti_name[/code] is the variable name for a Dictionary[Vector2i, Array],
## which name ends in "_parti".
func find_objects(canvas_rect:Rect2, parti_name:StringName="_") -> Array:
	canvas_rect = canvas_rect.abs()
	var objs : Array[Variant] = []
	var parti : Dictionary[Vector2i, Array] = get(parti_name + "_parti")
	var start : Vector2i = make_partition_id(canvas_rect.position)
	var stop : Vector2i = make_partition_id(canvas_rect.end)
	#NOTE We add or subtract `partition_size` to grow selection area which avoids false negatives. False positives are handled by wrapper functions.
	start -= Vector2i.ONE
	stop += Vector2i.ONE
	for x : int in range(start.x, stop.x):
		for y : int in range(start.y, stop.y):
			objs += parti.get(Vector2i(x, y), [])
	return objs

## A wrapper for searching objects. Returns those which origin coordinate is within [code]canvas_rect[/code], rather than their Rect2, so doesn't account size.
func find_objects_simple(canvas_rect:Rect2, parti_name:StringName="_") -> Array:
	var objs : Array[Variant] = []
	for obj in find_objects(canvas_rect, parti_name):
		if canvas_rect.has_point(obj_intel[obj].position):
			objs.append(obj)
	return objs

## A wrapper for searching objects which checks to only include those which Rect2 intersects [code]canvas_rect[/code].
func find_objects_tolerant(canvas_rect:Rect2, parti_name:StringName="_") -> Array:
	var objs : Array[Variant] = []
	for obj in find_objects(canvas_rect, parti_name):
		if canvas_rect.intersects(get_obj_rect(obj), true):
			objs.append(obj)
	return objs

## A wrapper for searching objects while only counting them in if their Rect2 is enclosed by [code]canvas_rect[/code].
func find_objects_zealous(canvas_rect:Rect2, parti_name:StringName="_") -> Array:
	var objs : Array[Variant] = []
	for obj in find_objects(canvas_rect, parti_name):
		if canvas_rect.encloses(get_obj_rect(obj)):
			objs.append(obj)
	return objs
#endregion

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

@warning_ignore("unused_parameter")
func draw_back_geometry(viewed_canvas_rect:Rect2):
	pass
@warning_ignore("unused_parameter")
func draw_fore_geometry(viewed_canvas_rect:Rect2):
	pass

## Override this function with the appropriate calculation of the Rect for the particular type of objects you are placing on the canvas.
## By default, it tries to find a [code]get_rect()[/code] function and if it can't, it assumes a unit-sized entity at the same position as the coordinate.
func _get_obj_rect(obj, data:={}) -> Rect2:
	if typeof(obj) == TYPE_OBJECT and obj.has_method("get_rect"):
		return obj.get_rect()
	return Rect2(data.position, Vector2.ONE)
#endregion
