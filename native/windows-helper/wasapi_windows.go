package main

import (
	"errors"
	"fmt"
	"runtime"
	"syscall"
	"time"
	"unsafe"
)

// All endpoint and stream interfaces are used and released on their owning COM thread.
var (
	audioOLE          = syscall.NewLazyDLL("ole32.dll")
	audioInitialize   = audioOLE.NewProc("CoInitializeEx")
	audioUninitialize = audioOLE.NewProc("CoUninitialize")
	audioCreate       = audioOLE.NewProc("CoCreateInstance")
	audioFree         = audioOLE.NewProc("CoTaskMemFree")
	audioVariantClear = audioOLE.NewProc("PropVariantClear")
	audioStringLength = syscall.NewLazyDLL("kernel32.dll").NewProc("lstrlenW")
	classEnumerator   = syscall.GUID{Data1: 0xbcde0395, Data2: 0xe52f, Data3: 0x467c, Data4: [8]byte{0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}}
	iidEnumerator     = syscall.GUID{Data1: 0xa95664d2, Data2: 0x9614, Data3: 0x4f35, Data4: [8]byte{0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}}
	iidAudioClient    = syscall.GUID{Data1: 0x1cb9ad4c, Data2: 0xdbfa, Data3: 0x4c32, Data4: [8]byte{0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}}
	iidCapture        = syscall.GUID{Data1: 0xc8adbd64, Data2: 0xe71e, Data3: 0x48a0, Data4: [8]byte{0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17}}
	friendlyNameKey   = struct {
		Format syscall.GUID
		ID     uint32
	}{syscall.GUID{Data1: 0xa45c254e, Data2: 0xdf1c, Data3: 0x4efd, Data4: [8]byte{0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14}
)

type audioError uint32

func (e audioError) Error() string { return fmt.Sprintf("Windows audio HRESULT 0x%08X", uint32(e)) }
func checkAudio(result uintptr) error {
	if int32(result) < 0 {
		return audioError(result)
	}
	return nil
}

type audioInterface struct{ methods *[32]uintptr }

//go:uintptrescapes
func (p *audioInterface) call(slot int, arguments ...uintptr) error {
	args := append([]uintptr{uintptr(unsafe.Pointer(p))}, arguments...)
	hr, _, _ := syscall.SyscallN(p.methods[slot], args...)
	runtime.KeepAlive(p)
	return checkAudio(hr)
}

func (p *audioInterface) release() {
	if p != nil {
		p.call(2)
	}
}

func audioThread(fn func(*audioInterface) error) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	hr, _, _ := audioInitialize.Call(0, 2) // COINIT_APARTMENTTHREADED, on a dedicated thread.
	if err := checkAudio(hr); err != nil {
		return err
	}
	defer audioUninitialize.Call()
	var enumerator *audioInterface
	hr, _, _ = audioCreate.Call(uintptr(unsafe.Pointer(&classEnumerator)), 0, 1, uintptr(unsafe.Pointer(&iidEnumerator)), uintptr(unsafe.Pointer(&enumerator)))
	if err := checkAudio(hr); err != nil {
		return err
	}
	defer enumerator.release()
	return fn(enumerator)
}

func deviceString(p *uint16) string {
	if p == nil {
		return ""
	}
	length, _, _ := audioStringLength.Call(uintptr(unsafe.Pointer(p)))
	return syscall.UTF16ToString(unsafe.Slice(p, int(length)))
}

func deviceID(device *audioInterface) (string, error) {
	var p *uint16
	if err := device.call(5, uintptr(unsafe.Pointer(&p))); err != nil {
		return "", err
	} // IMMDevice::GetId
	defer audioFree.Call(uintptr(unsafe.Pointer(p)))
	return deviceString(p), nil
}

func deviceName(device *audioInterface) string {
	var store *audioInterface
	if err := device.call(4, 0, uintptr(unsafe.Pointer(&store))); err != nil {
		return "Microphone"
	} // OpenPropertyStore
	defer store.release()
	var value struct {
		Kind     uint16
		Reserved [3]uint16
		Text     *uint16
		Extra    uintptr
	}
	if err := store.call(5, uintptr(unsafe.Pointer(&friendlyNameKey)), uintptr(unsafe.Pointer(&value))); err != nil {
		return "Microphone"
	}
	defer audioVariantClear.Call(uintptr(unsafe.Pointer(&value)))
	if value.Kind == 31 && value.Text != nil {
		return deviceString(value.Text)
	} // VT_LPWSTR
	return "Microphone"
}

type waveFormat struct {
	Tag, Channels           uint16
	Rate, BytesPerSecond    uint32
	BlockAlign, Bits, Extra uint16
}

func audioClient(device *audioInterface) (*audioInterface, error) {
	var client *audioInterface
	err := device.call(3, uintptr(unsafe.Pointer(&iidAudioClient)), 1, 0, uintptr(unsafe.Pointer(&client))) // IMMDevice::Activate
	return client, err
}

func mixFormat(client *audioInterface) (waveFormat, error) {
	var f *waveFormat
	if err := client.call(8, uintptr(unsafe.Pointer(&f))); err != nil {
		return waveFormat{}, err
	} // IAudioClient::GetMixFormat
	defer audioFree.Call(uintptr(unsafe.Pointer(f)))
	return *f, nil
}

func defaultMic(enumerator *audioInterface) (*audioInterface, error) {
	var device *audioInterface
	err := enumerator.call(4, 1, 0, uintptr(unsafe.Pointer(&device))) // GetDefaultAudioEndpoint(eCapture, eConsole)
	return device, err
}

func listMicrophones() ([]deviceInfo, error) {
	devices := []deviceInfo{}
	err := audioThread(func(enumerator *audioInterface) error {
		defaultID := ""
		if dev, err := defaultMic(enumerator); err == nil {
			defaultID, _ = deviceID(dev)
			dev.release()
		}
		var collection *audioInterface
		if err := enumerator.call(3, 1, 1, uintptr(unsafe.Pointer(&collection))); err != nil {
			return err
		} // EnumAudioEndpoints: active capture endpoints
		defer collection.release()
		var count uint32
		if err := collection.call(3, uintptr(unsafe.Pointer(&count))); err != nil {
			return err
		}
		for i := uint32(0); i < count; i++ {
			var device *audioInterface
			if err := collection.call(4, uintptr(i), uintptr(unsafe.Pointer(&device))); err != nil {
				continue
			}
			id, err := deviceID(device)
			if err == nil {
				info := deviceInfo{ID: id, Name: deviceName(device), Default: id == defaultID}
				if client, err := audioClient(device); err == nil {
					if f, err := mixFormat(client); err == nil {
						info.SampleRate = int(f.Rate)
						info.Channels = int(f.Channels)
					}
					client.release()
				}
				devices = append(devices, info)
			}
			device.release()
		}
		return nil
	})
	return devices, err
}

type microphone struct {
	client, capture *audioInterface
	info            deviceInfo
}

func openMicrophone(device *audioInterface, sampleRate int) (*microphone, error) {
	id, err := deviceID(device)
	if err != nil {
		return nil, err
	}
	client, err := audioClient(device)
	if err != nil {
		return nil, err
	}
	keep := false
	defer func() {
		if !keep {
			client.release()
		}
	}()
	mix, err := mixFormat(client)
	if err != nil {
		return nil, err
	}
	want := waveFormat{Tag: 1, Channels: 1, Rate: uint32(sampleRate), BytesPerSecond: uint32(2 * sampleRate), BlockAlign: 2, Bits: 16}
	// Shared mode SRC and channel matrix convert the microphone mix to mono PCM16.
	const autoConvertPCM = 0x80000000
	const defaultSRCQuality = 0x08000000
	if err := client.call(3, 0, autoConvertPCM|defaultSRCQuality, 1000000, 0, uintptr(unsafe.Pointer(&want)), 0); err != nil {
		return nil, err
	}
	var capture *audioInterface
	if err := client.call(14, uintptr(unsafe.Pointer(&iidCapture)), uintptr(unsafe.Pointer(&capture))); err != nil {
		return nil, err
	} // GetService
	if err := client.call(10); err != nil {
		capture.release()
		return nil, err
	} // Start
	keep = true
	return &microphone{client, capture, deviceInfo{ID: id, Name: deviceName(device), SampleRate: int(mix.Rate), Channels: int(mix.Channels)}}, nil
}

func selectMic(enumerator *audioInterface, p captureParams) (*microphone, error) {
	for _, id := range p.Devices {
		key, err := syscall.UTF16PtrFromString(id)
		if err != nil {
			continue
		}
		var device *audioInterface
		if err = enumerator.call(5, uintptr(unsafe.Pointer(key)), uintptr(unsafe.Pointer(&device))); err != nil {
			continue
		}
		mic, err := openMicrophone(device, p.SampleRate)
		device.release()
		if err == nil {
			return mic, nil
		}
	}
	device, err := defaultMic(enumerator)
	if err != nil {
		return nil, err
	}
	defer device.release()
	return openMicrophone(device, p.SampleRate)
}

func (m *microphone) close() {
	m.client.call(11) // Stop
	m.capture.release()
	m.client.release()
}

func (m *microphone) packet() ([]byte, error) {
	var frames, flags uint32
	if err := m.capture.call(5, uintptr(unsafe.Pointer(&frames))); err != nil {
		return nil, err
	} // GetNextPacketSize
	if frames == 0 {
		return nil, nil
	}
	var raw *byte
	if err := m.capture.call(3, uintptr(unsafe.Pointer(&raw)), uintptr(unsafe.Pointer(&frames)), uintptr(unsafe.Pointer(&flags)), 0, 0); err != nil {
		return nil, err
	} // GetBuffer
	data := make([]byte, 2*int(frames))
	if flags&2 == 0 && raw != nil {
		copy(data, unsafe.Slice(raw, len(data)))
	} // AUDCLNT_BUFFERFLAGS_SILENT
	return data, m.capture.call(4, uintptr(frames)) // ReleaseBuffer
}

func processCPU() float64 {
	h, _ := syscall.GetCurrentProcess()
	var c, e, k, u syscall.Filetime
	if syscall.GetProcessTimes(h, &c, &e, &k, &u) != nil {
		return 0
	}
	ticks := func(t syscall.Filetime) uint64 { return uint64(t.HighDateTime)<<32 | uint64(t.LowDateTime) }
	return float64(ticks(k)+ticks(u)) / 1e7
}

func captureFailure(err error) error {
	if errors.Is(err, audioError(0x80070005)) {
		return &wireError{Code: "permission_denied", Message: "Windows denied microphone access", Data: map[string]string{"permission": "microphone"}}
	}
	return &wireError{Code: "device_unavailable", Message: err.Error()}
}

func recordMicrophone(job string, p captureParams, stop <-chan string, notify func(string, any)) (any, error) {
	start := time.Now()
	cpu := processCPU()
	s := captureStream{job: job, p: p, start: start, notify: notify}
	reason := "stopped"
	err := audioThread(func(enumerator *audioInterface) error {
		mic, err := selectMic(enumerator, p)
		if err != nil {
			return err
		}
		defer mic.close()
		s.device = mic.info
		tick := time.NewTicker(5 * time.Millisecond)
		defer tick.Stop()
		lastPacket := time.Now()
		for {
			select {
			case reason = <-stop:
			case <-tick.C:
				reason = ""
			}
			if reason == "cancelled" {
				return nil
			}
			// Drain buffered samples on stop before reporting the final partial frame.
			for {
				data, err := mic.packet()
				if err != nil {
					if !s.started {
						return err
					}
					reason = "deviceLost"
					return nil
				}
				if len(data) == 0 {
					break
				}
				if p.MaxSeconds > 0 {
					left := int(float64(p.SampleRate)*p.MaxSeconds) - s.samples - len(s.buf)/2
					if len(data)/2 >= left {
						data = data[:2*max(left, 0)]
						reason = "maxSeconds"
					}
				}
				s.appendPCM(data)
				lastPacket = time.Now()
				if reason == "maxSeconds" {
					break
				}
			}
			if reason != "" {
				return nil
			}
			if time.Since(lastPacket) > 2*time.Second {
				if !s.started {
					return fmt.Errorf("microphone delivered no WASAPI packets within two seconds")
				}
				reason = "noCallback"
				return nil
			}
		}
	})
	if err != nil {
		return nil, captureFailure(err)
	}
	if reason == "cancelled" {
		return nil, &wireError{Code: "cancelled", Message: "recording cancelled"}
	}
	return s.result(reason, processCPU()-cpu), nil
}
