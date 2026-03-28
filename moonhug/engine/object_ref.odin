package engine

import "core:encoding/uuid"

Local_ID :: distinct i64
Asset_GUID :: distinct uuid.Identifier

// Persistent pointer — survives serialization/reload
// guid == 0 is in same file (local). guid != 0 is cross-asset
PPtr :: struct {
    local_id : Local_ID,
    guid : Asset_GUID,
}

// reference to local object
Ref_Local :: struct {
    local_id : Local_ID,
    handle : Handle `json:"-"`,
}

// reference to local or cross-asset object
Ref :: struct {
    pptr: PPtr,
    handle : Handle `json:"-"`,
}

Owned :: distinct Ref_Local
