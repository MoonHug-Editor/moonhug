package inspector

// The types plugins declare, installed or not (plugin_types_generated.odin,
// from plugin_types_gen). They name a type whose plugin is not installed: the
// inspector's Missing Component row shows the type and the plugin instead of
// a guid.

Plugin_Type :: struct {
	guid:   string,
	name:   string, // the type
	plugin: string, // the plugin or sample declaring it
}

// The type a guid names, when some plugin on disk declares it.
plugin_type_of_guid :: proc(guid: string) -> (Plugin_Type, bool) {
	for t in plugin_types do if t.guid == guid do return t, true
	return {}, false
}
