extends StaticBody3D

@export var offset: Vector3

var start: Vector3
var end: Vector3

var moving = false

func _ready():
    start = position
    end = position + offset
    move()

func move():
    moving = true
    var tween = get_tree().create_tween()
    tween.tween_property(self, "position", end, 4.0)
    tween.tween_property(self, "position", start, 4.0)
    await tween.finished
    moving = false

func _process(_delta):
    if not moving:
        move()

func handle_bullet():
    print("hey")
    queue_free()
