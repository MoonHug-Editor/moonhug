## [0.17.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.16.1...v0.17.0) (2026-04-26)

### Features

* nested scene overrides wip ([c291f5e](https://github.com/MoonHug-Editor/moonhug/commit/c291f5e3c6fb918148e0dfca8464d2157cb4e827))

## [0.16.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.16.0...v0.16.1) (2026-04-22)

### Bug Fixes

* cleanup at shutdown to track leaks better ([3104367](https://github.com/MoonHug-Editor/moonhug/commit/310436719ef488f46c3df11c894dc4664d65d1c4))

## [0.16.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.15.0...v0.16.0) (2026-04-22)

### Features

* add "No cameras rendering" message to view_game ([7589bf1](https://github.com/MoonHug-Editor/moonhug/commit/7589bf11b7a29cd4d011dae1f35d195b794dd3cd))
* add run_debug.sh with tracking allocator in main ([cd7e024](https://github.com/MoonHug-Editor/moonhug/commit/cd7e024a59cd907d563882e1c59338145d7470da))
* improve history view UX, up/down/enter keys, drag split ([453237b](https://github.com/MoonHug-Editor/moonhug/commit/453237b3ef18a2b62fdbd40d797e427c23856775))

### Bug Fixes

* fix some leaks ([dc5ad8a](https://github.com/MoonHug-Editor/moonhug/commit/dc5ad8a095995f266f70b3185663493d929a153e))

## [0.15.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.14.2...v0.15.0) (2026-04-22)

### Features

* hierarchy alt+shift+A to toggle transform.active, render active only ([e6b7c73](https://github.com/MoonHug-Editor/moonhug/commit/e6b7c731f68ef80d3749b28406e8e1cd3e12b789))

## [0.14.2](https://github.com/MoonHug-Editor/moonhug/compare/v0.14.1...v0.14.2) (2026-04-21)

### Bug Fixes

* use comp_zero instead of p^={} for zeroing component ([b2ffaba](https://github.com/MoonHug-Editor/moonhug/commit/b2ffabafa84d4a0aa1bd11baf61cf0b93a5582f1))

## [0.14.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.14.0...v0.14.1) (2026-04-19)

### Bug Fixes

* undo reparent when nested scene has same local_id transform ([e345e1a](https://github.com/MoonHug-Editor/moonhug/commit/e345e1a16139b05f5068e1d768eda820d06e2fb6))

## [0.14.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.13.0...v0.14.0) (2026-04-19)

### Features

* add undo feature ([5b2835f](https://github.com/MoonHug-Editor/moonhug/commit/5b2835f4ed1d717ba613dcc48d358538f0916e85))
* save views on/off ([9f99b3b](https://github.com/MoonHug-Editor/moonhug/commit/9f99b3bc08ce0b54f3a3a69600685a6c9560451a))

### Bug Fixes

* zero transform when destroying ([a161982](https://github.com/MoonHug-Editor/moonhug/commit/a161982b01e690fd1c7d5b2c34fc5eeac9fc69b9))

## [0.13.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.12.0...v0.13.0) (2026-04-16)

### Features

* opaque nested scene wip ([a0c94b3](https://github.com/MoonHug-Editor/moonhug/commit/a0c94b3946bc31660a0df479052a715208f13255))

### Bug Fixes

* minor, remove TypeKey value for better git diff ([feb0609](https://github.com/MoonHug-Editor/moonhug/commit/feb0609f88b0127cf84789900480aa6d00c0f8b5))

## [0.12.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.11.0...v0.12.0) (2026-04-16)

### Features

* add reset context menu item to some scalar fields ([c5aca93](https://github.com/MoonHug-Editor/moonhug/commit/c5aca93ac126e829cf384defefc0d40bce8b30e3))

### Bug Fixes

* use core json package ([fb4e873](https://github.com/MoonHug-Editor/moonhug/commit/fb4e8737c6aa58dbeb9f83c44c4919c815de6594))

## [0.11.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.10.0...v0.11.0) (2026-04-15)

### Features

* copy core/json package for customization ([0407546](https://github.com/MoonHug-Editor/moonhug/commit/0407546f922b2ff42826395eba1b20df930dad74))
* improve type_reset, add type_cleanup feature ([b74cd6b](https://github.com/MoonHug-Editor/moonhug/commit/b74cd6b04f9c2fc2b687b07ee91373fc17f0259f))

## [0.10.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.9.1...v0.10.0) (2026-04-13)

### Features

* phase add mode (All,Editor, App) ([9eb1726](https://github.com/MoonHug-Editor/moonhug/commit/9eb17268080d832814de3e6ad6faf3095c03426b))

## [0.9.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.9.0...v0.9.1) (2026-04-10)

### Bug Fixes

* memory fixes, add memory guide wip ([9818bd2](https://github.com/MoonHug-Editor/moonhug/commit/9818bd2568efda6bc98e2e8628ace6f0913541ae))

## [0.9.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.8.0...v0.9.0) (2026-04-07)

### Features

* arrow keys to walk hierarchy scene tree ([5bf03dc](https://github.com/MoonHug-Editor/moonhug/commit/5bf03dc166655e04f8d2bd935a22afc93a35b579))
* hierarchy hold alt to expand/collapse subtree ([67b6631](https://github.com/MoonHug-Editor/moonhug/commit/67b663108dcef6bb29fc2102e804ecf5b48cf93c))

### Bug Fixes

* hierarchy rename context menu item ([3e68f1c](https://github.com/MoonHug-Editor/moonhug/commit/3e68f1c3931aeb10dbba9bd48a1353291a772138))

## [0.8.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.7.0...v0.8.0) (2026-04-06)

### Features

* support on_validate_* proc in same file as component struct ([7bb17a7](https://github.com/MoonHug-Editor/moonhug/commit/7bb17a793178f0585cb6980d1142f6b6f84e72a2))

## [0.7.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.6.0...v0.7.0) (2026-04-03)

### Features

* copy/paste fields ([893bfe9](https://github.com/MoonHug-Editor/moonhug/commit/893bfe96fbfa8d4210c9e8a7cae5e3fe728841d5))

### Bug Fixes

* component fields copy/paste ([f617ccc](https://github.com/MoonHug-Editor/moonhug/commit/f617ccce1d28261e978e8db8b3558911e5f70ad8))

## [0.6.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.5.0...v0.6.0) (2026-04-01)

### Features

* add buggy copy/paste/duplicate subtree procs ([55bcbec](https://github.com/MoonHug-Editor/moonhug/commit/55bcbec18cef1932dbe6b849be155596dcf3cc32))
* add more component context menu items ([032f603](https://github.com/MoonHug-Editor/moonhug/commit/032f603ec2a28d589a39d2af337dadf6982c3681))

## [0.5.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.4.0...v0.5.0) (2026-04-01)

### Features

* add reset_* proc feature for components ([38dac20](https://github.com/MoonHug-Editor/moonhug/commit/38dac203241ffff9fdf596850c9cc5324fdca9a8))

## [0.4.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.3.0...v0.4.0) (2026-03-31)

### Features

* add hierarchy context menu actions ([4f8db88](https://github.com/MoonHug-Editor/moonhug/commit/4f8db8886c481e5d3b6d19033b26c9076ec003b0))

## [0.3.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.2.1...v0.3.0) (2026-03-31)

### Features

* add Lifetime component and Transform.destroy field ([47e9af2](https://github.com/MoonHug-Editor/moonhug/commit/47e9af2ca973794c5a0d60b9824328cce068411a))
* add max to poolable and component to limit count in pools ([fd7cf31](https://github.com/MoonHug-Editor/moonhug/commit/fd7cf311e2105ab3081ea07c49d9937a6958c69a))

## [0.2.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.2.0...v0.2.1) (2026-03-30)

### Bug Fixes

* package name collision ([5f26c3c](https://github.com/MoonHug-Editor/moonhug/commit/5f26c3c69b4c9c05b886c68151a1375dbbfd1a79))

## [0.2.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.1.1...v0.2.0) (2026-03-28)

### Features

* add inline field tag to inline structs and unions ([418a7d3](https://github.com/MoonHug-Editor/moonhug/commit/418a7d32ec7f72014c517c0df63e7bb3e2728b20))
* skip tweens with base.skip=true ([1046b77](https://github.com/MoonHug-Editor/moonhug/commit/1046b7730833968b6b191c8985d3c6af36f404e4))

## [0.1.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.1.0...v0.1.1) (2026-03-28)

### Bug Fixes

* test semantic versioning ([3ec4864](https://github.com/MoonHug-Editor/moonhug/commit/3ec4864a65643db686144e6da22f4679ca8d9acd))
