package app

@(typ_guid={guid = "c8b1e4a2-9d3f-4c5e-a6b7-8f1d2e3c4b5a", makeProcName = nameof(make_pPlayerSettings),
    menu_assets_create = {menu_name = "Player Settings", order = -12}})
PlayerSettings :: struct {
    name: string,
    maxHealth: int,
    speed: int,
}

make_pPlayerSettings :: proc() -> any {
    p := new(PlayerSettings)
    p.speed = 30
    return p^
}

