extends StaticBody3D

@onready var beam = $beam

const RANGE = 50
const PHYSICAL_DAMAGE = 30
const ENERGY_DAMAGE = 0

var target
var curve_start
var curve_peak
var curve_end
var t = 0
var velocity

func _ready():
    pass

func aim(at_target, weapons_target, skew):
    target = at_target
    curve_start = position
    if target != null:
        curve_end = target.position
    else:
        curve_end = weapons_target
    curve_peak = curve_start.lerp(curve_end, 0.2) + (skew * 5)

    if target != null and target.has_method("notify_of_incoming_missile"):
        target.notify_of_incoming_missile()

func _process(delta):
    t += delta * (1 + t)

    if t <= 0.9 and target != null:
        curve_end = target.position
    if t <= 1:
        # calcu
        var q0 = curve_start.lerp(curve_peak, t)
        var q1 = curve_peak.lerp(curve_end, t)
        var next_position = q0.lerp(q1, t)
        velocity = next_position - position
        look_at(position + (velocity * 200), transform.basis.y)

    var collision = move_and_collide(velocity)
    if collision:
        if collision.get_collider().has_method("handle_bullet"):
            collision.get_collider().handle_bullet(ENERGY_DAMAGE, PHYSICAL_DAMAGE)
        queue_free()
    elif (position - curve_start).length() >= RANGE:
        queue_free()
