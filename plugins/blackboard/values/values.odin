package blackboard_values

// What a package that adds a value type to Blackboard entries imports: this
// package, never the blackboard plugin's root, since the root's generated
// union imports that package back. The import also marks the package as
// needing the blackboard plugin, so prebuild leaves it out while the plugin
// is not installed (docs/core/Plugins.md, integration subpackages).
//
//   import _ "moonhug:packages/blackboard/values"
//
//   @(typ_guid={guid = "..."})
//   @(blackboard_value={name = "Team"})
//   Team :: enum u8 { Red, Blue }

// A type an entry can hold, and the name the inspector lists it by.
Value_Type :: struct {
	type: typeid,
	name: string,
}
