package main

import (
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

var (
	setCapsHook    = ui32.NewProc("SetWindowsHookExW")
	removeCapsHook = ui32.NewProc("UnhookWindowsHookEx")
	nextCapsHook   = ui32.NewProc("CallNextHookEx")
	getCapsMessage = ui32.NewProc("GetMessageW")
	postKeyMessage = ui32.NewProc("PostThreadMessageW")
	getKeyThread   = proc32.NewProc("GetCurrentThreadId")
	getModule      = proc32.NewProc("GetModuleHandleW")
)

const (
	wmHotkey          = 0x0312
	capsHookMessageID = 2
)

// RegisterHotKey reserves the shortcut. Intercept only the reserved Caps Lock
// before Windows changes logical capitalization. Keep the hook on its own
// message thread: delivery to Voxt, status I/O and audio cannot stall typing.
type capsListener struct {
	recipient, callback, thread uintptr
	stopped                     chan struct{}
	press                       capsPress // read and written only by the hook thread while installed
}

func (c *capsListener) procedure(code int32, msg uintptr, vk *uint32) uintptr {
	if code == 0 && vk != nil && *vk == vkCapital {
		down := msg == 0x100 || msg == 0x104
		up := msg == 0x101 || msg == 0x105
		if down || up {
			modified := false
			if down && !c.press.down {
				// These are previous modifier transitions; the event in flight is Caps Lock.
				for _, key := range [...]uintptr{0x10, 0x11, 0x12, 0x5b, 0x5c} {
					state, _, _ := keyState.Call(key)
					if state&0x8000 != 0 {
						modified = true
						break
					}
				}
			}
			swallow, fire := c.press.event(down, modified)
			if fire {
				postKeyMessage.Call(c.recipient, wmHotkey, capsHookMessageID, vkCapital<<16)
			}
			if swallow {
				return 1
			}
		}
	}
	next, _, _ := nextCapsHook.Call(0, uintptr(code), msg, uintptr(unsafe.Pointer(vk)))
	return next
}

func (c *capsListener) start() error {
	if c.callback == 0 {
		c.callback = syscall.NewCallback(c.procedure)
	}
	type registration struct {
		thread uintptr
		err    error
	}
	ready := make(chan registration)
	c.stopped = make(chan struct{})
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		defer close(c.stopped)
		var msg winMessage
		peekInput.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0, 0) // Create the thread's queue before publishing its ID.
		thread, _, _ := getKeyThread.Call()
		module, _, _ := getModule.Call(0)
		c.press = capsPress{}
		hook, _, err := setCapsHook.Call(13, c.callback, module, 0) // WH_KEYBOARD_LL
		if hook == 0 {
			ready <- registration{err: fmt.Errorf("Caps Lock SetWindowsHookExW: %w", err)}
			return
		}
		defer removeCapsHook.Call(hook)
		ready <- registration{thread: thread}
		for {
			got, _, _ := getCapsMessage.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
			if int32(got) <= 0 {
				return
			}
		}
	}()
	r := <-ready
	c.thread = r.thread
	if r.err != nil {
		<-c.stopped
	}
	return r.err
}

func (c *capsListener) close() {
	if c.thread == 0 {
		return
	}
	postKeyMessage.Call(c.thread, 0x12, 0, 0) // WM_QUIT
	<-c.stopped
	c.thread = 0
}
