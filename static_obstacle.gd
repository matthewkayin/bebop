extends StaticBody3D

var collision_radius = 0
var velocity = Vector3.ZERO

func _ready():
    collision_radius = $collider.shape.radius
    add_to_group("obstacles")
