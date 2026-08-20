package editor

import gfx "../engine/gfx"
import im "moonhug:external/odin-imgui"
import "../engine"
import "menu"

ABOUT_POPUP_ID :: "About"
ABOUT_LOGO_PATH :: "../readme_files/Logo1.png"
ABOUT_LOGO_MAX_WIDTH :: f32(300)

about_logo_tex: ^gfx.Texture

draw_about_popup :: proc() {
    if menu.show_about {
        menu.show_about = false

        about_logo_tex, _ = engine.texture_load_file(ABOUT_LOGO_PATH)

        im.OpenPopup(ABOUT_POPUP_ID, {})
    }

    if about_logo_tex == nil {
        return
    }

    vp := im.GetMainViewport()
    center := im.Vec2{vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}
    im.SetNextWindowPos(center, .Appearing, im.Vec2{0.5, 0.5})

    if im.BeginPopupModal(ABOUT_POPUP_ID, nil, {.AlwaysAutoResize}) {
        tex_w := f32(about_logo_tex.width)
        tex_h := f32(about_logo_tex.height)
        scale := min(ABOUT_LOGO_MAX_WIDTH / tex_w, 1.0)
        img_size := im.Vec2{tex_w * scale, tex_h * scale}

        avail := im.GetContentRegionAvail()
        if avail.x > img_size.x {
            im.SetCursorPosX(im.GetCursorPosX() + (avail.x - img_size.x) * 0.5)
        }
        tex_id := im.TextureID(uintptr(gfx.texture_imgui_id(about_logo_tex)))
        im.Image(im.TextureRef{_TexID = tex_id}, img_size)
        im.Spacing()

        im.Separator()
        im.Spacing()
        im.Text("MoonHug Editor v%s", VERSION)
        im.Spacing()
        im.Separator()
        im.Spacing()

        btn_width: f32 = 120
        avail = im.GetContentRegionAvail()
        im.SetCursorPosX(im.GetCursorPosX() + (avail.x - btn_width) * 0.5)
        if im.Button("OK", im.Vec2{btn_width, 0}) {
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    } else {
        // Popup closed: release the logo. Deferred GPU release is safe even
        // though imgui referenced it this frame.
        gfx.texture_destroy(about_logo_tex)
        about_logo_tex = nil
    }
}
