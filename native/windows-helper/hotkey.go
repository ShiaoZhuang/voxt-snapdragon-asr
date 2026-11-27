package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

type binding struct {
	ID        string
	Key       *int
	Modifiers map[string]string
	Behavior  string
}
type keyConfig struct {
	Sequence   uint64
	Generation int64
	Bindings   []binding
}

type shortcut struct {
	id, name       string
	key, modifiers uintptr
}

const (
	vkCapital   = 0x14
	modNoRepeat = 0x4000
)

func transcribeShortcut(bindings []binding) (shortcut, bool) {
	var requested bool
	for _, b := range bindings {
		if !strings.HasPrefix(b.ID, "transcribe/") {
			continue
		}
		requested = true
		if b.Key == nil || b.Behavior != "tap" {
			continue
		}
		switch *b.Key {
		case 57:
			if len(b.Modifiers) == 0 {
				return shortcut{b.ID, "Caps Lock", vkCapital, modNoRepeat}, true
			}
		case 49:
			if len(b.Modifiers) == 2 && b.Modifiers["control"] != "" && b.Modifiers["option"] != "" {
				return shortcut{b.ID, "Ctrl+Alt+Space", 0x20, modNoRepeat | 3}, true
			}
		}
	}
	return shortcut{}, requested
}

// Preserve the decision taken on the first Caps Lock down until key-up.
// Repeats and changes to modifiers during a press cannot start a second job.
type capsPress struct{ down, claimed bool }

func (p *capsPress) event(down, modified bool) (swallow, trigger bool) {
	if !down {
		swallow = p.claimed
		*p = capsPress{}
		return swallow, false
	}
	if p.down {
		return p.claimed, false
	}
	p.down, p.claimed = true, !modified
	return p.claimed, p.claimed
}

type registrationStatus struct {
	Installed bool   `json:"installed"`
	Error     string `json:"error"`
	Binding   string `json:"binding"`
}

// A launcher may read this while the helper reconfigures during dictation.
func writeHotkeyStatus(path string, status registrationStatus) error {
	if path == "" {
		return nil
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".voxt-hotkey-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	err = json.NewEncoder(f).Encode(status)
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}
