package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

func microphoneConsent(root syscall.Handle, subkey string) string {
	path, _ := syscall.UTF16PtrFromString(subkey)
	var key syscall.Handle
	if syscall.RegOpenKeyEx(root, path, 0, syscall.KEY_QUERY_VALUE, &key) != nil {
		return ""
	}
	defer syscall.RegCloseKey(key)
	name, _ := syscall.UTF16PtrFromString("Value")
	var buffer [32]uint16
	var kind uint32
	size := uint32(unsafe.Sizeof(buffer))
	if syscall.RegQueryValueEx(key, name, nil, &kind, (*byte)(unsafe.Pointer(&buffer[0])), &size) != nil || kind != syscall.REG_SZ {
		return ""
	}
	return strings.ToLower(syscall.UTF16ToString(buffer[:]))
}

func microphonePermission() string {
	const consent = `SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone`
	for _, entry := range []struct {
		root syscall.Handle
		path string
	}{
		{syscall.HKEY_LOCAL_MACHINE, consent}, {syscall.HKEY_CURRENT_USER, consent}, {syscall.HKEY_CURRENT_USER, consent + `\NonPackaged`},
	} {
		if microphoneConsent(entry.root, entry.path) == "deny" {
			return "denied"
		}
	}
	// Unpackaged desktop apps may capture by default. WASAPI is authoritative
	// and capture.start returns permission_denied if policy refuses the request.
	return "granted"
}

func permissions(name string) (any, error) {
	access := microphonePermission()
	switch name {
	case "", "accessibility":
	case "microphone":
		if access == "denied" {
			cmd := exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", "ms-settings:privacy-microphone")
			if err := cmd.Start(); err != nil {
				return nil, err
			}
			go cmd.Wait()
		}
	default:
		return nil, &wireError{Code: "unsupported", Message: "permission unavailable", Data: map[string]string{"capability": name}}
	}
	return map[string]string{"microphone": access, "accessibility": "granted"}, nil
}

func main() {
	s := server{out: json.NewEncoder(os.Stdout), record: recordMicrophone, devices: listMicrophones, permissions: permissions}
	s.input = newInput(s.notify)
	s.serve(os.Stdin)
}
