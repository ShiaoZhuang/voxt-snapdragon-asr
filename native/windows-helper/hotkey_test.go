package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestVoxtShortcutWire(t *testing.T) {
	cases := []struct {
		bindings, want string
		vk, flags      uintptr
		requested      bool
	}{
		{`[{"id":"finish","key":36,"modifiers":{},"behavior":"tap"},{"id":"transcribe/0","key":57,"modifiers":{},"behavior":"tap"}]`, "Caps Lock", 0x14, 0x4000, true},
		{`[{"id":"transcribe/0","key":49,"modifiers":{"control":"any","option":"any"},"behavior":"tap"}]`, "Ctrl+Alt+Space", 0x20, 0x4003, true},
		{`[{"id":"transcribe/0","key":57,"modifiers":{"control":"any"},"behavior":"tap"}]`, "", 0, 0, true},
		{`[{"id":"transcribe/0","key":57,"modifiers":{},"behavior":"longPress"}]`, "", 0, 0, true},
		{`[]`, "", 0, 0, false},
	}
	for _, tc := range cases {
		var config keyConfig
		if err := json.Unmarshal([]byte(`{"generation":2,"sequence":4,"bindings":`+tc.bindings+`}`), &config); err != nil {
			t.Fatal(err)
		}
		got, requested := transcribeShortcut(config.Bindings)
		if requested != tc.requested || got.name != tc.want || got.key != tc.vk || got.modifiers != tc.flags {
			t.Fatalf("binding %s got %+v requested %v", tc.bindings, got, requested)
		}
		if got.key != 0 && got.id != "transcribe/0" {
			t.Fatalf("wrong wire binding %s", got.id)
		}
	}
}

func TestHeldCapsAndModifiedCaps(t *testing.T) {
	var key capsPress
	events := []struct{ down, modified, swallow, fire bool }{
		{true, false, true, true},                             // first recording
		{true, false, true, false}, {true, true, true, false}, // held through modifier change
		{false, true, true, false},
		{true, false, true, true}, {false, false, true, false}, // finish recording
		{true, true, false, false}, {true, false, false, false}, {false, false, false, false}, // Shift+Caps, then release Shift first
		{true, false, true, true}, {false, false, true, false},
	}
	for i, e := range events {
		got, fire := key.event(e.down, e.modified)
		if got != e.swallow || fire != e.fire {
			t.Fatalf("event %d: swallow %v, fire %v", i, got, fire)
		}
	}
}

func TestRegistrationStatusReplacement(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "hotkey.json")
	for _, want := range []registrationStatus{{false, "Win32 error 1409", "Caps Lock"}, {true, "", "Caps Lock"}} {
		if err := writeHotkeyStatus(path, want); err != nil {
			t.Fatal(err)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var got registrationStatus
		if err := json.Unmarshal(data, &got); err != nil || got != want {
			t.Fatalf("status %s, error %v", data, err)
		}
	}
	list, err := os.ReadDir(dir)
	if err != nil || len(list) != 1 {
		t.Fatalf("temporary status retained: %v %v", list, err)
	}
}
