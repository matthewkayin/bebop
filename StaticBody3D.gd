extends StaticBody3D

@export var offset: Vector3

var start: Vector3
var end: Vector3
var velocity = Vector3.ZERO
var last_position

var moving = false

func _ready():
    add_to_group("targets")
    last_position = position
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

func _physics_process(delta):
    if not moving:
        move()
    velocity = (position - last_position) / delta
    last_position = position

func handle_bullet():
    queue_free()
