package inspector

import "core:fmt"
import "core:strings"
import "core:encoding/uuid"
import im "../../../external/odin-imgui"
import "../../engine"

@(property_drawer={type = engine.Asset_GUID, priority = 0})
draw_asset_guid_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
    guid_ptr := cast(^engine.Asset_GUID)ptr
    guid_val := uuid.Identifier(guid_ptr^)

    display: string
    if guid_val == (uuid.Identifier{}) {
        display = "None"
    } else if path, ok := engine.asset_db_get_path(guid_val); ok {
        last_slash := strings.last_index(path, "/")
        if last_slash >= 0 && last_slash + 1 < len(path) {
            display = path[last_slash + 1:]
        } else {
            display = path
        }
    } else {
        display = fmt.tprintf("%v", guid_val)
    }

    im.AlignTextToFramePadding()
    im.Text(label)
    im.SameLine(0, 8)

    avail := im.GetContentRegionAvail().x
    clear_w: f32 = 0
    has_value := guid_val != (uuid.Identifier{})
    if has_value {
        clear_w = 24
    }

    btn_label := strings.clone_to_cstring(
        fmt.tprintf("%s##%s", display, label), context.temp_allocator,
    )
    im.Button(btn_label, {avail - clear_w, 0})

    if im.BeginDragDropTarget() {
        if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil {
            path_data := string((cast([^]u8)payload.Data)[:payload.DataSize])
            if new_guid, ok := engine.asset_db_get_guid(path_data); ok {
                guid_ptr^ = engine.Asset_GUID(new_guid)
            }
        }
        im.EndDragDropTarget()
    }

    if has_value {
        im.SameLine(0, 0)
        clear_label := strings.clone_to_cstring(
            fmt.tprintf("X##clear_%s", label), context.temp_allocator,
        )
        if im.Button(clear_label, {clear_w, 0}) {
            guid_ptr^ = {}
        }
    }
}
