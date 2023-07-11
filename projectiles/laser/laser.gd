extends StaticBody3D

@onready var beam = $beam

const SPEED = 70
const RANGE = 30
const PHYSICAL_DAMAGE = 0
const ENERGY_DAMAGE = 2

var origin

func aim(target):
    look_at(target)
    origin = position

func _physics_process(delta):
    var collision = move_and_collide(-transform.basis.z * SPEED * delta)
    if collision:
        if collision.get_collider().has_method("handle_bullet"):
            collision.get_collider().handle_bullet(ENERGY_DAMAGE, PHYSICAL_DAMAGE)
        queue_free()
    elif (position - origin).length() >= RANGE:
        queue_free()
