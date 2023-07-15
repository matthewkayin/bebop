extends MeshInstance3D

func _ready():
    mesh.radius = 0
    mesh.height = 0
    var material = StandardMaterial3D.new()
    material.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
    material.albedo_color = Color(1, 1, 1, 1)
    set_surface_override_material(0, material)

    var tween = get_tree().create_tween()
    tween.tween_property(mesh, "radius", 0.25, 0.05)
    tween.tween_property(get_surface_override_material(0), "albedo_color", Color(1, 1, 1, 0), 0.05)
    await tween.finished
    queue_free()

func _process(_delta):
    mesh.height = 2 * mesh.radius
