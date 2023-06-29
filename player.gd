extends CharacterBody3D

@onready var mesh = $mesh
@onready var camera_anchor = $camera_anchor
@onready var boost_timer = $boost_timer
@onready var yaw_roll_timer = $yaw_roll_timer
@onready var camera = $camera_anchor/camera
@onready var targeting_ray = $camera_anchor/camera/targeting_ray
@onready var target_selection_ray = $camera_anchor/camera/target_selection_ray
@onready var laser_mount = $mesh/laser_mount
@onready var laser_mount2 = $mesh/laser_mount2
@onready var laser_timer = $laser_timer

@onready var laser_scene = preload("res://laser.tscn")

const TERMINAL_VELOCITY = 10
const MAX_THROTTLE_VELOCITY = 7
const MAX_ROTATION_SPEED = Vector3(1.4, 0.8, 0.2)
const ACCELERATION = Vector3(2.5, 2.5, 2.5)

enum YawRoll {
    OFF,
    ON_INITIAL_ROLL,
    ON_LOW_ROLL
}

var rotation_type = YawRoll.ON_LOW_ROLL
var rotation_input = Vector3(0, 0, 0)
var rotation_speed = Vector3(0, 0, 0)
var rotation_values = Vector3(0, 0, 0)

var throttle = 0

var has_boost = true
var boost_impulse = Vector3.ZERO
var collision_impulse = Vector3.ZERO
var drifting = false

var weapons_target
var weapon_alternator = 0
var target = null
var crosshair_position = Vector2.ZERO
var target_reticle_position = null

var debug_display = []

func _ready():
    targeting_ray.add_exception(self)
    target_selection_ray.add_exception(self)
    laser_timer.timeout.connect(laser_timer_timeout)

func _input(event):
    if event is InputEventMouseButton:
        if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
            Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        rotation_input.y += event.relative.y * 0.01
        if Input.is_action_pressed("yaw_roll"):
            rotation_input.z += event.relative.x * 0.01
        else:
            var prev_rotation_input = rotation_input.x
            rotation_input.x += event.relative.x * 0.01
            if Vector2(prev_rotation_input, 0).normalized() != Vector2(rotation_input.x, 0).normalized():
                yaw_roll_timer.start(0.25)
    if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
        var prev_roll_input = rotation_input.x
        rotation_input.x = Input.get_action_strength("roll_left") - Input.get_action_strength("roll_right")
        rotation_input.y = Input.get_action_strength("pitch_down") - Input.get_action_strength("pitch_up")
        rotation_input.z = Input.get_action_strength("yaw_left") - Input.get_action_strength("yaw_right")

        if yaw_roll_timer.is_stopped() and prev_roll_input == 0 and rotation_input.x != 0:
            yaw_roll_timer.start(0.25)
        # if Input.is_action_pressed("yaw_roll"):
            # rotation_input.x = 0
            #rotation_input.z = Input.get_action_strength("roll_left") - Input.get_action_strength("roll_right")
        #else:
            # rotation_input.x = Input.get_action_strength("roll_left") - Input.get_action_strength("roll_right")
            # rotation_input.z = 0

func _physics_process(delta):
    # misc inputs
    if Input.is_action_just_pressed("escape"):
        if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            rotation_input = Vector3.ZERO

    if Input.is_action_just_pressed("boost") and has_boost:
        boost()
    if Input.is_action_just_pressed("flight_assist"):
        drifting = not drifting
    if Input.is_action_pressed("shoot"):
        if laser_timer.is_stopped():
            shoot()
    if Input.is_action_just_pressed("target"):
        target = null
        for _target in get_tree().get_nodes_in_group("targets"):
            if target != null:
                break
            if camera.is_position_behind(_target.position):
                continue
            var target_screen_position = camera.unproject_position(_target.position)
            if (target_screen_position - crosshair_position).length() <= 30:
                target_selection_ray.look_at(_target.position)
                target_selection_ray.force_raycast_update()
                print(target_selection_ray.is_colliding(), " / ", target_selection_ray.get_collider())
                if target_selection_ray.is_colliding() and target_selection_ray.get_collider() == _target:
                    target = _target

    # Flight rotation
    for i in range(0, 3):
        if abs(rotation_input[i]) <= 0.01:
            rotation_input[i] = 0
            if i == 0:
                yaw_roll_timer.stop()

        if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
            if rotation_input[i] > 0:
                rotation_input[i] -= 0.01
            elif rotation_input[i] < 0:
                rotation_input[i] += 0.01
            # Limit input
            rotation_input[i] = clamp(rotation_input[i], -3, 3)

    # flight assist rotation correction
    if not drifting:
        for i in range(0, 3):
            if rotation_speed[i] > 0:
                rotation_speed[i] -= 0.02
            elif rotation_speed[i] < 0:
                rotation_speed[i] += 0.02

    var roll = rotation_input.x
    var yaw = rotation_input.z
    if rotation_type == YawRoll.ON_INITIAL_ROLL and not yaw_roll_timer.is_stopped():
        yaw += roll
    elif rotation_type == YawRoll.ON_LOW_ROLL and abs(rotation_input.x) > 0.3:
        yaw += rotation_input.x

    rotation_speed += Vector3(roll, rotation_input.y, yaw)
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
    camera_anchor.transform = camera_anchor.transform.interpolate_with(mesh.transform, delta * 1.5)

    # Check thrust inputs
    var thrust_input = Vector3.ZERO
    thrust_input.y = Input.get_action_strength("thrust_up") - Input.get_action_strength("thrust_down")
    var z_input = Input.get_action_strength("thrust_forwards") - Input.get_action_strength("thrust_backwards")
    throttle = clamp(throttle + (z_input * 0.01), 0, 1)
    thrust_input.x = Input.get_action_strength("thrust_right") - Input.get_action_strength("thrust_left")
    if Input.is_action_pressed("thrust_right"):
        thrust_input.x = 1
    if Input.is_action_pressed("thrust_left"):
        thrust_input.x = -1

    debug_display.append("Throttle: " + str(snapped(throttle, 0.01)))

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

    # debug display
    debug_display.append("Velocity: " + str(snapped(velocity.length(), 0.1)))
    if boost_impulse != Vector3.ZERO:
        debug_display.append("BOOST!")
    elif has_boost:
        debug_display.append("ready")
    else:
        debug_display.append("charging...")
    if drifting:
        debug_display.append("DRIFT")
    else:
        debug_display.append("no drift")

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

    # set camera fov
    if boost_impulse == Vector3.ZERO:
        camera.fov = lerp(camera.fov, 75 + (32 * (velocity.length() / TERMINAL_VELOCITY)), delta)

    # set weapons target
    target_reticle_position = null
    if target != null and not camera.is_position_behind(target.position):
        target_reticle_position = camera.unproject_position(target.position)

    weapons_target = $mesh/target.to_global($mesh/target.position)
    if target_reticle_position != null and crosshair_position.distance_to(target_reticle_position) <= 25:
        weapons_target = target.position
    targeting_ray.look_at(weapons_target)
    targeting_ray.force_raycast_update()
    if targeting_ray.is_colliding():
        weapons_target = targeting_ray.get_collision_point()
    
    crosshair_position = camera.unproject_position(weapons_target)

func boost():
    has_boost = false
    var tween = get_tree().create_tween()
    tween.tween_property(self, "velocity", -mesh.transform.basis.z * velocity.length(), 0.3)
    await tween.finished
    var camera_tween = get_tree().create_tween()
    camera_tween.tween_property(camera, "fov", 115, 0.2)
    await camera_tween.finished
    boost_impulse = -mesh.transform.basis.z * 30
    boost_timer.start(1)
    await boost_timer.timeout
    boost_impulse = Vector3.ZERO
    boost_timer.start(10)
    await boost_timer.timeout
    has_boost = true

func laser_timer_timeout():
    if Input.is_action_pressed("shoot"):
        shoot()

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
