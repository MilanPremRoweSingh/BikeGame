@tool
extends EditorScript

const MASTER_SHADER = preload("res://assets/materials/master_material.gdshader")

func _run() -> void:
    var root = get_editor_interface().get_edited_scene_root()
    if root == null:
        push_error("Open a scene first.")
        return

    var converted := 0
    var cache: Dictionary = {}
    var nodes: Array[Node] = [root]

    while not nodes.is_empty():
        var node = nodes.pop_back()

        for child in node.get_children():
            nodes.push_back(child)

        if not node is MeshInstance3D or node.mesh == null:
            continue

        for surface in range(node.mesh.get_surface_count()):
            var source = node.get_active_material(surface)

            if source == null:
                continue

            var id = source.get_instance_id()
            var target: ShaderMaterial

            if cache.has(id):
                target = cache[id]
            else:
                target = ShaderMaterial.new()
                target.shader = MASTER_SHADER

                if source is StandardMaterial3D:
                    target.set_shader_parameter(
                        "albedo_texture", source.albedo_texture
                    )
                    target.set_shader_parameter(
                        "albedo_color", source.albedo_color
                    )
                    target.set_shader_parameter(
                        "roughness", source.roughness
                    )
                    target.set_shader_parameter(
                        "metallic", source.metallic
                    )

                cache[id] = target

            node.set_surface_override_material(surface, target)
            converted += 1

    print("Converted ", converted, " mesh surfaces.")