package app

@(typ_guid={guid = "f47ac10b-58cc-4372-a567-0e02b2c3d479", menu_assets_create = {menu_name = "Game Settings", order = 0}})
GameSettings :: struct {
    playerSpeed: f32 `inspect:"" json:"-"
        decor:min(0.5)`,
    maxHealth: int `
        decor:min(5)
        `,

    isDebugMode: bool,

    test: bool `
        decor:readonly()
        `,

    a: A,
    a2: A,

    gameNames:[dynamic]string `
        decor:header(text="Test Header")
        decor:tooltip(desc="Tooltip message")`,

    dynamicInt:[dynamic]int `
        decor:separator()`,
    dynamicA:[dynamic]A,
    a3:[3]A,
    int3:[3]int,

    comp: UnionTest,
    comps3: [3]UnionTest,
}
