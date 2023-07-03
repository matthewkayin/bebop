extends CharacterBody3D

@onready var mesh = $mesh
@onready var boost_timer = $boost_timer
@onready var yaw_roll_timer = $yaw_roll_timer
@onready var laser_mount = $mesh/laser_mount
@onready var laser_mount2 = $mesh/laser_mount2
@onready var laser_timer = $laser_timer

@onready var laser_scene = preload("res://projectiles/laser/laser.tscn")

const TERMINAL_VELOCITY = 10
const MAX_THROTTLE_VELOCITY = 7
const MAX_ROTATION_SPEED = Vector3(1.4, 0.8, 0.6)
const ACCELERATION = Vector3(2.5, 2.5, 2.5)

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
var number = 0

func _ready():
    laser_timer.timeout.connect(laser_timer_timeout)

func pathfind():
    throttle = 0
    rotation_input = Vector3.ZERO
    thrust_input = Vector3.ZERO

    if target == null:
        return

    var direction = position.direction_to(target.position)
    var collision_eminent = false
    for obstacle in get_tree().get_nodes_in_group("obstacles"):
        if obstacle == self:
            continue
        var relative_velocity = velocity - obstacle.velocity
        var obstacle_direction = position.direction_to(obstacle.position)
        relative_velocity = (obstacle_direction * relative_velocity.dot(obstacle_direction) / obstacle_direction.length())
        var stop_distance = ((relative_velocity.length() * relative_velocity.length()) / ACCELERATION.x) + obstacle.collision_radius
        var collision_distance = position.distance_to(obstacle.position) - obstacle.collision_radius 
        if collision_distance <= stop_distance:
            var collision_angle = rad_to_deg((-mesh.transform.basis.z).angle_to(position.direction_to(obstacle.position)))
            var avoidance_strength = ((1 - (collision_angle / 180)) * 0.5) + ((1 - (collision_distance / stop_distance)) * 0.5)
            if collision_distance / stop_distance >= 0.75:
                collision_eminent = true
            var avoidance = -position.direction_to(obstacle.position) * avoidance_strength * 2
            print(obstacle.name, " / ", avoidance_strength, " / ", collision_angle)
            direction += avoidance
    direction = direction.normalized()

    var direction_xbasis = (mesh.transform.basis.x * direction.dot(mesh.transform.basis.x)) / mesh.transform.basis.x.length()
    var direction_ybasis = (mesh.transform.basis.y * direction.dot(mesh.transform.basis.y)) / mesh.transform.basis.y.length()
    if direction_xbasis.length() > 0.3:
        if direction_xbasis.normalized() == mesh.transform.basis.x:
            rotation_input.x = -1
        elif direction_xbasis.normalized() == -mesh.transform.basis.x:
            rotation_input.x = 1
    elif direction_xbasis.length() > 0.1:
        if direction_xbasis.normalized() == mesh.transform.basis.x:
            rotation_input.z = -1
        elif direction_xbasis.normalized() == -mesh.transform.basis.x:
            rotation_input.z = 1
    if direction_ybasis.length() > 0.2:
        if direction_ybasis.normalized() == mesh.transform.basis.y:
            rotation_input.y = 1
        elif direction_ybasis.normalized() == -mesh.transform.basis.y:
            rotation_input.y = -1

    if direction_xbasis.length() > 0.3 or direction_ybasis.length() > 0.3:
        throttle = 0.45
    else:
        var desired_vf = target.velocity.length()
        var desired_follow_distance = 15
        var time_to_deccel = abs(desired_vf - velocity.length()) / ACCELERATION.x
        var distance_to_deccel = position.distance_to(target.position) - desired_follow_distance - (velocity.length() * time_to_deccel) - (0.5 * ACCELERATION.x * (time_to_deccel * time_to_deccel))
        if distance_to_deccel <= 0:
            throttle = desired_vf / MAX_THROTTLE_VELOCITY
        else:
            throttle = 1

        if collision_eminent or (position.distance_to(target.position) <= desired_follow_distance and velocity.length() > desired_vf):
            thrust_input.z = 1

func _physics_process(delta):
    if target == null:
        target = get_node_or_null("../point1")

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
            var velocity_component_in_basis_direction = (mesh.transform.basis[i] * velocity.dot(mesh.transform.basis[i]) / mesh.transform.basis[i].length())
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
        print("bonk")
        collision_impulse = collision.get_normal() * velocity.length() * 100
        rotation_speed[0] = collision.get_normal().signed_angle_to(velocity, Vector3.FORWARD)
        rotation_speed[1] = collision.get_normal().signed_angle_to(velocity, Vector3.UP)
        rotation_speed[2] = collision.get_normal().signed_angle_to(velocity, Vector3.RIGHT)
        rotation_speed *= 5

    weapons_target = $mesh/target.to_global($mesh/target.position)
    if target != null and position.distance_to(target.position) >= 5:
        weapons_target = target.position + (target.velocity * (position.distance_to(target.position) / 50))
    # targeting_ray.look_at(weapons_target)
    # targeting_ray.force_raycast_update()
    # if targeting_ray.is_colliding():
        # weapons_target = targeting_ray.get_collision_point()

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
