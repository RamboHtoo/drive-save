"""GPS quality gates shared by the offline Mazda5 estimator."""

from datetime import datetime, timezone
import math

import numpy as np

METERS_PER_MILE = 1609.344
MAX_DURATION_S = 7200
MAX_SAMPLES = 30000
MAX_EDGE_GAP_S = 3.0
MAX_INTERIOR_GAP_S = 3.0
MIN_DIRECT_COVERAGE = 0.95
SCORING_WINDOW_POLICY = "observed-gps-window-v1"


class TraceError(ValueError):
    """Expected invalid or insufficient observations, safe to expose as a reason code."""


def finite_number(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def timestamp(value):
    try:
        dt = value if isinstance(value, datetime) else datetime.fromisoformat(value.replace("Z", "+00:00"))
        if dt.tzinfo is None or dt.utcoffset() is None:
            raise ValueError()
        return dt.timestamp()
    except (AttributeError, TypeError, ValueError, OverflowError) as exc:
        raise TraceError("invalid_timezone_timestamp") from exc


def prepare_trace(samples, trip):
    start, end = timestamp(trip.get("started_at")), timestamp(trip.get("ended_at"))
    duration = end - start
    distance = trip.get("distance_mi")
    if not finite_number(distance) or distance <= 0:
        raise TraceError("invalid_distance")
    if not 3 <= duration <= MAX_DURATION_S:
        raise TraceError("duration_out_of_bounds")
    if not isinstance(samples, list) or not 2 <= len(samples) <= MAX_SAMPLES:
        raise TraceError("sample_count_out_of_bounds")
    rows, seen_seq, seen_time = [], set(), set()
    for sample in samples:
        if not isinstance(sample, dict):
            raise TraceError("invalid_sample")
        seq = sample.get("sample_seq")
        if type(seq) is not int or seq < 0 or seq in seen_seq:
            raise TraceError("invalid_or_duplicate_sequence")
        seen_seq.add(seq)
        t = timestamp(sample.get("ts")) - start
        if t < 0 or t > duration or t in seen_time:
            raise TraceError("out_of_trip_or_duplicate_timestamp")
        seen_time.add(t)
        v, accuracy = sample.get("speed_mps"), sample.get("speed_accuracy_mps")
        valid = (finite_number(v) and 0 <= v <= 53.6448 and
                 finite_number(accuracy) and 0 <= accuracy <= 2)
        rows.append((t, v, valid))
    rows.sort(key=lambda r: r[0])
    good = [(t, v) for t, v, valid in rows if valid]
    if len(good) < 2:
        raise TraceError("insufficient_valid_speed")
    t, v = np.array(good, dtype=float).T
    # Session buttons and CLLocation observations have independent timestamps.
    # Price only the observed window, without inventing boundary speeds. Keep
    # offsets relative to the original session so event timestamps stay aligned.
    leading, trailing = float(t[0]), float(duration - t[-1])
    if max(leading, trailing) > MAX_EDGE_GAP_S + 1e-6:
        raise TraceError("gps_boundary_gap_over_three_seconds")
    scoring_duration = float(t[-1] - t[0])
    if scoring_duration < 3:
        raise TraceError("scoring_window_too_short")
    gaps = np.diff(t)
    if np.max(gaps) > MAX_INTERIOR_GAP_S + 1e-6:
        raise TraceError("gps_gap_over_three_seconds")
    # Each observation supports at most one second until the next observation.
    # Interpolated gaps AND both unobserved edges count against coverage of the
    # original session. Trimming cannot turn a poorly recorded trip into 100%.
    coverage = float(np.minimum(gaps, 1).sum() / duration)
    if coverage < MIN_DIRECT_COVERAGE - 1e-9:
        raise TraceError("valid_time_coverage_below_95_percent")
    if np.max(np.abs(np.diff(v) / gaps)) > 1.5 * 9.80665:
        raise TraceError("implausible_speed_change")
    # Preserve observation knots as well as 1 Hz points; otherwise resampling
    # can erase a fractional-second turn in the trace or hide a speed spike.
    grid = np.unique(np.r_[t, np.arange(t[0], t[-1], 1.0)])
    speed = np.interp(grid, t, v)
    if np.max(np.abs(np.diff(speed) / np.diff(grid))) > 1.5 * 9.80665:
        raise TraceError("implausible_speed_change")
    integrated_mi = float(np.trapezoid(speed, grid) / METERS_PER_MILE)
    if integrated_mi <= 0 or abs(integrated_mi - distance) / distance > 0.10 + 1e-9:
        raise TraceError("distance_mismatch_over_10_percent")
    return grid, speed, {
        "input_sample_count": len(samples), "valid_sample_count": len(good),
        "direct_time_coverage": coverage, "max_gap_seconds": float(np.max(gaps)),
        "integrated_distance_mi": integrated_mi, "reported_distance_mi": distance,
        "duration_seconds": duration,
        "scoring_window_policy": SCORING_WINDOW_POLICY,
        "scoring_start_s": leading, "scoring_end_s": float(t[-1]),
        "scoring_started_at": datetime.fromtimestamp(start + t[0], timezone.utc).isoformat(),
        "scoring_ended_at": datetime.fromtimestamp(start + t[-1], timezone.utc).isoformat(),
        "scoring_duration_seconds": scoring_duration,
        "unobserved_start_seconds": leading, "unobserved_end_seconds": trailing,
        "window_trimmed": leading > 0 or trailing > 0,
    }
