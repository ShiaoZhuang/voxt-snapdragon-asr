package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"testing"
	"time"
)

func TestCaptureFramingAndStopOrder(t *testing.T) {
	var output bytes.Buffer
	ready := make(chan struct{})
	s := server{out: json.NewEncoder(&output)}
	// Feed 85 PCM16 samples in two differently sized WASAPI packets. The
	// protocol must emit an 80-sample frame and a five-sample tail on stop.
	pcm := make([]byte, 170)
	for i := 0; i < len(pcm); i += 2 {
		binary.LittleEndian.PutUint16(pcm[i:], uint16(32000-i))
	}
	s.record = func(id string, p captureParams, stop <-chan string, notify func(string, any)) (any, error) {
		stream := captureStream{job: id, p: p, start: time.Now(), device: deviceInfo{ID: "default", Name: "input", SampleRate: 48000, Channels: 2}, notify: notify}
		stream.appendPCM(pcm[:34])
		stream.appendPCM(pcm[34:])
		close(ready)
		return stream.result(<-stop, 0.01), nil
	}
	s.dispatch(request{ID: "pre", Method: "capture.start"})
	s.dispatch(request{ID: "hello", Method: "helper.hello", Params: json.RawMessage(`{"protocol":1}`)})
	s.dispatch(request{ID: "record", Method: "capture.start", Params: json.RawMessage(`{"sampleRate":8000,"frameMs":10,"levelHz":100}`)})
	<-ready
	s.dispatch(request{ID: "busy", Method: "capture.start"})
	s.dispatch(request{ID: "stop", Method: "capture.stop", Params: json.RawMessage(`{"job":"record"}`)})
	s.dispatch(request{ID: "again", Method: "capture.stop", Params: json.RawMessage(`{"job":"record"}`)})
	var packets []byte
	var methods []string
	var frames int
	var results []string
	decoder := json.NewDecoder(&output)
	for decoder.More() {
		var m struct {
			ID, Method string
			Params     struct {
				Job, Data   string
				Seq, Offset int
				Peak        float64
			}
			Result struct {
				Frames, Samples int
				Stopped         bool
				Reason          string
			}
			Error *wireError
		}
		if err := decoder.Decode(&m); err != nil {
			t.Fatal(err)
		}
		switch m.ID {
		case "pre", "busy":
			expect := map[string]string{"pre": "not_initialized", "busy": "busy"}[m.ID]
			if m.Error == nil || m.Error.Code != expect {
				t.Fatalf("%s error: %+v", m.ID, m.Error)
			}
		case "record":
			if m.Result.Frames != 2 || m.Result.Samples != 85 || m.Result.Reason != "stopped" {
				t.Fatalf("result: %+v", m.Result)
			}
			results = append(results, m.ID)
		case "stop", "again":
			if m.Result.Stopped != (m.ID == "stop") {
				t.Fatalf("%s result %+v", m.ID, m.Result)
			}
			results = append(results, m.ID)
		}
		if m.Method == "" {
			continue
		}
		if m.Params.Job != "record" {
			t.Fatalf("undeliverable notification: %+v", m)
		}
		methods = append(methods, m.Method)
		if m.Method == "capture.pcm" {
			b, err := base64.StdEncoding.DecodeString(m.Params.Data)
			if err != nil {
				t.Fatal(err)
			}
			if m.Params.Seq != frames || m.Params.Offset != len(packets)/2 {
				t.Fatalf("discontinuous seq=%d, offset=%d", m.Params.Seq, m.Params.Offset)
			}
			packets = append(packets, b...)
			frames++
		}
	}
	if !bytes.Equal(pcm, packets) || len(methods) != 4 || methods[0] != "capture.started" || methods[2] != "capture.level" {
		t.Fatalf("stream mismatch: %v, %d PCM bytes", methods, len(packets))
	}
	if len(results) != 3 || results[0] != "record" || results[1] != "stop" || results[2] != "again" {
		t.Fatalf("response order: %v", results)
	}
}

func TestCancelWaitsForRecording(t *testing.T) {
	var out bytes.Buffer
	s := server{out: json.NewEncoder(&out), initialized: true, record: func(id string, p captureParams, stop <-chan string, notify func(string, any)) (any, error) {
		return nil, &wireError{Code: <-stop, Message: "recording cancelled"}
	}}
	s.dispatch(request{ID: "record", Method: "capture.start"})
	s.dispatch(request{ID: "cancel", Method: "job.cancel", Params: json.RawMessage(`{"job":"record"}`)})
	d := json.NewDecoder(&out)
	var a, b struct {
		ID     string
		Error  *wireError
		Result struct{ Cancelled bool }
	}
	if err := d.Decode(&a); err != nil {
		t.Fatal(err)
	}
	if err := d.Decode(&b); err != nil {
		t.Fatal(err)
	}
	if a.ID != "record" || a.Error == nil || a.Error.Code != "cancelled" || b.ID != "cancel" || !b.Result.Cancelled {
		t.Fatalf("unexpected cancellation: %s %s", a.ID, b.ID)
	}
}
