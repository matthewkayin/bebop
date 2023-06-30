extends CharacterBody3D

@onready var mesh = $mesh
@onready var boost_timer = $boost_timer
@onready var yaw_roll_timer = $yaw_roll_timer
@onready var targeting_ray = $mesh/targeting_ray
@onready var target_selection_ray = $mesh/target_selection_ray
@onready var laser_mount = $mesh/laser_mount
@onready var laser_mount2 = $mesh/laser_mount2
@onready var laser_timer = $laser_timer

@onready var laser_scene = preload("res://projectiles/laser/laser.tscn")

const TERMINAL_VELOCITY = 10
const MAX_THROTTLE_VELOCITY = 7
const MAX_ROTATION_SPEED = Vector3(1.4, 0.8, 0.6)
const ACCELERATION = Vector3(2.5, 2.5, 2.5)

var target_position = null

var rotation_input = Vector3(0, 0, 0)
var rotation_speed = Vector3(0, 0, 0)

var throttle = 0
var thrust_input = Vector3.ZERO

var has_boost = true
var boost_impulse = Vector3.ZERO
var collision_impulse = Vector3.ZERO
var drifting = false

var weapons_target
var weapon_alternator = 0
var target = null

func _ready():
    targeting_ray.add_exception(self)
    target_selection_ray.add_exception(self)
    laser_timer.timeout.connect(laser_timer_timeout)

func pathfind():
    if target_position == null:
        throttle = 0
        return
    if position.distance_to(target_position) <= 1:
        throttle = 0
        return

    var pt = (target_position - position).normalized()
    var py1 = Vector2((-mesh.transform.basis.z).x, (-mesh.transform.basis.z).z)
    var py2 = Vector2(pt.x, pt.z)
    var px1 = Vector2((-mesh.transform.basis.z).x, (-mesh.transform.basis.z).y)
    var px2 = Vector2(pt.x, pt.y)
    var yaw_angle = rad_to_deg(py2.angle_to(py1))
    var pitch_angle = rad_to_deg(px1.angle_to(px2))
    rotation_input = Vector3.ZERO
    var threshold = 5
    if yaw_angle > threshold:
        rotation_input.x = 1
    elif yaw_angle < -threshold:
        rotation_input.x = -1
    if pitch_angle > threshold:
        rotation_input.y = 1
    elif pitch_angle < -threshold:
        rotation_input.y = -1

func _physics_process(delta):
    if target_position == null:
        var point = get_node_or_null("../point1")
        if point != null:
            target_position = point.position

    pathfind()

    # flight assist rotation correction
    if not drifting:
        for i in range(0, 3):
            if rotation_speed[i] > 0:
                rotation_speed[i] -= 0.02
            elif rotation_speed[i] < 0:
                rotation_speed[i] += 0.02

    rotation_speed += rotation_input
    var speed_percent = 1 - abs((velocity.length() / TERMINAL_VELOCITY) - 0.45)
    if boost_impulse != Vector3.ZERO or drifting:
        speed_percent = 1
    for i in range(0, 3):
        rotation_speed[i] = clamp(rotation_speed[i], -MAX_ROTATION_SPEED[i] * speed_percent, MAX_ROTATION_SPEED[i] * speed_percent)

    # Perform flight rotation
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.z, rotation_speed.x * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.x, rotation_speed.y * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.y, rotation_speed.z * delta)
    mesh.transform.basis = mesh.transform.basis.orthonormalized()

    # acceleration and decceleration
    var acceleration = Vector3.ZERO
    for i in range(0, 3):
        acceleration += mesh.transform.basis[i] * thrust_input[i] * ACCELERATION[i]

    var decceleration = Vector3.ZERO
    if not drifting:
        for i in range(0, 3):
            var velocity_component_in_basis_direction = mesh.transform.basis[i] * (velocity.dot(mesh.transform.basis[i]) / mesh.transform.basis[i].length())
            if not drifting and i == 2 and throttle != 0:
                if velocity_component_in_basis_direction.normalized() == mesh.transform.basis[i]:
                    acceleration += -mesh.transform.basis[i] * ACCELERATION[i]
                elif velocity_component_in_basis_direction.normalized() == -mesh.transform.basis[i] and velocity_component_in_basis_direction.length() > (MAX_THROTTLE_VELOCITY * throttle) + 5:
                    decceleration += mesh.transform.basis[i] * ACCELERATION[i]
                elif velocity_component_in_basis_direction.length() < MAX_THROTTLE_VELOCITY * throttle:
                    acceleration += -mesh.transform.basis[i] * ACCELERATION[i]
            elif thrust_input[i] == 0 and velocity_component_in_basis_direction.length() >= ACCELERATION[i] * delta: 
                decceleration += -velocity_component_in_basis_direction.normalized() * ACCELERATION[i]
    if boost_impulse != Vector3.ZERO:
        velocity += boost_impulse * delta
    else:
        velocity += (acceleration + decceleration + collision_impulse) * delta

    # velocity
    velocity = velocity.limit_length(TERMINAL_VELOCITY)
    if thrust_input == Vector3.ZERO and (throttle == 0 and not drifting) and velocity.length() <= 0.1:
        velocity = Vector3.ZERO

    # move and handle collisions
    var collision = move_and_collide(velocity * delta)
    collision_impulse = Vector3.ZERO
    if collision:
        collision_impulse = collision.get_normal() * velocity.length() * 100
        rotation_speed[0] = collision.get_normal().signed_angle_to(velocity, Vector3.FORWARD)
        rotation_speed[1] = collision.get_normal().signed_angle_to(velocity, Vector3.UP)
        rotation_speed[2] = collision.get_normal().signed_angle_to(velocity, Vector3.RIGHT)
        rotation_speed *= 5

    weapons_target = $mesh/target.to_global($mesh/target.position)
    if target != null and position.distance_to(target.position) >= 5:
        weapons_target = target.position + (target.velocity * (position.distance_to(target.position) / 50))
    targeting_ray.look_at(weapons_target)
    targeting_ray.force_raycast_update()
    if targeting_ray.is_colliding():
        weapons_target = targeting_ray.get_collision_point()

func boost():
    has_boost = false
    var tween = get_tree().create_tween()
    tween.tween_property(self, "velocity", -mesh.transform.basis.z * velocity.length(), 0.3)
    await tween.finished
    boost_impulse = -mesh.transform.basis.z * 30
    boost_timer.start(1)
    await boost_timer.timeout
    boost_impulse = Vector3.ZERO
    boost_timer.start(10)
    await boost_timer.timeout
    has_boost = true

func laser_timer_timeout():
    pass

func shoot():
    var bullet = laser_scene.instantiate()
    get_parent().add_child(bullet)
    if weapon_alternator == 0:
        bullet.position = laser_mount.global_position
        weapon_alternator = 1
    else:
        bullet.position = laser_mount2.global_position
        weapon_alternator = 0
    bullet.add_collision_exception_with(self)
    bullet.aim(weapons_target)
    laser_timer.start(0.05)
