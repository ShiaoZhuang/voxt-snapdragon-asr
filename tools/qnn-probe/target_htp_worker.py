"""Run a single Target replay graph in its own QNN process."""

from pathlib import Path
import sys
import time


def main(model, request, profile, result):
    phase_file = profile.with_suffix(".phase.txt")
    partial_phase = phase_file.with_suffix(".tmp")
    current_phase = ""

    def phase(name):
        nonlocal current_phase
        current_phase = name
        partial_phase.write_text(name + "\n", encoding="utf-8")
        partial_phase.replace(phase_file)

    phase("import QNN runtime")
    import numpy as np
    import onnxruntime as ort
    import onnxruntime_qnn as qnn

    from projection import QNN_PROVIDER, htp_execute_events, htp_session_options

    with np.load(request, allow_pickle=False) as data:
        feeds = {name: data[name] for name in data.files}

    phase("register QNN provider")
    ort.register_execution_provider_library(QNN_PROVIDER, qnn.get_library_path())
    session = options = devices = None
    failed_phase = None
    try:
        phase("configure QNN session")
        options, run_options, devices = htp_session_options(qnn, profile)
        phase("initialize QNN session")
        session = ort.InferenceSession(str(model), sess_options=options, enable_fallback=False)
        if QNN_PROVIDER not in session.get_providers():
            raise RuntimeError(f"QNN provider was not selected: {session.get_providers()}")

        phase("execute HTP warmup")
        session.run(None, feeds, run_options)
        phase("execute timed HTP runs")
        times = []
        for _ in range(3):
            start = time.perf_counter()
            output, = session.run(None, feeds, run_options)
            times.append((time.perf_counter() - start) * 1000)
        phase("collect QAIRT profile")
        events = htp_execute_events(session.end_profiling())
        partial = result.with_suffix(".partial.npz")
        np.savez(partial, output=output, median_ms=float(np.median(times)), events=events)
        partial.replace(result)
    except Exception:
        failed_phase = current_phase
        raise
    finally:
        phase("release QNN session")
        del session, options, devices
        phase("unregister QNN provider")
        ort.unregister_execution_provider_library(QNN_PROVIDER)
        if failed_phase:
            phase(failed_phase)
    phase("complete")


if __name__ == "__main__":
    main(*(Path(value) for value in sys.argv[1:]))
