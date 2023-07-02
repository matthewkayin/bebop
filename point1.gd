extends StaticBody3D

var origin_pos
var state = 0
var target_pos = null
var velocity = Vector3.ZERO
var collision_radius = 0.5

func _ready():
    origin_pos = position
    add_to_group("obstacles")

func _process(delta):
    if get_node_or_null("../point2") == null:
        return
    if target_pos == null: 
        if state == 0:
            target_pos = get_node("../point2").position
        elif state == 1:
            target_pos = origin_pos
        state = (state + 1) % 2

    if position.distance_to(target_pos) <= 1:
        target_pos = null
        velocity = Vector3.ZERO
    else:
        velocity = position.direction_to(target_pos) * 7

    position += velocity * delta
