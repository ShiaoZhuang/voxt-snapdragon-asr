// Windows ARM64 input adapter for the Voxt helper protocol.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var ui32 = syscall.NewLazyDLL("user32.dll")
var proc32 = syscall.NewLazyDLL("kernel32.dll")
var registerKey = ui32.NewProc("RegisterHotKey")
var unregisterKey = ui32.NewProc("UnregisterHotKey")
var peekInput = ui32.NewProc("PeekMessageW")
var injectInput = ui32.NewProc("SendInput")
var foreground = ui32.NewProc("GetForegroundWindow")
var threadPID = ui32.NewProc("GetWindowThreadProcessId")
var threadInfo = ui32.NewProc("GetGUIThreadInfo")
var keyState = ui32.NewProc("GetAsyncKeyState")
var windowClass = ui32.NewProc("GetClassNameW")
var windowStyle = ui32.NewProc("GetWindowLongW")

type keyCall struct {
	config *keyConfig
	answer chan map[string]any
}
type windowsInput struct {
	calls   chan keyCall
	done    chan struct{}
	stopped chan struct{}
}
type winMessage struct {
	window         uintptr
	message        uint32
	wparam, lparam uintptr
	time           uint32
	x, y           int32
	private        uint32
}
type frontApp struct {
	PID      uint32 `json:"pid"`
	Name     string `json:"name,omitempty"`
	BundleID string `json:"bundleId,omitempty"`
}

func frontWindow() (uintptr, uintptr, frontApp) {
	hwnd, _, _ := foreground.Call()
	var pid uint32
	tid, _, _ := threadPID.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
	app := frontApp{PID: pid}
	handle, _, _ := proc32.NewProc("OpenProcess").Call(0x1000, 0, uintptr(pid))
	if handle != 0 {
		defer proc32.NewProc("CloseHandle").Call(handle)
		buf := make([]uint16, 1024)
		n := uint32(len(buf))
		ok, _, _ := proc32.NewProc("QueryFullProcessImageNameW").Call(handle, 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&n)))
		if ok != 0 {
			app.Name = filepath.Base(syscall.UTF16ToString(buf[:n]))
			app.BundleID = strings.ToLower(app.Name)
		}
	}
	return hwnd, tid, app
}

func newInput(notify func(string, any)) *windowsInput {
	w := &windowsInput{make(chan keyCall), make(chan struct{}), make(chan struct{})}
	go w.watch(notify)
	return w
}

func (w *windowsInput) watch(notify func(string, any)) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer close(w.stopped)
	timer := time.NewTicker(20 * time.Millisecond)
	defer timer.Stop()
	const id = 1
	var current shortcut
	statusFile := os.Getenv("VOXT_WINDOWS_HOTKEY_STATUS")
	thread, _, _ := getKeyThread.Call()
	caps := capsListener{recipient: thread}
	var first winMessage
	peekInput.Call(uintptr(unsafe.Pointer(&first)), 0, 0, 0, 0)
	defer caps.close()
	var sequence uint64
	var generation int64
	var count int
	var problem string
	defer unregisterKey.Call(0, id)
	for {
		select {
		case <-w.done:
			return
		case req := <-w.calls:
			c := req.config
			if c != nil && (c.Sequence == 0 || c.Sequence >= sequence) {
				sequence, generation = c.Sequence, c.Generation
				bound, requested := transcribeShortcut(c.Bindings)
				if current != bound {
					if current.key != 0 {
						caps.close()
						unregisterKey.Call(0, id)
					}
					current = shortcut{}
				}
				problem = ""
				if current.key == 0 && bound.key != 0 {
					ok, _, err := registerKey.Call(0, id, bound.modifiers, bound.key)
					if ok == 0 {
						code, _ := err.(syscall.Errno)
						problem = fmt.Sprintf("%s RegisterHotKey(vk=0x%02X, modifiers=0x%04X): Win32 error %d: %v", bound.name, bound.key, bound.modifiers, code, err)
					} else {
						current = bound
						if bound.key == vkCapital {
							if hookErr := caps.start(); hookErr != nil {
								unregisterKey.Call(0, id)
								current = shortcut{}
								problem = hookErr.Error()
							}
						}
					}
				}
				if requested && bound.key == 0 {
					problem = "Set Transcribe to Caps Lock or Ctrl+Alt+Space (tap)."
				}
				if requested {
					state := registrationStatus{Installed: current.key != 0, Binding: bound.name, Error: problem}
					if err := writeHotkeyStatus(statusFile, state); err != nil {
						fmt.Fprintln(os.Stderr, "hotkey status file:", err)
					}
					if problem != "" {
						fmt.Fprintln(os.Stderr, "hotkey:", problem)
					}
				}
			}
			n := 0
			if current.key != 0 {
				n = 1
			}
			req.answer <- map[string]any{"installed": n != 0, "accessibility": true, "bindings": n, "events": count, "error": problem}
		case <-timer.C:
			var msg winMessage
			for {
				ok, _, _ := peekInput.Call(uintptr(unsafe.Pointer(&msg)), 0, 0x312, 0x312, 1)
				if ok == 0 {
					break
				}
				source := uintptr(id)
				if current.key == vkCapital {
					source = capsHookMessageID
				}
				if current.key == 0 || msg.wparam != source || msg.lparam>>16 != current.key {
					continue
				}
				_, _, front := frontWindow()
				count++
				notify("hotkey.event", map[string]any{"binding": current.id, "generation": generation, "behavior": "tap", "phase": "trigger", "front": front})
			}
		}
	}
}

type guiThreadInfo struct {
	size, flags                               uint32
	active, focus, capture, menu, move, caret uintptr
	rect                                      [4]int32
}

func focused(tid uintptr) (uintptr, bool) {
	var info guiThreadInfo
	info.size = uint32(unsafe.Sizeof(info))
	ok, _, _ := threadInfo.Call(tid, uintptr(unsafe.Pointer(&info)))
	if ok == 0 || info.focus == 0 {
		return 0, false
	}
	var class [128]uint16
	windowClass.Call(info.focus, uintptr(unsafe.Pointer(&class[0])), uintptr(len(class)))
	name := strings.ToLower(syscall.UTF16ToString(class[:]))
	style, _, _ := windowStyle.Call(info.focus, uintptr(uint32(0xfffffff0)))
	return info.focus, (name == "edit" || strings.HasPrefix(name, "richedit")) && style&0x20 != 0
}

// INPUT has an 8-byte header and a 32-byte union on Windows ARM64.
type unicodeInput struct {
	kind, pad                   uint32
	key, scan                   uint16
	flags, timestamp, alignment uint32
	extra                       uintptr
	tail                        [8]byte
}

func insertAtTarget(text string, target uint32) (frontApp, error) {
	hwnd, tid, app := frontWindow()
	focus, password := focused(tid)
	if target != 0 && target != app.PID || hwnd == 0 || focus == 0 || password {
		return app, errors.New("foreground target unavailable")
	}
	if text == "" {
		return app, errors.New("empty transcription")
	}
	for _, key := range []uintptr{0x11, 0x12, 0x5b, 0x5c} {
		state, _, _ := keyState.Call(key)
		if state&0x8000 != 0 {
			return app, errors.New("release keyboard modifiers before inserting")
		}
	}
	units := utf16.Encode([]rune(strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\n", "\r")))
	inputs := make([]unicodeInput, 0, 2*len(units))
	for _, u := range units {
		inputs = append(inputs, unicodeInput{kind: 1, scan: u, flags: 4}, unicodeInput{kind: 1, scan: u, flags: 6})
	}
	now, _, _ := foreground.Call()
	current, secure := focused(tid)
	if now != hwnd || current != focus || secure {
		return app, errors.New("focus changed")
	}
	n, _, err := injectInput.Call(uintptr(len(inputs)), uintptr(unsafe.Pointer(&inputs[0])), unsafe.Sizeof(inputs[0]))
	runtime.KeepAlive(inputs)
	if int(n) != len(inputs) {
		return app, fmt.Errorf("SendInput submitted %d/%d events: %v", n, len(inputs), err)
	}
	return app, nil
}

func (w *windowsInput) handle(method string, params json.RawMessage) (any, bool, error) {
	switch method {
	case "hotkey.configure", "hotkey.status":
		req := keyCall{answer: make(chan map[string]any, 1)}
		if method == "hotkey.configure" {
			var c keyConfig
			if err := json.Unmarshal(params, &c); err != nil {
				return nil, true, err
			}
			req.config = &c
		}
		select {
		case w.calls <- req:
			return <-req.answer, true, nil
		case <-w.stopped:
			return nil, true, errors.New("helper stopped")
		}
	case "app.frontmost":
		_, _, app := frontWindow()
		return app, true, nil
	case "textio.focus":
		_, tid, app := frontWindow()
		focus, password := focused(tid)
		result := map[string]any{"pid": app.PID, "app": app, "editable": focus != 0 && !password}
		if password {
			result["subrole"] = "AXSecureTextField"
		}
		return result, true, nil
	case "textio.paste":
		var p struct {
			Text      string
			TargetPID uint32
			Press     []json.RawMessage
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, true, err
		}
		start := time.Now()
		app, err := insertAtTarget(p.Text, p.TargetPID)
		result := map[string]any{"posted": err == nil, "front": app, "pressSkipped": len(p.Press) > 0, "check": "unknown", "ms": time.Since(start).Milliseconds()}
		if err != nil {
			result["error"] = err.Error()
		}
		return result, true, nil
	}
	return nil, false, nil
}
func (w *windowsInput) close() { close(w.done); <-w.stopped }
