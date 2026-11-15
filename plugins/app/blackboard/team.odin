package app_blackboard

// What the app adds to the blackboard plugin: a Team an entry can hold, so a
// squad's Blackboard names the team its members are on.

import _ "moonhug:packages/blackboard/values"

@(typ_guid={guid = "ca247118-e740-4d93-9ad5-6532e61ec6b7"})
@(blackboard_value={name = "Team"})
Team :: enum u8 {
	Red,
	Blue,
}
