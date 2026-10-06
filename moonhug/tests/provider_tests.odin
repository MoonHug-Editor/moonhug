package tests

// editor/provider: a provider struct is absent or complete, a partly filled
// one is named field by field.

import "core:testing"
import "moonhug:editor/provider"

_Probe :: struct {
	a:     proc(),
	b:     proc(x: int) -> int,
	label: string, // not a proc, never reported
}

@(test)
test_provider_missing_fields_names_the_nil_procs :: proc(t: ^testing.T) {
	p: _Probe
	missing, total := provider.missing_fields({name = "Probe", ptr = &p, ti = type_info_of(_Probe)})
	testing.expect_value(t, total, 2)
	testing.expect_value(t, len(missing), 2)
	p.a = proc() {}
	missing, total = provider.missing_fields({name = "Probe", ptr = &p, ti = type_info_of(_Probe)})
	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "Probe.b")
	p.b = proc(x: int) -> int { return x }
	missing, _ = provider.missing_fields({name = "Probe", ptr = &p, ti = type_info_of(_Probe)})
	testing.expect_value(t, len(missing), 0)
}
