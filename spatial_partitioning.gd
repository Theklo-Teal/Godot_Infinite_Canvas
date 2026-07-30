extends Resource
class_name SpatialPartition

## An hybrid of Spatial Hash Partitioning with Quadtrees for refining search. With this, you can have many objects in a 2D space and be able to search them or select them very quickly. [br]
## Having separate partition resource instances allows different kinds of objects to be discriminated, or even partition them by different paramenters, if they operate at very different scales.[br]
## Various kinds of objects can be stored in the partitions, as long as they contain a [code]get_rect()[/code] method, [code]rect[/code] key or property, or [code]position[/code] as key or property, from a Dictionary, through inner class and RefCount instances, to Godot Nodes.[br]
## Each one of the methods or properties is tried in that order.[br]
## Quadtree root cells have a maximum size, and they are considered the cells of hash partitioning method.
## These roots have an ID which is calculated according to the area of space they enclosure. Object within this area are associated with this ID.
## Depending on whether objects exist within them or are moved, they are created or deleted as appropriate.[br]
## We first search objects by the ID of the desired area. When multiple objects are within this root partition, subdivisions of the quadtree allow for more granular search.

#TODO setters to make sure min_size is less than half of root_size.

@export_range(50, 5000, 1, "or_greater") var root_size : int = 1000 :  ## Size of each basic partition. Also the biggest cell size for quadtree methods. Bigger number makes searching objects in the canvas faster, but less accurate. Typically you want partitions to be larger (bounding box Rect2.size) than most objects placed on them, or there will be false negatives with some functions.
	set(val):
		root_size = val
		min_size = mini(min_size, floori(root_size / 2.0) )
@export_range(5, 1000, 1, "or_greater") var min_size : int = 50 :  ## Size of the smallest subdivision of a partition for quadtree methods.
	set(val):
		min_size = mini(val, floori(root_size / 2.0))
@export_range(1, 100, 1, "or_greater") var max_obj : int = 5  ## Maximum number of objects within each quadtree cell. If more are found, it subdivides into smaller cells.

var obj_intel : Dictionary[Variant, Dictionary]  ## Back index for [code]partition[/code]. The dictionary includes the index "parti_id", the "parti_name", as well as information in common with all objects like constraints.
var partition : Dictionary[Vector2i, Array]  ## [root_partition_id][idx] -> object_instance; Index of objects at each root partition.
var quadtrees : Dictionary[Vector2i, QuadTree]  ## [root_partition_id] -> QuadTree

class QuadTree:
	var rect : Rect2
	var cells : Array[QuadTree]
	var _min_size : int = 50
	var _max_objs : int = 5
	
	func _init(area : Rect2, min_size:int = 50, max_objs:int = 5):
		rect = area.abs()
		_min_size = max(5, min_size)
		_max_objs = max(1, max_objs)
	
	## A list of object positions can be supplied to tell whether to subdivide further.
	func subdivide(objects:Array[Vector2]=[]) -> void:
		cells.clear()
		if rect.size.x < _min_size:
			return
		for i in range(4):
			var new_size : float = rect.size.x / 2.0
			var new_pos : Vector2 = rect.position
			new_pos.x += (i & 1) * new_size
			new_pos.y += ((i & 2) >> 1) * new_size
			cells.append(QuadTree.new(
				Rect2(
					new_pos,
					Vector2.ONE * new_size
				), _min_size, _max_objs))
			var sub_set_objs : Array[Vector2] = cells[i].select_points(objects)
			if sub_set_objs.size() > _max_objs:
				cells[i].subdivide(sub_set_objs)
	
	## Returns the points that fit in this partition, from a set. Can be useful to count how many of the points are inside a partion.
	func select_points(points : Array[Vector2]) -> Array[Vector2]:
		var ans : Array[Vector2] = []
		for point in points:
			if rect.has_point(point):
				ans.append(point)
		return ans
	
	## Returns the smallest quadtree cell containing a point. Returns null if the point isn't in the quadtree.
	func search_point(point:Vector2):
		if rect.has_point(point):
			if cells.is_empty():
				return self
			for i in range(4):
				return cells[i].search_point(point)
	
	## Returns all partitions (at the bottom of the tree, not their parents) that are fully enclosed by an area.
	func search_area_enclose(area:Rect2, finds:Array[QuadTree]=[]) -> Array[QuadTree]:
		if cells.is_empty() and area.encloses(rect):
			finds.append(self)
		else:
			for i in range(4):
				cells[i].search_area_enclose(area, finds)
		return finds
	
	## Returns all the partitions (at the bottom of the tree, not their parents) that intersect an area, even if not fully enclosing it.
	func search_area_intersect(area:Rect2, finds:Array[QuadTree]=[]) -> Array[QuadTree]:
		if cells.is_empty() and area.intersects(rect, true):
			finds.append(self)
		else:
			for i in range(4):
				cells[i].search_area_intersect(area, finds)
		return finds
	
	## Returns the bottom-most partition containing an object. Returns null if not found. Usually, the position is the top-left corner of an object's rect. [code]use_center[/code] can be provided to use the center of the object's Rect, instead of top-left corner. If the object doesn't have a [code]get_rect()[/code] method, then a [code]position[/code] property is used.
	func search_object(obj, use_center:bool=false) -> QuadTree:
		var point : Vector2
		if typeof(obj) == TYPE_OBJECT and obj.has_method("get_rect"):
			if use_center:
				point = obj.get_rect().get_center()
			else:
				point = obj.get_rect().position
		elif "rect" in obj:
			if use_center:
				point = obj.rect.get_center()
			else:
				point = obj.rect.position
		else:
			point = obj.position
		return search_point(point)
	
	## Finds if a point is near an edge or a corner of this quadtree, within given margin.[br]
	## Returns the the overlapping [code]side[/code] or [code]corner[/code], if two sides overlap, as well as the smallest [code]quadtree[/code] containing that point.[br]
	## See more at [code]@GlobalScope.Side[/code] and [code]@GlobalScope.Corner[/code].
	func point_near_border(point:Vector2, margin:float = 1.0) -> Dictionary:
		var ans : Dictionary[String, Variant] = {
			"quadtree": self,
			"sub_side": -1,
			"sub_corner": -1,
			"side": -1,
			"corner": -1,
		}
		var closest : float = INF
		ans.quadtree = search_point(point)
		for i in range(4):
			var can_break : bool = false  # Skip checking further sides when we already found an answer.
			var axis = i & 1
			var dir = (i & 1) >> 1
			var dist = point[axis] - [ans.quadtree.rect.end[axis], ans.quadtree.rect.position[axis]][dir]
			if abs(dist) < margin:
				if ans.sub_side < 0:
					closest = abs(dist)
					ans.sub_side = i as Side
				else:
					#NOTE "-1" are invalid combinations of edges that don't produce a corner.
					ans.sub_corner = [-1, CORNER_BOTTOM_RIGHT, -1, CORNER_TOP_RIGHT, CORNER_BOTTOM_RIGHT, -1, CORNER_BOTTOM_LEFT, -1, -1, CORNER_BOTTOM_LEFT, -1, CORNER_TOP_RIGHT, CORNER_TOP_LEFT, -1, CORNER_TOP_RIGHT, -1][ans.sub_side | i << 2]
					if closest > abs(dist):
						ans.sub_side = i as Side
					can_break = true
			dist = point[axis] - [rect.end[axis], rect.position[axis]][dir]
			if abs(dist) < margin:
				if ans.side < 0:
					closest = abs(dist)
					ans.side = i as Side
				else:
					#NOTE "-1" are invalid combinations of edges that don't produce a corner.
					ans.corner = [-1, CORNER_BOTTOM_RIGHT, -1, CORNER_TOP_RIGHT, CORNER_BOTTOM_RIGHT, -1, CORNER_BOTTOM_LEFT, -1, -1, CORNER_BOTTOM_LEFT, -1, CORNER_TOP_RIGHT, CORNER_TOP_LEFT, -1, CORNER_TOP_RIGHT, -1][ans.side | i << 2]
					if closest > abs(dist):
						ans.side = i as Side
					if can_break:
						break
		return ans


## Defines the rules as to how a coordinate in space translates into a root partition ID.
func make_partition_id(coord:Vector2) -> Vector2i:
	var id : Vector2i
	id.x = roundi(coord.x / root_size)
	id.y = roundi(coord.y / root_size)
	return id

#TODO How could this be extended for custom rects?
## Return a Rect2 for object, enabling a way to tell if an object still counts as within selection, even if it's origin coordinate would be excluded.
func get_obj_rect(obj) -> Rect2:
		if typeof(obj) == TYPE_OBJECT and obj.has_method("get_rect"):
			return obj.get_rect()
		elif "rect" in obj:
			return obj.rect
		else:
			return Rect2(get_obj_position(obj), Vector2.ONE)

func get_obj_position(obj) -> Vector2:
	if typeof(obj) == TYPE_OBJECT and obj.has_method("get_position"):
		return obj.get_position()
	elif "position" in obj:
		return obj.position
	else:
		return Vector2.ZERO

#region Managing Objects
## Register object in a partition.[br] 
## [b]NOTE: [/b][u]If the obj has the same data as an existing one, their hashes,
## thus index in the partition keys will be the same, leading to overwriting, so
## you should add some "unique id" or "hash" property to such objects.[/u][br]
## Afterwards, you may want change parameters on it like [code]centered[/code], so the
## dictionary of all data on the object is returned.[br]
## [b]NOTE: [/b][u]This function doesn't set the position of the object, it just trusts the given position is true.
## Positioning of the object is done independently.[br]
## Finally, a method [code]_parti_registered[/code] is called if it exists in
## the object. [code]registry_acknowledged[/code] in the data argument can be set [code]true[/code]
## To mark that method to have been executed.
func add_object(obj, pos:Vector2) -> Dictionary:
	var id: Vector2i = make_partition_id(pos)
	var parti = partition.get_or_add(id, [])
	parti.append(obj)
	obj_intel[obj] = {"parti_id": id, "registry_acknowledged":false, "centered": false}
	
	var obj_pos : Array[Vector2]
	for each in parti:
		if obj_intel[each].centered:
			obj_pos.append(get_obj_rect(each).get_center())
		else:
			obj_pos.append(get_obj_rect(each).position)
	
	var quad : QuadTree = quadtrees.get_or_add( id, QuadTree.new(Rect2(id, Vector2.ONE * root_size), min_size, max_obj) )
	quad.subdivide(obj_pos)
	
	if typeof(obj) == TYPE_OBJECT and obj.has_method("_parti_registered"):
		obj._parti_registered(self, obj_intel[obj])
		
	return obj_intel[obj]


## Unregister object from any partition. If it's a Node,
## use [code]queue_free()[/code] separatedly.[br]
## It returns the data stored about that object. It will also call a
## [code]_parti_unregistered()[/code] method in the object if it exists, along with
## its data as argument.
func remove_object(obj) -> Dictionary:
	var data = obj_intel[obj]
	
	obj_intel.erase(obj)
	partition[data.parti_id].erase(obj)
	if partition[data.parti_id].is_empty():
		partition.erase(data.parti_id)
		quadtrees.erase(data.parti_id)
		
	if typeof(obj) == TYPE_OBJECT and obj.has_method("_parti_unregistered"):
		obj._parti_removed(obj_intel[obj])
	
	return data


## After the object's position is changed, call this method to update its partition.[br]
## If the object includes a [code]_parti_updated()[/code] method, it will be called
## with its data as argument.[br]
## The data is returned, in case you need it to get computed positions.
func update_object(obj) -> Dictionary:
	var data : Dictionary = obj_intel[obj]
	
	var obj_pos : Vector2
	if typeof(obj) == TYPE_OBJECT and obj.has_method("get_rect"):
		if data.centered:
			obj_pos = obj.get_rect().get_center()
		else:
			obj_pos = obj.get_rect().position
	elif "rect" in obj:
		if data.centered:
			obj_pos = obj.rect.get_center()
		else:
			obj_pos = obj.rect.position
	else:
		obj_pos = obj.position
	
	# Find if we changed partition, whether by ID or the partition name.
	var new_id = make_partition_id(obj_pos)
	if data.parti_id != new_id:  # If ID has changed!
		# Remove from former partition
		partition[data.parti_id].erase(obj)
		if partition[data.parti_id].is_empty():
			partition.erase(data.parti_id)
			quadtrees.erase(data.parti_id)
		
		# Add to new partition.
		var parti = partition.get_or_add(new_id, [])
		parti.append(obj)
		
		var objs_pos : Array[Vector2]
		for each in parti:
			if obj_intel[each].centered:
				objs_pos.append(get_obj_rect(each).get_center())
			else:
				objs_pos.append(get_obj_rect(each).position)
			
		var quad = quadtrees.get_or_add( new_id, QuadTree.new(Rect2(new_id, Vector2.ONE * root_size), min_size, max_obj) )
		quad.subdivide(objs_pos)
	
		data.parti_id = new_id
		if typeof(obj) == TYPE_OBJECT and obj.has_method("_parti_updated"):
			obj._parti_updated(data)
	return data
#endregion

#region Searching Objects

## find objects of a single partition.
func find_partition_objects(coord:Vector2) -> Array:
	var id : Vector2i = make_partition_id(coord)
	return partition.get(id, [])

## Finds if there's an object at the given coordinate, accounting its size, and
## returns it if found.[br]
## This function has the possibility of false negative, for objects which Rect2
## crosses partition borders.[br]
## For example the coordinate of a click on the object, but its origin coordinate
## is in a different partition from the partition at the click.[br]
## Larger [code]root_size[/code] values make this less probable.
func find_object_at(coord: Vector2) -> Variant:
	var candidates : Array = find_partition_objects(coord)
	for each in candidates:
		var each_rect = get_obj_rect(each)
		if each_rect.has_point(coord):
			return each
	return null

## Return all objects that are within the partitions intersected by the given rectangle.
## It is biased to give false positives (includes objects that aren't in the 
## selection area), rather than false negatives (exclude objects that are in the
## selection area). Other functions will provide ways to further filter the results.[br]
func find_objects(rect:Rect2) -> Array:
	rect = rect.abs()
	var objs : Array[Variant] = []
	var start : Vector2i = make_partition_id(rect.position)
	var stop : Vector2i = make_partition_id(rect.end)
	#NOTE We add or subtract `partition_size` to grow selection area which avoids false negatives. False positives are handled by wrapper functions.
	start -= Vector2i.ONE
	stop += Vector2i.ONE
	for x : int in range(start.x, stop.x):
		for y : int in range(start.y, stop.y):
			objs += partition.get(Vector2i(x, y), [])
	return objs

## A wrapper for searching objects. Returns those which origin coordinate is within [code]rect[/code], rather than their Rect2, so doesn't account size.
func find_objects_simple(rect:Rect2) -> Array:
	var objs : Array[Variant] = []
	for obj in find_objects(rect):
		if rect.has_point(get_obj_position(obj)):
			objs.append(obj)
	return objs

## A wrapper for searching objects which checks to include those which Rect2 intersects [code]rect[/code].
func find_objects_tolerant(rect:Rect2) -> Array:
	var objs : Array[Variant] = []
	for obj in find_objects(rect):
		if rect.intersects(get_obj_rect(obj), true):
			objs.append(obj)
	return objs

## A wrapper for searching objects while only counting them in if their Rect2 is enclosed by [code]rect[/code].
func find_objects_zealous(rect:Rect2) -> Array:
	var objs : Array[Variant] = []
	for obj in find_objects(rect):
		if rect.encloses(get_obj_rect(obj)):
			objs.append(obj)
	return objs
#endregion


#region Helper Functions
## Helper function to get all the data stored by the partition on an object.
func get_obj_data(obj) -> Dictionary:
	return obj_intel.get(obj, {})

## Helper function that returns the partition ID ([code]parti_id[/code]) of the partition the object is found at.
func get_obj_parti_id(obj) -> Vector2i:
	var data = get_obj_data(obj)
	return data.parti_id

## Performs a [code]remove_object()[/code] to all objects at given ID,
## eventually removing the partition with that ID.
func remove_at_parti_ids(ids:Array[Vector2i]) -> void:
	for id in ids:
		for each in partition.get(id, []):
			if not each.is_empty():
				remove_object(each)

## Performs a [code]remove_object()[/code] to all given objects,
## Deleting partitions if appropriate.
func remove_objects(objs:Array) -> void:
	for obj in objs:
		remove_object(obj)
#endregion
