package main

import (
	"encoding/binary"
	"fmt"
	"math"
	"time"
)

type captureParams struct {
	Devices                      []string
	SampleRate, FrameMS, LevelHz int
	MaxSeconds                   float64
}

func (p *captureParams) defaults() error {
	if p.SampleRate == 0 {
		p.SampleRate = 16000
	}
	if p.FrameMS == 0 {
		p.FrameMS = 100
	}
	if p.LevelHz == 0 {
		p.LevelHz = 20
	}
	if p.SampleRate < 8000 || p.SampleRate > 192000 || p.FrameMS < 1 || p.FrameMS > 1000 || p.LevelHz < 1 || p.LevelHz > 100 || p.MaxSeconds < 0 || p.MaxSeconds > 86400 {
		return fmt.Errorf("unsupported capture sample rate, frame length, meter rate or duration")
	}
	return nil
}

type deviceInfo struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Channels   int    `json:"channels"`
	SampleRate int    `json:"sampleRate"`
	Default    bool   `json:"default"`
}

type captureStream struct {
	job                                         string
	p                                           captureParams
	device                                      deviceInfo
	start                                       time.Time
	notify                                      func(string, any)
	buf                                         []byte
	frames, samples, metered                    int
	meterSquared, meterPeak, peak, firstFrameMS float64
	started                                     bool
}

func dbfs(v float64) float64 {
	if v < 0.000001 {
		return -120
	}
	return 20 * math.Log10(v)
}

func (s *captureStream) appendPCM(data []byte) {
	if len(data) == 0 {
		return
	}
	if !s.started {
		s.started = true
		fellBack := len(s.p.Devices) != 0 && s.p.Devices[0] != s.device.ID
		started := map[string]any{"job": s.job, "device": s.device.ID, "deviceName": s.device.Name, "fellBack": fellBack, "deviceSampleRate": s.device.SampleRate, "deviceChannels": s.device.Channels, "sampleRate": s.p.SampleRate, "startMs": float64(time.Since(s.start).Microseconds()) / 1000}
		if fellBack {
			started["fallbackReason"] = "preferred microphone unavailable"
		}
		s.notify("capture.started", started)
	}
	frameBytes := 2 * (s.p.SampleRate * s.p.FrameMS / 1000)
	levelInterval := s.p.SampleRate / s.p.LevelHz
	for i := 0; i+1 < len(data); i += 2 {
		v := float64(int16(binary.LittleEndian.Uint16(data[i:]))) / 32768
		s.meterSquared += v * v
		s.meterPeak = math.Max(s.meterPeak, math.Abs(v))
		s.peak = math.Max(s.peak, math.Abs(v))
		s.metered++
		s.buf = append(s.buf, data[i], data[i+1])
		if len(s.buf) == frameBytes {
			s.flush()
		}
		if s.metered == levelInterval {
			s.notify("capture.level", map[string]any{"job": s.job, "seconds": float64(s.samples+len(s.buf)/2) / float64(s.p.SampleRate), "rms": dbfs(math.Sqrt(s.meterSquared / float64(s.metered))), "peak": dbfs(s.meterPeak)})
			s.metered, s.meterSquared, s.meterPeak = 0, 0, 0
		}
	}
}

func (s *captureStream) flush() {
	if len(s.buf) == 0 {
		return
	}
	s.notify("capture.pcm", map[string]any{"job": s.job, "seq": s.frames, "offset": s.samples, "data": s.buf})
	if s.frames == 0 {
		s.firstFrameMS = float64(time.Since(s.start).Microseconds()) / 1000
	}
	s.frames++
	s.samples += len(s.buf) / 2
	s.buf = s.buf[:0]
}

func (s *captureStream) result(reason string, cpuSeconds float64) any {
	s.flush()
	return map[string]any{"device": s.device.ID, "reason": reason, "frames": s.frames, "samples": s.samples, "seconds": float64(s.samples) / float64(s.p.SampleRate), "restarts": 0, "peak": dbfs(s.peak), "firstFrameMs": s.firstFrameMS, "cpuSeconds": cpuSeconds}
}
