For Paracortical Initiative, 2025, Diogo "Theklo" Duarte

Other projects:
- [Bluesky for news on any progress I've done](https://bsky.app/profile/diogo-duarte.bsky.social)
- [Itchi.io for my most stable playable projects](https://diogo-duarte.itch.io/)
- [The Github for source codes and portfolio](https://github.com/Theklo-Teal)
- [Ko-fi is where I'll accept donations](https://ko-fi.com/paracortical)

![A screenshot of the example scene extending the node.](InfiCanvas_Demo.png)

# DESCRIPTION
This is an area which works as window to an infinite plane where various objects can be added. Spatial Hash Partitioning is used to decide which objects to display and box selection, enabling very high performance with thousands of objects. These objects can be pretty much anything you can hold in a GDScript variable, by overriding functions to handle them. Override functions also allow to change style, background patterns, what to do with selection boxes and other things.
The canvas can be panned with the middle mouse button and zoomed with the scroll wheel. Panning too far from the origin displays a compass.
The box selection can have two modes, like is typical in CAD programs.
Everything is highly extensible and costumizeable.

# INSTALLATION
This isn't technically a Godot Plugin, it doesn't use the special Plugin features of the Editor, so don't put it inside the "plugin" folder. The folder of the tool can be anywhere else you want, though, but I suggest having it in a "modules" folder.

After that, the «class_name InfiCanvas» registers the node so you can add it to a project like you add any Godot node.
An example scene that extends this node with a minimap, drawing of circles on the canvas and different style is provided.

# USAGE
The general style options like thickness of lines and colors can be set in the inspector. Being an extension of ColorRect, the background color of this node is set in the same way.
Partition size tells the resolution of object finding algorithm. Bigger partitions make search faster, but find more unintended objects.
After first search, the returned objects may be calculated with brute force that discards false positives and false negatives.
On this second search, the size of the objects is accounted to determinate what to discard. The greedy version of search algorithm rejects objects not completely enclosed by selection area. The lazy version includes anything overlapping the selection area.

# FUTURE IMPROVEMENTS
- Shaders instead of custom drawing could improve performance.
- A binary tree and a quadtree algorithm could further improve performance and search speed.
- More selection options, like polygonal lasso, maybe?
