package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"runtime"
	"sync"
)

type request struct {
	ID, Method string
	Params     json.RawMessage
}
type wireError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func (e *wireError) Error() string { return e.Message }

type inputHandler interface {
	handle(string, json.RawMessage) (any, bool, error)
	close()
}

type captureJob struct {
	id   string
	stop chan string
	done chan struct{}
}

type server struct {
	out         *json.Encoder
	writeMu     sync.Mutex
	input       inputHandler
	initialized bool
	job         *captureJob
	record      func(string, captureParams, <-chan string, func(string, any)) (any, error)
	devices     func() ([]deviceInfo, error)
	permissions func(string) (any, error)
}

func (s *server) write(v any) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.out.Encode(v)
}

func (s *server) notify(method string, params any) {
	s.write(map[string]any{"method": method, "params": params})
}

func (s *server) reply(id string, result any, err error) {
	if err != nil {
		var failure *wireError
		if !errors.As(err, &failure) {
			failure = &wireError{Code: "internal", Message: err.Error()}
		}
		s.write(map[string]any{"id": id, "error": failure})
		return
	}
	if result == nil {
		result = struct{}{}
	}
	s.write(map[string]any{"id": id, "result": result})
}

func (s *server) stop(id, reason string) bool {
	if s.job == nil || s.job.id != id {
		return false
	}
	select {
	case <-s.job.done:
		return false
	case s.job.stop <- reason:
		<-s.job.done
		return true
	}
}

func (s *server) dispatch(r request) bool {
	if len(r.Params) == 0 {
		r.Params = json.RawMessage(`{}`)
	}
	bad := func(message string) { s.reply(r.ID, nil, &wireError{Code: "bad_request", Message: message}) }
	if !s.initialized && r.Method != "helper.hello" {
		s.reply(r.ID, nil, &wireError{Code: "not_initialized", Message: "helper.hello is required"})
		return true
	}
	switch r.Method {
	case "helper.hello":
		var p struct{ Protocol int }
		if err := json.Unmarshal(r.Params, &p); err != nil {
			bad(err.Error())
			break
		}
		if p.Protocol != 1 {
			s.reply(r.ID, nil, &wireError{Code: "protocol_mismatch", Message: "expected protocol 1", Data: map[string]any{"supported": []int{1}}})
			break
		}
		s.initialized = true
		methods := []string{"helper.hello", "helper.shutdown", "job.cancel", "permissions.status", "permissions.request", "capture.devices", "capture.start", "capture.stop", "hotkey.configure", "hotkey.status", "textio.focus", "textio.paste", "app.frontmost", "app.configure"}
		s.reply(r.ID, map[string]any{"protocol": 1, "version": "1.0", "pid": os.Getpid(), "methods": methods, "device": map[string]string{"name": "Windows " + runtime.GOARCH, "os": "Windows"}}, nil)
	case "helper.shutdown":
		if s.job != nil {
			s.stop(s.job.id, "cancelled")
		}
		s.reply(r.ID, nil, nil)
		return false
	case "capture.devices":
		devs, err := s.devices()
		s.reply(r.ID, map[string]any{"devices": devs}, err)
	case "permissions.status", "permissions.request":
		var p struct{ Permission string }
		if err := json.Unmarshal(r.Params, &p); err != nil {
			bad(err.Error())
			break
		}
		if r.Method == "permissions.request" && p.Permission == "" {
			bad("missing permission")
			break
		}
		result, err := s.permissions(p.Permission)
		s.reply(r.ID, result, err)
	case "capture.start":
		if s.job != nil {
			select {
			case <-s.job.done:
			default:
				s.reply(r.ID, nil, &wireError{Code: "busy", Message: "microphone already recording"})
				return true
			}
		}
		var p captureParams
		if err := json.Unmarshal(r.Params, &p); err != nil {
			bad(err.Error())
			break
		}
		if err := p.defaults(); err != nil {
			bad(err.Error())
			break
		}
		job := &captureJob{id: r.ID, stop: make(chan string), done: make(chan struct{})}
		s.job = job
		go func() {
			defer close(job.done)
			result, err := s.record(job.id, p, job.stop, s.notify)
			s.reply(job.id, result, err)
		}()
	case "job.cancel", "capture.stop":
		var p struct{ Job string }
		if err := json.Unmarshal(r.Params, &p); err != nil || p.Job == "" {
			bad("missing job id")
			break
		}
		reason, key := "stopped", "stopped"
		if r.Method == "job.cancel" {
			reason, key = "cancelled", "cancelled"
		}
		s.reply(r.ID, map[string]bool{key: s.stop(p.Job, reason)}, nil)
	case "app.configure":
		s.reply(r.ID, nil, nil)
	default:
		result, handled, err := s.input.handle(r.Method, r.Params)
		if !handled {
			err = &wireError{Code: "method_not_found", Message: "unknown helper method: " + r.Method}
		}
		s.reply(r.ID, result, err)
	}
	return true
}

func (s *server) serve(in io.Reader) {
	defer s.input.close()
	scan := bufio.NewScanner(in)
	scan.Buffer(make([]byte, 65536), 4<<20)
	for scan.Scan() {
		var r request
		if json.Unmarshal(scan.Bytes(), &r) != nil || r.ID == "" || r.Method == "" {
			continue
		}
		if !s.dispatch(r) {
			return
		}
	}
	if s.job != nil {
		s.stop(s.job.id, "cancelled")
	}
}
