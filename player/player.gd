extends CharacterBody3D

@onready var helpers = get_node("/root/Helpers")

@onready var arc_laser_scene = preload("res://projectiles/arc_laser/arc_laser.tscn")
@onready var laser_scene = preload("res://projectiles/laser/laser.tscn")

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
@onready var weapon_lock_timer = $weapon_lock_timer

@onready var ship = preload("res://ships/hummingbird.tres")

@export var invert_pitch = false

const CROSSHAIR_SENSITIVITY = 300
var rotation_input = Vector2.ZERO
var rotation_speed = Vector3.ZERO

var crosshair_position = Vector2.ZERO
var navigator_position = Vector2.ZERO

var camera_trauma_noise
var camera_trauma_noise_pos = Vector2(randi_range(1, 100), 1)
var camera_trauma = 0

var has_boost = true
var boost_impulse = Vector3.ZERO

var weapons_target
var weapon_alternator = 0
var target = null
var target_reticle_position = null
var target_follow_angle
var is_shooting = false
var weapon_has_lock = false
var current_weapon = 0
var weapon_range_min = [5, 10]
var weapon_range_max = [30, 40]
var weapon_max_aim_distance = [128, 32]
var weapon_lock_duration = [0, 3]

var collision_radius = 0

var hull = 0

func _ready():
    add_to_group("obstacles")

    crosshair_position = get_viewport().get_visible_rect().size / 2
    navigator_position = get_viewport().get_visible_rect().size / 2

    camera_trauma_noise = FastNoiseLite.new()
    camera_trauma_noise.set_noise_type(FastNoiseLite.TYPE_SIMPLEX)
    camera_trauma_noise.seed = randi()
    camera_trauma_noise.frequency = 2.0

    collision_radius = $avoidance_sphere.shape.radius
    targeting_ray.add_exception(self)
    target_selection_ray.add_exception(self)
    laser_timer.timeout.connect(laser_timer_timeout)
    weapon_lock_timer.timeout.connect(lock_target)

    hull = ship.HULL_STRENGTH

func _input(event):
    if event is InputEventMouseButton:
        if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
            Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        crosshair_position += event.relative

func _physics_process(delta):
    if not visible:
        return
    # misc inputs
    if Input.is_action_just_pressed("escape"):
        if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

    if Input.is_action_just_pressed("boost") and has_boost:
        boost()
    if Input.is_action_just_pressed("shoot"):
        on_initial_shoot()
    if Input.is_action_just_pressed("swap_weapons"):
        laser_timer.stop()
        weapon_lock_timer.stop()
        current_weapon = (current_weapon + 1) % 2
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
                if target_selection_ray.is_colliding() and target_selection_ray.get_collider() == _target:
                    target = _target
    var roll_input = Input.get_action_strength("roll_left") - Input.get_action_strength("roll_right")

    # handle joystick cursor input
    if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
        rotation_input.x = Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
        rotation_input.y = Input.get_action_strength("pitch_up") - Input.get_action_strength("pitch_down")

    # update navigator based on input
    if invert_pitch:
        rotation_input.y = -rotation_input.y
    navigator_position += rotation_input * CROSSHAIR_SENSITIVITY * delta
    navigator_position.x = clamp(navigator_position.x, 0, get_viewport().get_visible_rect().size.x)
    navigator_position.y = clamp(navigator_position.y, 0, get_viewport().get_visible_rect().size.y)
    var navigator_value = (navigator_position - (get_viewport().get_visible_rect().size / 2)) / (get_viewport().get_visible_rect().size / 2)

    # slowly return navigator to screen center
    if (navigator_position - (get_viewport().get_visible_rect().size / 2)).length() <= 2:
        navigator_position = get_viewport().get_visible_rect().size / 2
    else:
        navigator_position += -navigator_value * 4

    # lookat style rotation towards target
    var rotation_lookat_target = camera.project_position(navigator_position, 500)
    var bank_angle = (PI / 2) * abs(navigator_value.x)
    var rotation_up_direction = camera_anchor.basis.y.rotated(camera_anchor.basis.x, bank_angle)
    var rotation_target_transform = mesh.transform.looking_at(rotation_lookat_target, rotation_up_direction)
    var speed_percent = velocity.length() / ship.MAX_THROTTLE_VELOCITY
    if not (navigator_position == get_viewport().get_visible_rect().size / 2 and abs(rad_to_deg((-mesh.transform.basis.z).signed_angle_to(rotation_lookat_target, rotation_up_direction))) <= 2):
        mesh.transform = mesh.transform.interpolate_with(rotation_target_transform, (1 + (speed_percent * 3)) * delta)

    # physics-based rotation (for stuff like collisions)
    for i in range(0, 3):
        if rotation_speed[i] > 0:
            rotation_speed[i] = max(rotation_speed[i] - 0.02, 0)
        elif rotation_speed[i] < 0:
            rotation_speed[i] = min(rotation_speed[i] + 0.02, 0)
    if roll_input > 0:
        rotation_speed.x = min(rotation_speed.x + roll_input, 2)
    elif roll_input < 0:
        rotation_speed.x = max(rotation_speed.x + roll_input, -2)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.z, rotation_speed.x * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.x, rotation_speed.y * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.y, rotation_speed.z * delta)
    mesh.transform.basis = mesh.transform.basis.orthonormalized()

    # update camera
    var camera_follow_speed_percent = 1
    if rotation_speed.length() > ship.MAX_ROTATION_SPEED.length():
        camera_follow_speed_percent = 1 - min((rotation_speed.length() - ship.MAX_ROTATION_SPEED.length()) / ship.MAX_ROTATION_SPEED.length(), 1)
    var camera_speed_mod = 1.5 
    camera_anchor.transform = camera_anchor.transform.interpolate_with(mesh.transform, delta * camera_follow_speed_percent * camera_speed_mod)
    camera.position.x = lerp(camera.position.x, navigator_value.x * 3, delta)
    if navigator_value.y > 0:
        camera.position.y = lerp(camera.position.y, 2 + (navigator_value.y * 0.1), delta)
    else:
        camera.position.y = lerp(camera.position.y, 2 - (navigator_value.y * 0.75), delta)
    
    # camera shake
    var camera_shake_amount = camera_trauma * max(1, velocity.length() * 0.3)
    camera_anchor.transform.basis = camera_anchor.transform.basis.rotated(camera_anchor.transform.basis.z, 0.005 * camera_shake_amount * camera_trauma_noise.get_noise_2d(camera_trauma_noise_pos.x, camera_trauma_noise_pos.y))
    camera.position.x += 0.01 * camera_shake_amount * camera_trauma_noise.get_noise_2d(camera_trauma_noise_pos.x * 2, camera_trauma_noise_pos.y)
    camera.position.y += 0.01 * camera_shake_amount * camera_trauma_noise.get_noise_2d(camera_trauma_noise_pos.x * 3, camera_trauma_noise_pos.y)
    camera_trauma_noise_pos.y += 1
    camera_trauma = max(camera_trauma - 0.1, 0)

    # Check thrust inputs
    var thrust_input = Vector3.ZERO
    thrust_input.y = Input.get_action_strength("thrust_up") - Input.get_action_strength("thrust_down")
    thrust_input.x = Input.get_action_strength("thrust_right") - Input.get_action_strength("thrust_left")
    thrust_input.z = -(Input.get_action_strength("thrust_forwards") - Input.get_action_strength("thrust_backwards"))

    # decceleration
    if boost_impulse == Vector3.ZERO and thrust_input != Vector3.ZERO:
        for i in range(0, 3):
            var basis_velocity = helpers.vector_component_in_vector_direction(velocity, mesh.transform.basis[i])
            var positive_basis = mesh.transform.basis[i]
            if (basis_velocity.normalized().is_equal_approx(-positive_basis) and not thrust_input[i] < 0) or (basis_velocity.normalized().is_equal_approx(positive_basis) and not (thrust_input[i] > 0)):
                var decel_strength = min(ship.DECELERATION * delta, basis_velocity.length())
                velocity += -basis_velocity * decel_strength

    # thrust acceleration
    var previous_velocity = velocity.length()
    for i in range(0, 3):
        velocity += mesh.transform.basis[i] * thrust_input[i] * ship.ACCELERATION * delta
        var basis_velocity = helpers.vector_component_in_vector_direction(velocity, mesh.transform.basis[i])
        var max_basis_velocity = ship.MAX_THRUST_VELOCITY
        if i == 2:
            max_basis_velocity = ship.MAX_THROTTLE_VELOCITY
        if basis_velocity.length() > max_basis_velocity:
            velocity += -basis_velocity * (basis_velocity.length() - max_basis_velocity)
    if boost_impulse == Vector3.ZERO and previous_velocity <= ship.MAX_THROTTLE_VELOCITY:
        velocity = velocity.limit_length(ship.MAX_THROTTLE_VELOCITY)

    # boost impulse doesn't care about basis velocity limits
    if boost_impulse != Vector3.ZERO:
        velocity += boost_impulse * delta

    # limit velocity
    velocity = velocity.limit_length(ship.TERMINAL_VELOCITY)

    # move and handle collisions
    var collision = move_and_collide(velocity * delta)
    if collision:
        velocity += collision.get_normal() * velocity.length() * ship.COLLISION_IMPULSE_MODIFIER * delta
        rotation_speed.x = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.x)
        rotation_speed.y = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.z) 
        rotation_speed.z = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.y) 
        rotation_speed *= velocity.length() * ship.COLLISION_ROTATION_MODIFIER
        camera_trauma = max(10.0 * (velocity.length() / ship.MAX_THROTTLE_VELOCITY), camera_trauma)

    # set camera fov
    if boost_impulse == Vector3.ZERO:
        var desired_camera_fov = 75 + (32 * (velocity.length() / ship.TERMINAL_VELOCITY))
        camera.fov = lerp(camera.fov, desired_camera_fov, delta)

    # set weapons target
    target_reticle_position = null
    target_follow_angle = null
    if target != null: 
        if not camera.is_position_behind(target.position):
            target_reticle_position = camera.unproject_position(target.position)
            if not get_viewport().get_visible_rect().has_point(target_reticle_position):
                target_reticle_position = null
        if target_reticle_position == null:
            var direction_xbasis = helpers.vector_component_in_vector_direction(position.direction_to(target.position), mesh.transform.basis.x)
            var direction_ybasis = helpers.vector_component_in_vector_direction(position.direction_to(target.position), mesh.transform.basis.y)
            var screen_direction = Vector2(direction_xbasis.length(), direction_ybasis.length())
            if direction_xbasis.normalized().is_equal_approx(-mesh.transform.basis.x):
                screen_direction.x *= -1
            if direction_ybasis.normalized().is_equal_approx(-mesh.transform.basis.y):
                screen_direction.y *= -1
            target_follow_angle = rad_to_deg(screen_direction.angle())

    weapons_target = $mesh/target.to_global($mesh/target.position)
    if target_reticle_position != null and position.distance_to(target.position) >= weapon_range_min[current_weapon] and position.distance_to(target.position) <= weapon_range_max[current_weapon] and crosshair_position.distance_to(target_reticle_position) <= weapon_max_aim_distance[current_weapon]:
        if weapon_lock_duration[current_weapon] == 0:
            weapon_has_lock = true
        if weapon_has_lock: 
            weapons_target = target.position + (target.velocity * (position.distance_to(target.position) / 50))
        elif weapon_lock_timer.is_stopped():
            weapon_lock_timer.start(weapon_lock_duration[current_weapon])
    else:
        weapon_has_lock = false
        weapon_lock_timer.stop()
    targeting_ray.look_at(weapons_target)
    targeting_ray.force_raycast_update()
    if targeting_ray.is_colliding():
        weapons_target = targeting_ray.get_collision_point()

    crosshair_position = camera.unproject_position(weapons_target)
    if (crosshair_position - (get_viewport().get_visible_rect().size / 2)).length() <= 2:
        crosshair_position = get_viewport().get_visible_rect().size / 2
    
    print(rad_to_deg((-mesh.transform.basis.z).angle_to(position.direction_to(rotation_lookat_target))))

func boost():
    has_boost = false
    var tween = get_tree().create_tween()
    tween.tween_property(self, "velocity", -mesh.transform.basis.z * velocity.length(), 0.3)
    await tween.finished
    var camera_tween = get_tree().create_tween()
    camera_tween.tween_property(camera, "fov", 115, 0.2)
    await camera_tween.finished
    boost_impulse = -mesh.transform.basis.z * ship.BOOST_IMPULSE_STRENGTH
    boost_timer.start(ship.BOOST_IMPULSE_DURATION)
    await boost_timer.timeout
    boost_impulse = Vector3.ZERO
    boost_timer.start(10)
    await boost_timer.timeout
    has_boost = true

func laser_timer_timeout():
    if Input.is_action_pressed("shoot"):
        shoot_laser()

func lock_target():
    weapon_has_lock = true

func on_initial_shoot():
    if current_weapon == 0:
        if laser_timer.is_stopped():
            shoot_laser()
    elif current_weapon == 1:
        if not is_shooting:
            shoot_missile()

func shoot_laser():
    var bullet = laser_scene.instantiate()
    get_parent().add_child(bullet)
    if weapon_alternator == 0:
        bullet.position = laser_mount.global_position - mesh.transform.basis.z
        weapon_alternator = 1
    else:
        bullet.position = laser_mount2.global_position - mesh.transform.basis.z
        weapon_alternator = 0
    bullet.add_collision_exception_with(self)
    bullet.aim(weapons_target)
    laser_timer.start(0.1)
    camera_trauma = max(1.0, camera_trauma)

func shoot_missile():
    is_shooting = true
    for i in range(0, 2):
        var bullet = arc_laser_scene.instantiate()
        get_parent().add_child(bullet)
        var skew = mesh.transform.basis.x
        if weapon_alternator == 0:
            bullet.position = laser_mount.global_position
            weapon_alternator = 1
        else:
            skew *= -1
            bullet.position = laser_mount2.global_position
            weapon_alternator = 0
        bullet.add_collision_exception_with(self)
        var bullet_target = null
        if weapon_has_lock:
            bullet_target = target
        bullet.aim(bullet_target, weapons_target, skew)
    is_shooting = false

func handle_bullet(damage):
    hull -= damage
    if hull <= 0:
        visible = false
    camera_trauma = max(2.0, camera_trauma)
