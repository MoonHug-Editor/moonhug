## [0.74.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.73.1...v0.74.0) (2026-08-22)

### Features

* add progress overlay ([553e747](https://github.com/MoonHug-Editor/moonhug/commit/553e74751efd0f1dab3cf910e02e8334d96d68dd))

## [0.73.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.73.0...v0.73.1) (2026-08-20)

### Bug Fixes

* ignore /logs/ ([48e0f3b](https://github.com/MoonHug-Editor/moonhug/commit/48e0f3b9a2c8f29c483d74ae0f5c216ee7c7a646))

## [0.73.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.72.0...v0.73.0) (2026-08-20)

### Features

* inspector drawers funnel ([cf47dc9](https://github.com/MoonHug-Editor/moonhug/commit/cf47dc9b923fded1e9cf52dff49920ee74ba9e5e))

### Bug Fixes

* remove _generated files, gitignore them ([305047b](https://github.com/MoonHug-Editor/moonhug/commit/305047b03f302b9a7e07d3f31624a94849f7b643))
* tweens retype memory owner fix ([a98c880](https://github.com/MoonHug-Editor/moonhug/commit/a98c88075c1b47c78b15e817525b1069ad966035))

## [0.72.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.71.0...v0.72.0) (2026-08-20)

### Features

* improve crash log (time, version) ([87cf97a](https://github.com/MoonHug-Editor/moonhug/commit/87cf97ad9a46ca4df578b2741b9d541059f08968))
* one-shot audio, fade ([7a14582](https://github.com/MoonHug-Editor/moonhug/commit/7a145825a609b326c54a0d1998562b229bb1eb73))

## [0.71.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.70.0...v0.71.0) (2026-08-20)

### Features

* add audio, AudioSource, playback ([1aa7a14](https://github.com/MoonHug-Editor/moonhug/commit/1aa7a146828f666dbbecbac630582af2d89e13af))
* add AudioListener, pitch, mute, normalize ([89b5f4c](https://github.com/MoonHug-Editor/moonhug/commit/89b5f4c9adbec4a320049216a3e6cee80ce07526))

## [0.70.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.69.0...v0.70.0) (2026-08-20)

### Features

* tweens rewrite for modularity ([7cd20a7](https://github.com/MoonHug-Editor/moonhug/commit/7cd20a7cad3f46e88801d28487b3ab21816af77a))

## [0.69.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.68.0...v0.69.0) (2026-08-13)

### Features

* add Phase.SerializationInit to help decoupling ([510ef40](https://github.com/MoonHug-Editor/moonhug/commit/510ef404672f36e315396fb2df7a33fb1f7a4dc0))
* amend extract tween package ([4ab8f32](https://github.com/MoonHug-Editor/moonhug/commit/4ab8f324941e3a4f893806f92ba76e9eab1d81fc))
* extract audio importer ([ca88c7a](https://github.com/MoonHug-Editor/moonhug/commit/ca88c7a85bb6542b261f6d37230778fc509cbd17))
* extract core package for easier decoupling ([b939298](https://github.com/MoonHug-Editor/moonhug/commit/b93929894d8050ea664968a736db1f427b0f6132))
* gen folder for plugin packages ([081ca2b](https://github.com/MoonHug-Editor/moonhug/commit/081ca2b9314a597b0062b3befcbf0edc0b065bc2))
* make gen special folder ([fac97f1](https://github.com/MoonHug-Editor/moonhug/commit/fac97f1663b5312fe9fa92818ef76848188f0415))
* move Phases to core package ([2f3cfbe](https://github.com/MoonHug-Editor/moonhug/commit/2f3cfbeb47de5848046c551aba007ea8c14a0727))
* tween core to allow extending ([9604faa](https://github.com/MoonHug-Editor/moonhug/commit/9604faa4aa410032fd989af50e10f99777eafbd7))

## [0.68.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.67.0...v0.68.0) (2026-08-11)

### Features

* animation interpolation test assets ([89e8fb9](https://github.com/MoonHug-Editor/moonhug/commit/89e8fb935c6582eb9a5dabd913a07c87d8437bf1))
* extract tween package ([36b433f](https://github.com/MoonHug-Editor/moonhug/commit/36b433ffb1dc48cf5d03b251009ea41ae2003c8f))
* inspector multiedit over the whole selection ([66e9144](https://github.com/MoonHug-Editor/moonhug/commit/66e914497bdeb3f1f3a6266fd5da71045c571a7b))
* MCP multiselect and whole-editor screenshots ([e56118d](https://github.com/MoonHug-Editor/moonhug/commit/e56118de9b0f6e3a00034a08044424a2f8d0abc6))
* node graph package ([af95a75](https://github.com/MoonHug-Editor/moonhug/commit/af95a750881a59afb4ff27fd6f0f5088c2a52311))
* selectable history detail pane ([a2dd3fe](https://github.com/MoonHug-Editor/moonhug/commit/a2dd3feaa7675d61e92f3b55df41ecfb40cf663f))
* tween graph view ([033ae03](https://github.com/MoonHug-Editor/moonhug/commit/033ae0331477b0e675ab925355937235418ee69a))
* undo edit sessions, one transaction for value edits ([43711ed](https://github.com/MoonHug-Editor/moonhug/commit/43711ed900b361face31430e1050df4cfc7c330b))

### Bug Fixes

* ASCII dashes in UI strings, the font atlas has no em dash ([b1681cc](https://github.com/MoonHug-Editor/moonhug/commit/b1681cc12500b018168b1cd14631099a73fa8b8f))
* free Animation and ButtonsExample heap fields on destroy ([f169411](https://github.com/MoonHug-Editor/moonhug/commit/f169411437a0082807caa258e7120a87cfae8d54))
* keep euler angles in the human-readable spelling through gimbal ([58ec861](https://github.com/MoonHug-Editor/moonhug/commit/58ec8616fd6fe0fb85759e64eae8332ac187eada))
* skip re-import of meshes that already failed to import ([955b111](https://github.com/MoonHug-Editor/moonhug/commit/955b1110a6dd9a4a854c5b113f3f673142e8bff6))

## [0.67.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.66.1...v0.67.0) (2026-08-08)

### Features

* crash_journal ([9ab7ebe](https://github.com/MoonHug-Editor/moonhug/commit/9ab7ebeb3a0403deedb867583054bdc882dea1c9))

## [0.66.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.66.0...v0.66.1) (2026-08-08)

### Bug Fixes

* move, rename, docs ([00a39a4](https://github.com/MoonHug-Editor/moonhug/commit/00a39a4e1c543619b2ce7aacefe6037e0a528789))

## [0.66.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.65.0...v0.66.0) (2026-08-08)

### Features

* mcp ([c7ccb26](https://github.com/MoonHug-Editor/moonhug/commit/c7ccb26c548a167b5ad42556b9f9699d1ed4ee83))
* mcp improvements, settings.enabled, generator ([f8c7bbb](https://github.com/MoonHug-Editor/moonhug/commit/f8c7bbbb47d8be61b43ffcda779401d5fd9b39de))

### Bug Fixes

* generated sort order ([133e7e3](https://github.com/MoonHug-Editor/moonhug/commit/133e7e3ef1882e8908e02a7c137aaad49ed9b3cb))

## [0.65.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.64.0...v0.65.0) (2026-08-07)

### Features

* pool_next components iteration ([392007e](https://github.com/MoonHug-Editor/moonhug/commit/392007eeffb2be0b75d7fdc6a7d2e10d65ac6d4f))
* shader compile failure fallback to older artifact ([ff4268d](https://github.com/MoonHug-Editor/moonhug/commit/ff4268da4999fecbe1a729582ac67a4680e29aab))

## [0.64.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.63.0...v0.64.0) (2026-08-07)

### Features

* library folder rework, cache thumbnails ([7961536](https://github.com/MoonHug-Editor/moonhug/commit/7961536e17bf2fe5c6332d9eeebc142547ee8cc1))
* project_view thumbnails ([50ee18a](https://github.com/MoonHug-Editor/moonhug/commit/50ee18a91cb01be4efba77189fda10c77184d1ff))

## [0.63.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.62.0...v0.63.0) (2026-08-06)

### Features

* apply overrides, project_settings feature ([4e60308](https://github.com/MoonHug-Editor/moonhug/commit/4e6030860b810eb1b27b86b9a9fd6259947133fc))

## [0.62.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.61.0...v0.62.0) (2026-08-04)

### Features

* editor_window feature ([72d59ce](https://github.com/MoonHug-Editor/moonhug/commit/72d59ce746c2cde550ad0741b57d6d5a40ab0caa))
* up to 8 lights rendering ([7d995a3](https://github.com/MoonHug-Editor/moonhug/commit/7d995a3ed6b63554e8ee8f21160ee56b50e3d7a2))

## [0.61.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.60.0...v0.61.0) (2026-08-04)

### Features

* reorder collection elements in inspector by drag ([faed162](https://github.com/MoonHug-Editor/moonhug/commit/faed162dc214904569acc8933a1fb5833479ae15))

## [0.60.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.59.1...v0.60.0) (2026-08-04)

### Features

* simulate playmode in editor ([49a615d](https://github.com/MoonHug-Editor/moonhug/commit/49a615d9f744bfe0b54d356f13963c53ff7b87a2))

### Bug Fixes

* sim_host phase_run ([1089991](https://github.com/MoonHug-Editor/moonhug/commit/1089991a85a29ccbc3558ad815b939684f1ea8bc))

## [0.59.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.59.0...v0.59.1) (2026-08-02)

### Bug Fixes

* inspector UX ([ee359e7](https://github.com/MoonHug-Editor/moonhug/commit/ee359e7adbee3a5baa1ca2f06b18311c5a18312e))

## [0.59.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.58.0...v0.59.0) (2026-08-01)

### Features

* add PrefabsSpec.md ([a447d0f](https://github.com/MoonHug-Editor/moonhug/commit/a447d0ffe43ebe2af2192d9303aac4c677d92602))
* overrides list ([b925bd5](https://github.com/MoonHug-Editor/moonhug/commit/b925bd52d5c3f4211da24ed0ffc60aa5cee9b5d7))

## [0.58.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.57.0...v0.58.0) (2026-08-01)

### Features

* add/remove component on nested scene ([d0fd9c0](https://github.com/MoonHug-Editor/moonhug/commit/d0fd9c0c4820e624282d77f0592c3d606238aef7))
* immediate overrides, rename fixes ([a87a680](https://github.com/MoonHug-Editor/moonhug/commit/a87a680bb557e54eb68116a97b4edf539ed136bd))

### Bug Fixes

* make Ref field open picker on press None ([42b7f10](https://github.com/MoonHug-Editor/moonhug/commit/42b7f10a9d941851b3f712f2aba57c7fb0810c5b))
* menu fix ([30846d5](https://github.com/MoonHug-Editor/moonhug/commit/30846d51a951237065d5eb60b21090bcf9898012))
* revert and reset override fixes ([5ca565d](https://github.com/MoonHug-Editor/moonhug/commit/5ca565d400a7d849e8f05eb147786c703eaf501e))

## [0.57.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.56.0...v0.57.0) (2026-07-30)

### Features

* add physics3d_sample sample package ([8f56faa](https://github.com/MoonHug-Editor/moonhug/commit/8f56faaf53cb68d541b7331f39cd04542f69136e))
* package folder inspector ([8af3c5d](https://github.com/MoonHug-Editor/moonhug/commit/8af3c5dd5ea0070c64d8029d2809e981ea73c7d3))

## [0.56.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.55.0...v0.56.0) (2026-07-30)

### Features

* texture pixels per unit, physics2d_sample package ([5946487](https://github.com/MoonHug-Editor/moonhug/commit/5946487d77ae7eca6da8193a75f0e9fd44a5c7fe))

## [0.55.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.54.0...v0.55.0) (2026-07-29)

### Features

* add view_playable_graph ([64e5d59](https://github.com/MoonHug-Editor/moonhug/commit/64e5d5945f58bdefbc309e33e1f1ad8237cca747))
* change View menu to Window, add shortcuts ([eac9195](https://github.com/MoonHug-Editor/moonhug/commit/eac9195d51920932cce35931aad9dbac3bf8019d))

## [0.54.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.53.0...v0.54.0) (2026-07-28)

### Features

* view_animation tracks and key frames ([b870b33](https://github.com/MoonHug-Editor/moonhug/commit/b870b33a95948ae5e1a55274717f8bf53c9bce0b))

## [0.53.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.52.0...v0.53.0) (2026-07-28)

### Features

* playable graph ([81095d1](https://github.com/MoonHug-Editor/moonhug/commit/81095d181d35c09c479b173a9b6ac479a3219aab))
* view_animation, scrub preview ([a8cd619](https://github.com/MoonHug-Editor/moonhug/commit/a8cd619c0eab1cf49688c08fd0731a7f2e86c1fd))

## [0.52.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.51.0...v0.52.0) (2026-07-25)

### Features

* use *.odin files for run configs ([7ad4b7c](https://github.com/MoonHug-Editor/moonhug/commit/7ad4b7cb5bc85edaf81bd1d45e09376a9c6890ff))

## [0.51.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.50.0...v0.51.0) (2026-07-25)

### Features

* add spectrum theme ([e61c00c](https://github.com/MoonHug-Editor/moonhug/commit/e61c00c97bc6dd5bcde83a7b86cca31c74a60052))
* left aligned input fields ([b911297](https://github.com/MoonHug-Editor/moonhug/commit/b91129718a0fb32cf13d8da10e1aa9e0289fec7a))

### Bug Fixes

* checkmark visible color ([c33663e](https://github.com/MoonHug-Editor/moonhug/commit/c33663ecb4b2f39fdcb744c10b76598b40c7ffe6))
* field label and value size UX ([632275c](https://github.com/MoonHug-Editor/moonhug/commit/632275ce8a2793cfe7dd0eba26fce793846abb14))
* text color in history view ([604c0d2](https://github.com/MoonHug-Editor/moonhug/commit/604c0d29bb29c26713dd339a0dc3b8f933993161))

## [0.50.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.49.0...v0.50.0) (2026-07-25)

### Features

* add decorator_button ([cc38ada](https://github.com/MoonHug-Editor/moonhug/commit/cc38ada652c6476c3cb7fd40cd3db2c6dd702002))
* inspector button improvements ([4cdb8a1](https://github.com/MoonHug-Editor/moonhug/commit/4cdb8a12415172a7f4328137fc30c46589d074d5))

## [0.49.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.48.1...v0.49.0) (2026-07-24)

### Features

* drop incremental local_id in favour of random for better support of merging ([ec8ec30](https://github.com/MoonHug-Editor/moonhug/commit/ec8ec30fb8b1b5c310afb243fad969b7ec95ff39))
* missing components support in inspector ([f77b69e](https://github.com/MoonHug-Editor/moonhug/commit/f77b69e8d7ce7bd945d0d4e166f9d6e5caca360e))

### Bug Fixes

* drop legacy save data, save floats without trailing 0 ([d95d983](https://github.com/MoonHug-Editor/moonhug/commit/d95d983564cda400a5faff214fcd697f101aa67e))
* file_next_local_id grows only for unique local_ids ([30560c1](https://github.com/MoonHug-Editor/moonhug/commit/30560c105756f99ba8d9b9bdea360ede478cf882))
* rebind deleted object id when undo delete ([6c110ec](https://github.com/MoonHug-Editor/moonhug/commit/6c110ec7b3e531940a40b074528c3a21b349970a))
* resolve refs to non-saved objects ([0b3a174](https://github.com/MoonHug-Editor/moonhug/commit/0b3a174a7e7f6e5a11b6a1f1bfe8c455b8be8862))
* unresolved ref fix ([d6b4754](https://github.com/MoonHug-Editor/moonhug/commit/d6b4754f112ee399ddf556f75620006cb9220a70))

## [0.48.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.48.0...v0.48.1) (2026-07-22)

### Bug Fixes

* change import collection ([8b6ad5b](https://github.com/MoonHug-Editor/moonhug/commit/8b6ad5be2c60d1e46fb75d6e906106361c1ecd99))

## [0.48.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.47.1...v0.48.0) (2026-07-22)

### Features

* Animation, AnimationClip.anim, prewired scene extraction from gltf ([2c9694a](https://github.com/MoonHug-Editor/moonhug/commit/2c9694a17432450432f7d15a33ba4b61537b42aa))
* app as package ([78b157d](https://github.com/MoonHug-Editor/moonhug/commit/78b157d848a0e85d2a0f3e91a285bce881613d72))
* scene view flythrough smoothing ([3333a8d](https://github.com/MoonHug-Editor/moonhug/commit/3333a8d58b35259abd7f5bef82d68ec92d49410c))

## [0.47.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.47.0...v0.47.1) (2026-07-20)

### Bug Fixes

* improve grid and snap scene overlay buttons ([e0939ee](https://github.com/MoonHug-Editor/moonhug/commit/e0939ee62b37101b107a6e4fc8ebb237d668be9a))
* use odin build -out instead of odin run to prevent odin process in memory ([930ced8](https://github.com/MoonHug-Editor/moonhug/commit/930ced8ef7fce752dfd26eefe629e8543644b4ca))

## [0.47.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.46.1...v0.47.0) (2026-07-20)

### Features

* wrap input into package ([78327fe](https://github.com/MoonHug-Editor/moonhug/commit/78327fe0fa517d931b9185e14f535805d447db03))

## [0.46.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.46.0...v0.46.1) (2026-07-20)

### Bug Fixes

* make phase Phases work across plugins, replace debug_draw with phase ([34a0299](https://github.com/MoonHug-Editor/moonhug/commit/34a02991046349fb39dd4988295aaf15fcbf643c))

## [0.46.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.45.0...v0.46.0) (2026-07-19)

### Features

* f3 in app to debug draw physics gizmos ([396918b](https://github.com/MoonHug-Editor/moonhug/commit/396918b7761c654e2c8f21781dcc45c753716e33))

### Bug Fixes

* improve scene camera fly-through ([7c49a1c](https://github.com/MoonHug-Editor/moonhug/commit/7c49a1cd59d6142b756efce63c690be8a267afa2))

## [0.45.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.44.0...v0.45.0) (2026-07-19)

### Features

* improve assets menu ([b800d10](https://github.com/MoonHug-Editor/moonhug/commit/b800d10911a0e28a5a8f9110a312bff211e79415))
* plugin tests now are imported to main tests suite, generated by separate prebuild call ([18c0634](https://github.com/MoonHug-Editor/moonhug/commit/18c0634e30a621befc448cb11cfbe782e4bde4ac))

### Bug Fixes

* kinematic and dynamic bodies collision during sync ([016da09](https://github.com/MoonHug-Editor/moonhug/commit/016da095f1b685b12e47c9b02f1208aba715dacb))

## [0.44.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.43.0...v0.44.0) (2026-07-19)

### Features

* add 3D Object menus, scale collider with transform ([1f27645](https://github.com/MoonHug-Editor/moonhug/commit/1f276451e3dba390486da26d2670c8229eaeb201))
* add essentials plugin with meshes, shaders, materials ([fadfa2c](https://github.com/MoonHug-Editor/moonhug/commit/fadfa2c223eef11b68652d77f51fd97309c8403e))
* improve menus ([0e2bc50](https://github.com/MoonHug-Editor/moonhug/commit/0e2bc5035524487f16f054119dacee685de66fc0))

## [0.43.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.42.0...v0.43.0) (2026-07-19)

### Features

* add physics(3d) plugin ([f27ef3a](https://github.com/MoonHug-Editor/moonhug/commit/f27ef3a454a0b311d3e20b445c79b1adbd22da74))
* add physics2d plugin, fixed tick ([97143e9](https://github.com/MoonHug-Editor/moonhug/commit/97143e9eabc6e66c8554df17ea544a254d169a26))
* add plugins feature ([c684149](https://github.com/MoonHug-Editor/moonhug/commit/c6841493a1823cbce9af535d55b039c152380f1d))
* on_draw_gizmos attributes ([627be40](https://github.com/MoonHug-Editor/moonhug/commit/627be40c20f2b618bc992915eec08ba1f8e5a718))
* tests per plugin ([07358ab](https://github.com/MoonHug-Editor/moonhug/commit/07358ab8fe7e5bf884e73c5805b7c0247d67a690))

### Bug Fixes

* cache project dirs for performance ([3d30999](https://github.com/MoonHug-Editor/moonhug/commit/3d309995fd786fbcb024b21a124c8d2b5e521a25))
* compilation fix after odin update ([e0a2e94](https://github.com/MoonHug-Editor/moonhug/commit/e0a2e9490830552b3103adaa8d13e1b8a2363929))

## [0.42.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.41.0...v0.42.0) (2026-07-17)

### Features

* more context menu items in project ([890a9be](https://github.com/MoonHug-Editor/moonhug/commit/890a9be73e3a0cae485e5bcc7a89c07c9ddabd7b))
* multi move and rubber-band select ([6991f02](https://github.com/MoonHug-Editor/moonhug/commit/6991f029064df3c57330c9ec35d41a3d3b788fb3))

## [0.41.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.40.0...v0.41.0) (2026-07-16)

### Features

* input_debug window, apply icon fix ([00409f7](https://github.com/MoonHug-Editor/moonhug/commit/00409f7e625622de556608a05d78cc861a512c87))
* multiselection ([ce14843](https://github.com/MoonHug-Editor/moonhug/commit/ce14843f345d03449435ea4eb7f5e8e5ce911f05))

### Bug Fixes

* improve gizmo ([51b22fe](https://github.com/MoonHug-Editor/moonhug/commit/51b22fe3b02cc9d78962f3631306148440c0fc20))
* make undo work for assets and selection ([eb6c6fb](https://github.com/MoonHug-Editor/moonhug/commit/eb6c6fb5b0a31c8fed634945558776b6b0003c49))

## [0.40.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.39.0...v0.40.0) (2026-07-14)

### Features

* add image based lighting for environment ([6be09e3](https://github.com/MoonHug-Editor/moonhug/commit/6be09e3a62e98f0b90401656606670dfe276fe6a))
* glb extract textures and auto-create .mat ([9130c3e](https://github.com/MoonHug-Editor/moonhug/commit/9130c3e8a7cfade75db82fe93dea0d2cfd2ade13))
* pbr, specular shaders ([10ef134](https://github.com/MoonHug-Editor/moonhug/commit/10ef134f49771d85011f2400d862a12c380f9472))

## [0.39.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.38.0...v0.39.0) (2026-07-14)

### Features

* material in SpriteRenderer ([8671344](https://github.com/MoonHug-Editor/moonhug/commit/86713449a2c2a64ba90baca71a899aa7912c4206))

## [0.38.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.37.0...v0.38.0) (2026-07-13)

### Features

* add directional Light component ([0e6fe16](https://github.com/MoonHug-Editor/moonhug/commit/0e6fe16379cfbf7b533add9e15914136e54359dc))
* custom shaders, material properties ([3d516e5](https://github.com/MoonHug-Editor/moonhug/commit/3d516e5b7f39d7ccf27c312b19b138a789a0df0b))

## [0.37.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.36.0...v0.37.0) (2026-07-13)

### Features

* add material and shader ([284a91a](https://github.com/MoonHug-Editor/moonhug/commit/284a91a00bd8d06738f2210ef18723c7e12e22be))

## [0.36.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.35.0...v0.36.0) (2026-07-13)

### Features

* add snap toolbar ([8906540](https://github.com/MoonHug-Editor/moonhug/commit/890654065aee1575588d2ec8c689bdad0bb02551))
* add sprite sorting group ([30dad9f](https://github.com/MoonHug-Editor/moonhug/commit/30dad9f20293f2fe5f16c07e66ca6a3edcc30a0f))

## [0.35.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.34.0...v0.35.0) (2026-07-12)

### Features

* grid scene toolbar ([cb7c35a](https://github.com/MoonHug-Editor/moonhug/commit/cb7c35a9f957eb3c487cbabcbe170d86c8f8a44e))

## [0.34.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.33.0...v0.34.0) (2026-07-11)

### Features

* added @(scene_toolbar={id="", order=N}) extensibility ([9bf72fb](https://github.com/MoonHug-Editor/moonhug/commit/9bf72fb8f38ae47260cefc79fe0fffe604669fc4))

## [0.33.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.32.0...v0.33.0) (2026-07-11)

### Features

* dock toolbar in scene view ([9a28875](https://github.com/MoonHug-Editor/moonhug/commit/9a28875e5ff35a57e8e4c17aa3e500ee7657ae9e))

### Bug Fixes

* improve gizmo looks ([c10c19e](https://github.com/MoonHug-Editor/moonhug/commit/c10c19eebff5763b5b4c77c9ada334c0a6a26d02))

## [0.32.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.31.0...v0.32.0) (2026-07-11)

### Features

* add glb, gltf mesh import ([5ded605](https://github.com/MoonHug-Editor/moonhug/commit/5ded605dced702570536090588306226b179cd62))
* add MeshRenderer, MeshFilter, cube.glb, ext: extension field tag ([6611216](https://github.com/MoonHug-Editor/moonhug/commit/661121627024c8a9e8be6f8de67b99ac0d22cb45))
* replace raylib with sdl3 ([5f772bf](https://github.com/MoonHug-Editor/moonhug/commit/5f772bf3a593a3d08f41e3217c36147be367090c))
* rotate, scale gizmos ([2c6cd7d](https://github.com/MoonHug-Editor/moonhug/commit/2c6cd7d4537b3b6ffa000724180f52156b9ac7e9))
* scene picking ([b4dc8f1](https://github.com/MoonHug-Editor/moonhug/commit/b4dc8f1f7fa79afc33f2b18c11463b74ea508498))

## [0.31.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.30.0...v0.31.0) (2026-07-10)

### Features

* run app with current open scene state ([da67963](https://github.com/MoonHug-Editor/moonhug/commit/da67963c83b9d859bfe9d8ebeb5a0d5ae838446f))

## [0.30.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.29.0...v0.30.0) (2026-07-10)

### Features

* asset_db auto refresh ([f22a99f](https://github.com/MoonHug-Editor/moonhug/commit/f22a99ff2013cc94b9d16fd355311d827411e78e))
* ref object picker ([15a2b6f](https://github.com/MoonHug-Editor/moonhug/commit/15a2b6f5f0337a18a84dfb1ae8ac8d8dda298550))

### Bug Fixes

* scene variant icon, resizable console subview ([459d4d2](https://github.com/MoonHug-Editor/moonhug/commit/459d4d26ff1349a48ac12643c83fe026176a8453))
* variant overrides regression ([64f44fd](https://github.com/MoonHug-Editor/moonhug/commit/64f44fd53ae7c08f7956e2467c8c6d8f0686ebf5))

## [0.29.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.28.0...v0.29.0) (2026-07-08)

### Features

* console improve ([fa6e9e2](https://github.com/MoonHug-Editor/moonhug/commit/fa6e9e251ea510a1c9de0bae58f1137cc7f1fbb0))

## [0.28.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.27.0...v0.28.0) (2026-07-08)

### Features

* project, hierarchy improvements ([5af7793](https://github.com/MoonHug-Editor/moonhug/commit/5af7793cbdfb57f2013345611226c9fb7325f52e))

### Bug Fixes

* more icons ([26b0bb3](https://github.com/MoonHug-Editor/moonhug/commit/26b0bb3bca0a1d166f81f705ed6c446c846b6161))
* nested scene hash collision protection ([12e44d7](https://github.com/MoonHug-Editor/moonhug/commit/12e44d7ff9ec77a49ef1d0e60958a77fad958e46))

## [0.27.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.26.0...v0.27.0) (2026-07-07)

### Features

* allow components outside engine package ([e1445aa](https://github.com/MoonHug-Editor/moonhug/commit/e1445aad6c1aa193519a1dfa4e106aa76e9f0655))
* project window improvements ([3dc1aeb](https://github.com/MoonHug-Editor/moonhug/commit/3dc1aeb1af5a24bb834fe0aa1c44f672177e7e3f))

## [0.26.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.25.0...v0.26.0) (2026-07-06)

### Features

* add macOS editor icon ([0b0dc04](https://github.com/MoonHug-Editor/moonhug/commit/0b0dc04bafa7de16b1b6cd150e8e9da3903318f0))

## [0.25.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.24.0...v0.25.0) (2026-07-06)

### Features

* add demo menu scene, move files ([8428a1f](https://github.com/MoonHug-Editor/moonhug/commit/8428a1f8835393dff52f13be03435c233abb409b))

## [0.24.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.23.0...v0.24.0) (2026-07-02)

### Features

* improve console messages - add time, code line, icon ([0a7fc62](https://github.com/MoonHug-Editor/moonhug/commit/0a7fc62074e84343fb35885b64acc3c4aa80b3d5))

## [0.23.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.22.0...v0.23.0) (2026-07-01)

### Features

* add Material font icons ([ea9a58f](https://github.com/MoonHug-Editor/moonhug/commit/ea9a58fe3858552c7b21f0f158de2df887967b7f))

## [0.22.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.21.1...v0.22.0) (2026-06-30)

### Features

* up odin-imgui ([69a0ec9](https://github.com/MoonHug-Editor/moonhug/commit/69a0ec96897af3788832e8dc0df425978ec3170e))

## [0.21.1](https://github.com/MoonHug-Editor/moonhug/compare/v0.21.0...v0.21.1) (2026-06-30)

### Bug Fixes

* override/revert in variants ([aedaf2c](https://github.com/MoonHug-Editor/moonhug/commit/aedaf2c8423c2c5bf6e7e53a563083ce72199b15))

## [0.21.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.20.0...v0.21.0) (2026-06-29)

### Features

* prefab variants ([44c621d](https://github.com/MoonHug-Editor/moonhug/commit/44c621da3dbb9c90441077bd3d94c6e99fff7ffe))

## [0.20.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.19.0...v0.20.0) (2026-06-28)

### Features

* apply override to immediate-parent prefab ([ac9246e](https://github.com/MoonHug-Editor/moonhug/commit/ac9246e834220d899fc6d4f60559b86588e62a79))

## [0.19.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.18.0...v0.19.0) (2026-06-21)

### Features

* Ref_Local inspector UX, up readme ([7e03e1e](https://github.com/MoonHug-Editor/moonhug/commit/7e03e1ed71dbadfc02e960cfe04c98359c864e97))
* rewrite prebuild generator ([ac3298b](https://github.com/MoonHug-Editor/moonhug/commit/ac3298bf94408cf26bfaa284e21179b250d38263))

## [0.18.0](https://github.com/MoonHug-Editor/moonhug/compare/v0.17.0...v0.18.0) (2026-05-10)

### Features

* add @(cleanup) attr for external types cleanup ([bc9d31d](https://github.com/MoonHug-Editor/moonhug/commit/bc9d31dcc785d347063f201ee20c140576a20c41))
* deep nested prefabs ([1dac6f5](https://github.com/MoonHug-Editor/moonhug/commit/1dac6f5dab9a206e20f8c3af90f1070af133fc2d))
* squash commit. nested_patch_live_field of target, relies on correct cleanup_T. many fixes ([c7ffab7](https://github.com/MoonHug-Editor/moonhug/commit/c7ffab77e4868eb08137123d05ae708d7cc66242))

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
