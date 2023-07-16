extends StaticBody3D

@onready var bullet_puff_scene = preload("res://projectiles/laser/bullet_puff.tscn")

@onready var beam = $beam

const SPEED = 70 * 2
const RANGE = 100
const DAMAGE = 2

var origin

func aim(target):
    look_at(target)
    origin = position

func _physics_process(delta):
    var collision = move_and_collide(-transform.basis.z * SPEED * delta)
    if collision:
        if collision.get_collider().has_method("handle_bullet"):
            collision.get_collider().handle_bullet(DAMAGE)
        var bullet_puff = bullet_puff_scene.instantiate()
        get_parent().add_child(bullet_puff)
        bullet_puff.position = global_transform.origin
        queue_free()
    elif (position - origin).length() >= RANGE:
        queue_free()
