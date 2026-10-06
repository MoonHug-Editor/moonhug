package scene_undo

// The engine side of undo under one name at the call site: this package
// re-exports the shell
// stack (moonhug:editor/undo) and adds the engine's recording helpers, so
// engine-side code and plugin editors import this package alone, as
// `import undo "moonhug:packages/engine/editor/undo"`, and write
// undo.push, undo.record_create and undo.group_begin as one API. Same shape
// as plugins/engine/core_exports.odin. Package names are unique program-wide, so the
// package is scene_undo and the import alias gives it the undo name. Variables
// are not aliasable, the shell undo exposes none.

import shell "moonhug:editor/undo"
import "moonhug:packages/engine/editor/undo_ops"

Doc_Kind                        :: shell.Doc_Kind
Edit_Scope                      :: shell.Edit_Scope
Edit_Session                    :: shell.Edit_Session
Edit_Target                     :: shell.Edit_Target
Entry                           :: shell.Entry
Group_Command                   :: shell.Group_Command
Group_Scope                     :: shell.Group_Scope
Inspector_Owner                 :: shell.Inspector_Owner
MAX_ENTRIES                     :: shell.MAX_ENTRIES
Owner_Kind                      :: shell.Owner_Kind
Property_Target                 :: shell.Property_Target
Scene_Ref                       :: shell.Scene_Ref
Selection_Command               :: shell.Selection_Command
Selection_Scene_Item            :: shell.Selection_Scene_Item
Selection_State                 :: shell.Selection_State
Target_Resolver                 :: shell.Target_Resolver
Undo_Stack                      :: shell.Undo_Stack
Value_Command                   :: shell.Value_Command
abort_group_command             :: shell.abort_group_command
activity_consume                :: shell.activity_consume
activity_take                   :: shell.activity_take
amend_top_selection             :: shell.amend_top_selection
apply_Group_Command             :: shell.apply_Group_Command
apply_Selection_Command         :: shell.apply_Selection_Command
apply_Value_Command             :: shell.apply_Value_Command
apply_redo                      :: shell.apply_redo
apply_undo                      :: shell.apply_undo
asset_path                      :: shell.asset_path
assets_Group_Command            :: shell.assets_Group_Command
assets_Value_Command            :: shell.assets_Value_Command
begin_group_command             :: shell.begin_group_command
can_redo                        :: shell.can_redo
can_undo                        :: shell.can_undo
capture_json                    :: shell.capture_json
clear                           :: shell.clear
current_owner                   :: shell.current_owner
describe_Group_Command          :: shell.describe_Group_Command
describe_Selection_Command      :: shell.describe_Selection_Command
describe_Value_Command          :: shell.describe_Value_Command
destroy                         :: shell.destroy
destroy_Group_Command           :: shell.destroy_Group_Command
destroy_Selection_Command       :: shell.destroy_Selection_Command
destroy_Value_Command           :: shell.destroy_Value_Command
edit_begin                      :: shell.edit_begin
edit_cancel                     :: shell.edit_cancel
edit_component_base             :: shell.edit_component_base
edit_component_begin            :: shell.edit_component_begin
edit_end                        :: shell.edit_end
edit_inspector_field_begin      :: shell.edit_inspector_field_begin
edit_pooled_begin               :: shell.edit_pooled_begin
edit_raw_begin                  :: shell.edit_raw_begin
edit_session_abandon            :: shell.edit_session_abandon
edit_session_abort              :: shell.edit_session_abort
edit_session_active             :: shell.edit_session_active
edit_session_begin              :: shell.edit_session_begin
edit_session_end                :: shell.edit_session_end
edit_target_asset               :: shell.edit_target_asset
edit_target_pooled              :: shell.edit_target_pooled
edit_target_transform           :: shell.edit_target_transform
edit_target_whole               :: shell.edit_target_whole
edit_transform_begin            :: shell.edit_transform_begin
end_group_command               :: shell.end_group_command
entries                         :: shell.entries
get                             :: shell.get
group_abort                     :: shell.group_abort
group_begin                     :: shell.group_begin
group_commit                    :: shell.group_commit
group_end                       :: shell.group_end
init                            :: shell.init
inspector_shutdown              :: shell.inspector_shutdown
install                         :: shell.install
is_applying                     :: shell.is_applying
jump_to                         :: shell.jump_to
label_Group_Command             :: shell.label_Group_Command
label_Selection_Command         :: shell.label_Selection_Command
label_Value_Command             :: shell.label_Value_Command
make_asset_target               :: shell.make_asset_target
make_component_target           :: shell.make_component_target
make_pooled_target              :: shell.make_pooled_target
make_raw_target                 :: shell.make_raw_target
make_transform_target           :: shell.make_transform_target
object_name                     :: shell.object_name
play_begin                      :: shell.play_begin
play_end                        :: shell.play_end
pooled_owner                    :: shell.pooled_owner
pop_owner                       :: shell.pop_owner
purge_asset                     :: shell.purge_asset
purge_scenes                    :: shell.purge_scenes
push                            :: shell.push
push_asset_owner                :: shell.push_asset_owner
push_component_owner            :: shell.push_component_owner
push_owner                      :: shell.push_owner
push_pooled_owner               :: shell.push_pooled_owner
push_raw_owner                  :: shell.push_raw_owner
push_selection                  :: shell.push_selection
push_transform_owner            :: shell.push_transform_owner
push_value                      :: shell.push_value
record_selection_snapshot       :: shell.record_selection_snapshot
resolve_component_base          :: shell.resolve_component_base
resolve_pooled_base             :: shell.resolve_pooled_base
resolve_target_ptr              :: shell.resolve_target_ptr
revert_Group_Command            :: shell.revert_Group_Command
revert_Selection_Command        :: shell.revert_Selection_Command
revert_Value_Command            :: shell.revert_Value_Command
scene_alive                     :: shell.scene_alive
scene_mark_dirty                :: shell.scene_mark_dirty
scene_name                      :: shell.scene_name
scenes_Group_Command            :: shell.scenes_Group_Command
scenes_Selection_Command        :: shell.scenes_Selection_Command
scenes_Value_Command            :: shell.scenes_Value_Command
selection_state_destroy         :: shell.selection_state_destroy
selection_state_equal           :: shell.selection_state_equal
set_asset_apply                 :: shell.set_asset_apply
set_asset_doc_lookup            :: shell.set_asset_doc_lookup
set_recording                   :: shell.set_recording
set_selection_hooks             :: shell.set_selection_hooks
set_stack_slot                  :: shell.set_stack_slot
set_target_resolver             :: shell.set_target_resolver
target_name                     :: shell.target_name
top_index                       :: shell.top_index
write_json_value                :: shell.write_json_value

// Scene lookups the engine commands use, for tests and tools.
scene_find_transform_by_local_id :: undo_ops.scene_find_transform_by_local_id
scene_find_component_by_local_id :: undo_ops.scene_find_component_by_local_id
