package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import im "../../external/odin-imgui"
import "inspector"
import "menu"
import "../engine"
import "undo"

ProjectViewData :: struct {
    currentPath: string,
    selectedFile: string,
    rootPath: string,
}

projectViewData: ProjectViewData

init_project_view :: proc() {
    projectViewData.rootPath = strings.clone(".")
    projectViewData.currentPath = strings.clone(".")
}

shutdown_project_view :: proc() {
    delete(projectViewData.rootPath)
    delete(projectViewData.currentPath)
    if projectViewData.selectedFile != "" {
        delete(projectViewData.selectedFile)
    }
}

draw_directory_tree :: proc(path: string, level: int = 0) {
    handle, err := os.open(path)
    if err != nil {
        return
    }
    defer os.close(handle)
    
    entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }
    defer os.file_info_slice_delete(entries, context.temp_allocator)

    slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
        return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
    })
    
    for entry in entries {
        if entry.type != .Directory {
            continue
        }
        
        full_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
        
        // Create tree node for directory
        node_label := strings.clone_to_cstring(entry.name)
        defer delete(node_label)
        
        // Check if this is the selected path
        is_selected := projectViewData.currentPath == full_path
        
        node_flags: im.TreeNodeFlags = {.OpenOnArrow, .OpenOnDoubleClick}
        if is_selected {
            node_flags += {.Selected}
        }
        
        node_open := im.TreeNodeEx(node_label, node_flags)
        
        // Handle selection
        if im.IsItemClicked() {
            // Clear old path and set new one
            delete(projectViewData.currentPath)
            projectViewData.currentPath = strings.clone(full_path)
        }
        
        if node_open {
            draw_directory_tree(full_path, level + 1)
            im.TreePop()
        }
    }
}

is_known_extension :: proc(filename: string) -> bool {
    ext := filepath.ext(filename)
    if ext == ".prefab" || ext == ".asset" || ext == ".scene" do return true
    return engine.is_importable_extension(ext)
}

draw_file_list :: proc(path: string) {
    handle, err := os.open(path)
    if err != nil {
        im.Text("Failed to open directory")
        return
    }
    defer os.close(handle)
    
    entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        im.Text("Failed to read directory")
        return
    }
    defer os.file_info_slice_delete(entries, context.temp_allocator)

    slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
        return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
    })
    
    path_label := strings.clone_to_cstring(fmt.tprintf("Path: %s", path))
    defer delete(path_label)
    im.Text(path_label)
    im.Separator()
    
    // Draw directories first
    for entry in entries {
        if entry.type != .Directory {
            continue
        }
        
        label := strings.clone_to_cstring(fmt.tprintf("[DIR] %s", entry.name))
        defer delete(label)
        
        is_selected := projectViewData.selectedFile == entry.name
        
        if im.Selectable(label, is_selected) {
            delete(projectViewData.selectedFile)
            projectViewData.selectedFile = strings.clone(entry.name)
            
            full_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
            delete(projectViewData.currentPath)
            projectViewData.currentPath = strings.clone(full_path)
        }
        
        if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
            full_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
            delete(projectViewData.currentPath)
            projectViewData.currentPath = strings.clone(full_path)
        }
    }
    
    // Draw files below directories
    for entry in entries {
        if strings.has_prefix(entry.name, ".") {
            continue
        }
        
        if entry.type == .Directory {
            continue
        }

        if filepath.ext(entry.name) == ".meta" {
            continue
        }
        
        label := strings.clone_to_cstring(entry.name)
        defer delete(label)

        is_selected := projectViewData.selectedFile == entry.name

        if !is_known_extension(entry.name) {
            text_col := im.GetStyleColorVec4(im.Col.Text)
            dimmed: im.Vec4 = {text_col[0] * 0.6, text_col[1] * 0.6, text_col[2] * 0.6, text_col[3]}
            im.PushStyleColorImVec4(im.Col.Text, dimmed)
        }
        if im.Selectable(label, is_selected, {.AllowDoubleClick}) {
            delete(projectViewData.selectedFile)
            projectViewData.selectedFile = strings.clone(entry.name)

            full_path, _ := filepath.join({path, entry.name}, context.temp_allocator)

            if strings.has_suffix(entry.name, ".asset") {
                undo.clear(undo.get())
                inspector.load_from_file(full_path)
            }
            ext := filepath.ext(entry.name)
            if engine.is_importable_extension(ext) {
                undo.clear(undo.get())
                inspector.load_import_settings(full_path)
            }
            if strings.has_suffix(entry.name, ".scene") && im.IsMouseDoubleClicked(.Left) {
                undo.clear(undo.get())
                // Fresh navigation — reset the nested-scene edit stack.
                hierarchy_edit_stack_clear()
                scene := engine.scene_load_single_path(full_path)
                engine.sm_scene_set_active(scene)
            }
        }
        // Right-click also selects, so the context menu (which acts on the
        // selected asset) targets the row under the cursor, not whatever was
        // previously selected.
        if im.IsItemHovered() && im.IsMouseClicked(.Right) {
            delete(projectViewData.selectedFile)
            projectViewData.selectedFile = strings.clone(entry.name)
        }
        if im.BeginDragDropSource({}) {
            full_path, _ := filepath.join({path, entry.name}, context.temp_allocator)
            raw := raw_data(full_path)
            im.SetDragDropPayload("ASSET_PATH", raw, len(full_path))
            im.Text(label)
            im.EndDragDropSource()
        }
        if !is_known_extension(entry.name) {
            im.PopStyleColor()
        }
    }
}

// Create a prefab variant of the scene at `base_path`, written alongside it as
// "<name>_Variant.scene", then open it. The variant's root is a NestedScene
// over the base (empty overrides); editing it captures overrides against the base.
create_scene_variant :: proc(base_path: string) {
    dir := filepath.dir(base_path)
    defer delete(dir)
    stem := filepath.stem(base_path)
    variant_name := strings.concatenate({stem, "_Variant.scene"}, context.temp_allocator)
    variant_path, _ := filepath.join({dir, variant_name}, context.temp_allocator)

    if !engine.scene_create_variant_file(base_path, variant_path) {
        fmt.printf("[Editor] Failed to create scene variant from %s\n", base_path)
        return
    }
    // Mint the variant's .meta and register it so it can be loaded by GUID.
    engine.asset_db_refresh()

    undo.clear(undo.get())
    hierarchy_edit_stack_clear()
    scene := engine.scene_load_single_path(variant_path)
    engine.sm_scene_set_active(scene)
}

draw_project_view :: proc() {
    if im.Begin("Project", nil, {.NoCollapse}) {
        // Create two columns
        im.Columns(2, "ProjectColumns", true)
        
        // Left pane: Tree view
        im.BeginChild("TreeView", im.Vec2{0, 0}, {.Borders})
        
        // Draw root "Assets" node
        root_flags: im.TreeNodeFlags = {.OpenOnArrow, .OpenOnDoubleClick, .DefaultOpen}
        if projectViewData.currentPath == projectViewData.rootPath {
            root_flags += {.Selected}
        }
        
        root_open := im.TreeNodeEx("Assets", root_flags)
        
        if im.IsItemClicked() {
            delete(projectViewData.currentPath)
            projectViewData.currentPath = strings.clone(projectViewData.rootPath)
        }
        
        if root_open {
            // Draw the tree starting from root
            draw_directory_tree(projectViewData.rootPath)
            im.TreePop()
        }
        
        im.EndChild()
        
        im.NextColumn()
        
        // Right pane: File list
        im.BeginChild("FileList", im.Vec2{0, 0}, {.Borders})
        
        // Draw files in current path
        draw_file_list(projectViewData.currentPath)

        if im.BeginPopupContextWindow("ProjectFileListContext", im.PopupFlags_MouseButtonRight) {
            menu.draw_menu_subtree("Assets")
            im.EndPopup()
        }

        im.EndChild()
        
        im.Columns(1)
    }
    im.End()
}
