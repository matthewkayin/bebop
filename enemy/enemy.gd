extends CharacterBody3D

@onready var helpers = get_node("/root/Helpers")

@onready var mesh = $mesh
@onready var boost_timer = $boost_timer
@onready var laser_mount = $mesh/laser_mount
@onready var laser_mount2 = $mesh/laser_mount2
@onready var laser_timer = $laser_timer
@onready var targeting_ray = $targeting_ray
@onready var weapon_lock_timer = $weapon_lock_timer
@onready var camera_anchor = $camera_anchor
@onready var avoidance_ray = $avoidance_ray
@onready var avoidance_ray_left = $avoidance_ray_left
@onready var avoidance_ray_right = $avoidance_ray_right
@onready var avoidance_ray_up = $avoidance_ray_up
@onready var avoidance_ray_down = $avoidance_ray_down
@onready var maneuver_timer = $maneuver_timer

@onready var arc_laser_scene = preload("res://projectiles/arc_laser/arc_laser.tscn")
@onready var laser_scene = preload("res://projectiles/laser/laser.tscn")

@onready var ship = preload("res://ships/hummingbird.tres")

var rotation_speed = Vector3(0, 0, 0)

var thrust_input = Vector3.ZERO

var has_boost = true
var boost_impulse = Vector3.ZERO
var collision_impulse = Vector3.ZERO
var is_maneuvering = false

var weapons_target = null
var weapon_alternator = 0
var target = null
var number = 0
var weapon_has_lock = false
var current_weapon = 0
var weapon_range_min = [0, 10]
var weapon_range_max = [50, 40]
var weapon_max_aim_angle = [15, 30]
var weapon_lock_duration = [0, 3]
var is_shooting = false

var collision_radius = 0

var hull = 0

var direction = Vector3.FORWARD

func _ready():
    add_to_group("obstacles")
    add_to_group("targets")
    collision_radius = $avoidance_sphere.shape.radius

    var avoidance_ray_angle = 15
    var avoidance_ray_length = abs(avoidance_ray.target_position.z)
    var avoidance_ray_opposite = avoidance_ray_length * sin(deg_to_rad(avoidance_ray_angle))
    var avoidance_ray_adjacent = avoidance_ray_length * cos(deg_to_rad(avoidance_ray_angle))
    avoidance_ray_left.target_position = Vector3(-avoidance_ray_opposite, 0, -avoidance_ray_adjacent)
    avoidance_ray_right.target_position = Vector3(avoidance_ray_opposite, 0, -avoidance_ray_adjacent)
    avoidance_ray_up.target_position = Vector3(0, avoidance_ray_opposite, -avoidance_ray_adjacent)
    avoidance_ray_down.target_position = Vector3(0, -avoidance_ray_opposite, -avoidance_ray_adjacent)

    weapon_lock_timer.timeout.connect(lock_target)
    hull = ship.HULL_STRENGTH
    current_weapon = 0

func _physics_process(delta):
    if target == null:
        target = get_node_or_null("../player")

    # pathfinding
    if target != null and not is_maneuvering:
        thrust_input = Vector3.ZERO

        # obstacle avoidance
        var avoidance = Vector3.ZERO
        for ray in [avoidance_ray, avoidance_ray_right, avoidance_ray_down, avoidance_ray_up, avoidance_ray_left]:
            ray.force_raycast_update()
            if ray.is_colliding():
                avoidance += -(position + velocity).direction_to(ray.get_collision_point())
        avoidance = avoidance.normalized() * 0.5

        var desired_direction

        # ai chase mode
        if position.distance_to(target.position) > 20:
            desired_direction = position.direction_to(target.global_transform.origin)
            desired_direction += avoidance
            desired_direction = desired_direction.normalized()

            thrust_input.z = -1
        # ai evasive mode
        # note that this mode should only be used when ai is within a certain range of the player otherwise the ai might just flee indefinitely
        elif target.target == self and target.weapon_has_lock:
            var should_maneuver = maneuver_timer.is_stopped() 

            if should_maneuver:
                # begin barrel roll
                is_maneuvering = true
                desired_direction = direction
                var barrel_roll_direction = 1
                if randi_range(0, 1) == 0:
                    barrel_roll_direction = -1
                thrust_input.x = barrel_roll_direction
                var barrel_roll_tween = get_tree().create_tween()
                barrel_roll_tween.tween_property(mesh, "rotation", mesh.rotation + Vector3(0, 0, 2 * PI * barrel_roll_direction), 1.75)
                barrel_roll_tween.tween_callback(func(): 
                    is_maneuvering = false
                    maneuver_timer.start(randf_range(5, 15))
                )
            else:
                desired_direction = -(position.direction_to(target.global_transform.origin))
                desired_direction += avoidance
                desired_direction = desired_direction.normalized()
                thrust_input.z = -1
        # ai strafe mode
        else:
            desired_direction = position.direction_to(target.global_transform.origin)
            var desired_velocity_direction = position.direction_to(target.global_transform.origin + Vector3(0, 0, 10))
            desired_velocity_direction += avoidance
            desired_velocity_direction = desired_velocity_direction.normalized()

            thrust_input = desired_velocity_direction
            
        direction = (direction + (desired_direction * 0.1)).normalized()

    var rotation_lookat_target = position + (direction * 100)
    var roll_input = 0

    # lookat style rotation towards target
    var bank_angle = (PI / 2) * ((-transform.basis.z).signed_angle_to(direction, transform.basis.y) / PI)  
    if not is_maneuvering:
        mesh.rotation.z = bank_angle
    var rotation_target_transform = transform.looking_at(rotation_lookat_target, Vector3.UP)
    var speed_percent = velocity.length() / ship.MAX_THROTTLE_VELOCITY
    speed_percent = 1
    transform = transform.interpolate_with(rotation_target_transform, (1 + (speed_percent * 3)) * delta)

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
    transform.basis = transform.basis.rotated(transform.basis.z, rotation_speed.x * delta)
    transform.basis = transform.basis.rotated(transform.basis.x, rotation_speed.y * delta)
    transform.basis = transform.basis.rotated(transform.basis.y, rotation_speed.z * delta)
    transform.basis = transform.basis.orthonormalized()
    camera_anchor.transform = camera_anchor.transform.interpolate_with(camera_anchor.transform.looking_at(position - Vector3(0, 0, 100), Vector3.UP), delta)

    # decceleration
    if thrust_input != Vector3.ZERO:
        for i in range(0, 3):
            var basis_velocity = helpers.vector_component_in_vector_direction(velocity, transform.basis[i])
            var positive_basis = mesh.transform.basis[i]
            if (basis_velocity.normalized().is_equal_approx(-positive_basis) and not thrust_input[i] < 0) or (basis_velocity.normalized().is_equal_approx(positive_basis) and not (thrust_input[i] > 0)):
                var decel_strength = min(ship.DECELERATION * delta, basis_velocity.length())
                velocity += -basis_velocity * decel_strength

    # thrust acceleration
    for i in range(0, 3):
        velocity += transform.basis[i] * thrust_input[i] * ship.ACCELERATION * delta
        var basis_velocity = helpers.vector_component_in_vector_direction(velocity, transform.basis[i])
        var max_basis_velocity = ship.MAX_THRUST_VELOCITY
        if i == 2:
            max_basis_velocity = ship.MAX_THROTTLE_VELOCITY
        if basis_velocity.length() > max_basis_velocity:
            velocity += -basis_velocity * (basis_velocity.length() - max_basis_velocity)
    if boost_impulse == Vector3.ZERO:
        velocity = velocity.limit_length(ship.MAX_THROTTLE_VELOCITY)

    # boost impulse doesn't care about basis velocity limits
    if boost_impulse != Vector3.ZERO:
        velocity += boost_impulse * delta

    # limit velocity
    velocity = velocity.limit_length(ship.TERMINAL_VELOCITY)

    # move and handle collisions
    var collision = move_and_collide(velocity * delta)
    collision_impulse = Vector3.ZERO
    if collision:
        collision_impulse = collision.get_normal() * velocity.length() * ship.COLLISION_IMPULSE_MODIFIER * delta
        rotation_speed.x = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.x)
        rotation_speed.y = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.z) 
        rotation_speed.z = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.y) 
        rotation_speed *= velocity.length() * ship.COLLISION_ROTATION_MODIFIER

    # try to lock on to target
    weapons_target = null
    if target != null and position.distance_to(target.position) >= weapon_range_min[current_weapon] and position.distance_to(target.position) <= weapon_range_max[current_weapon] and rad_to_deg((-transform.basis.z).angle_to(position.direction_to(target.position))) <= weapon_max_aim_angle[current_weapon]:
        if weapon_lock_duration[current_weapon] == 0:
            weapon_has_lock = true
        if weapon_has_lock: 
            weapons_target = target.position + (target.velocity * (position.distance_to(target.position) / 140))
            targeting_ray.look_at(weapons_target)
            targeting_ray.force_raycast_update()
            if targeting_ray.is_colliding():
                weapons_target = targeting_ray.get_collision_point()
        elif weapon_lock_timer.is_stopped():
            weapon_lock_timer.start(weapon_lock_duration[current_weapon])
    else:
        weapon_has_lock = false
        weapon_lock_timer.stop()

    # shoot target
    if weapons_target != null:
        shoot()
        mesh.get_surface_override_material(0).albedo_color = Color(1, 0, 1)
    else:
        mesh.get_surface_override_material(0).albedo_color = Color(1, 0, 0)

func lock_target():
    weapon_has_lock = true

func boost():
    has_boost = false
    var tween = get_tree().create_tween()
    tween.tween_property(self, "velocity", -mesh.transform.basis.z * velocity.length(), 0.3)
    await tween.finished
    boost_impulse = -mesh.transform.basis.z * ship.BOOST_IMPULSE_STRENGTH
    boost_timer.start(ship.BOOST_IMPULSE_DURATION)
    await boost_timer.timeout
    boost_impulse = Vector3.ZERO
    boost_timer.start(10)
    await boost_timer.timeout
    has_boost = true

func shoot():
    return
    if is_shooting or not laser_timer.is_stopped():
        return
    if current_weapon == 0:
        shoot_laser()
    elif current_weapon == 1:
        shoot_missile()

func shoot_laser():
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
    laser_timer.start(0.1)

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
    laser_timer.start(1)

func handle_bullet(damage):
    hull -= damage
    if hull <= 0:
        queue_free()
