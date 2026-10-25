from copy import deepcopy
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path

import numpy as np
import pytest

from drive_save_model import estimate_trip, reference_profile, scoring_config
from drive_save_model.physics import (brake_scenario, acceleration_scenario, fuel_per_meter,
    road_load, high_speed_scenario, diagnostic_cycle_fuel, MPH_TO_MPS, G)
from drive_save_model.trace import prepare_trace
from drive_save_model.validation import example_payload, payload_from_trace, cruise_payload, validation_report, four_player_demo


@pytest.fixture
def payload():
    return example_payload()


def test_source_profile_and_hashes():
    p = reference_profile()
    assert p['fuel_economy_vehicle_id'] == 31284
    assert p['mass_kg'] == pytest.approx(1700.9713875)
    assert p['road_load_si']['a_n'] == pytest.approx(151.50198)
    assert p['city_mpg'] == 21 and p['highway_mpg'] == 28
    root = Path(__file__).resolve().parents[2] / 'drive_save_model/data'
    for a in json.loads((root/'sources.json').read_text())['assets']:
        assert hashlib.sha256((root/a['file']).read_bytes()).hexdigest() == a['sha256']
    assert road_load(10, p) == road_load(10, {**p, 'road_load_si': dict(reversed(list(p['road_load_si'].items())))})


def test_independent_notion_civic_arithmetic():
    # Published worked example, independently calculated from its SI coefficients.
    p = {'mass_kg':1474.2, 'rated_horsepower':200,
         'road_load_si':{'a_n':112.45, 'b_n_per_mps':1.2916, 'c_n_per_mps2':.38863}}
    b = brake_scenario(34*.44704, 12*.44704, 3, p)
    assert b['extra_cruise_distance_m'] == pytest.approx(175.3846, abs=.001)
    assert b['fuel_gal']*4.284 == pytest.approx(.0080131, abs=1e-6)
    h = high_speed_scenario(np.array([0, 480]), np.array([75*.44704]*2), [], p)
    assert h['fuel_gal']*4.284 == pytest.approx(.19494, abs=1e-5)
    assert h['uninterrupted_time_difference_s'] == pytest.approx(73.846153846)
    a = acceleration_scenario(8*.44704, 27*.44704, 3.5, .33, p)
    assert a['fuel_gal'] == 0
    p['rated_horsepower'] = 150
    assert acceleration_scenario(8*.44704, 27*.44704, 3.5, .33, p)['fuel_gal'] > 0


def test_receipt_reconciles_without_adding_penalties_to_budget(payload):
    r = estimate_trip(**payload)
    assert r['status'] == 'scored', r
    assert len(r['model_details']['events']) == 3
    assert r['avoidable_usd'] == pytest.approx(sum(e['cost_usd'] for e in r['model_details']['events']) + r['model_details']['high_speed']['cost_usd'])
    assert r['estimated_trip_cost_usd'] == pytest.approx(r['fuel_gal']*3.5)
    assert r['reference_fuel_gal'] is None
    assert r['model_details']['events'][0]['cost_usd'] < .01
    assert r['model_details']['validation_status'] == 'laboratory_validation_pending'
    json.dumps(r, allow_nan=False)


@pytest.mark.parametrize('mph', [0.1, 25, 65])
def test_complete_no_event_trace_can_be_zero(mph):
    r = estimate_trip(**cruise_payload(mph))
    assert r['status'] == 'scored' and r['avoidable_usd'] == 0


def test_high_speed_increases_and_boundary_segments_split():
    p = reference_profile()
    t, v = np.array([0., 10.]), np.array([75*.44704]*2)
    full = high_speed_scenario(t, v, [], p)
    half = high_speed_scenario(t, v, [(2.5,7.5)], p)
    assert half['fuel_gal'] == pytest.approx(full['fuel_gal']/2)
    assert high_speed_scenario(t, v, [(0,10)], p)['fuel_gal'] == 0
    assert high_speed_scenario(t, np.array([80*.44704]*2), [], p)['fuel_gal'] > full['fuel_gal']


def test_idle_and_deceleration_are_distinct():
    p = reference_profile()
    assert diagnostic_cycle_fuel(np.array([0,60]), np.array([0,0]), p) == pytest.approx(.25/60)
    assert diagnostic_cycle_fuel(np.array([0,2]), np.array([20,10]), p) == 0
    with pytest.raises(ValueError):
        fuel_per_meter(0, p)


@pytest.mark.parametrize('bad', [None, -1, float('nan'), float('inf'), True])
def test_invalid_speed_is_unknown(payload, bad):
    for s in payload['speed_samples'][40:50]: s['speed_mps'] = bad
    r = estimate_trip(**payload)
    assert r['status'] == 'insufficient_data' and r['avoidable_usd'] is None


@pytest.mark.parametrize('mutation,reason', [
    (lambda p:p['speed_samples'].pop(), 'missing_boundary_speed'),
    (lambda p:p['speed_samples'].append(p['speed_samples'][5].copy()), 'invalid_or_duplicate_sequence'),
    (lambda p:p['trip_metadata'].update(distance_mi=100), 'distance_mismatch_over_10_percent'),
    (lambda p:p['trip_metadata'].update(is_demo=False), 'experimental_model_requires_demo_mode'),
    (lambda p:p['vehicle_profile'].update(id='other'), 'unsupported_vehicle_profile'),
    (lambda p:p['scoring_config'].update(model_version='other'), 'scoring_config_mismatch'),
    (lambda p:p.pop('events'), 'missing_or_invalid_events'),
    (lambda p:p['trip_metadata'].update(events_complete=False), 'event_recording_incomplete'),
    (lambda p:p['trip_metadata'].pop('detector_version'), 'missing_detector_version'),
    (lambda p:p['events'][0].pop('duration_s'), 'invalid_event_duration'),
    (lambda p:p['events'][0].update(duration_s=float('nan')), 'invalid_event_duration'),
    (lambda p:p['events'][0].update(peak_g=0.01), 'event_peak_inconsistent_with_speed'),
    (lambda p:p['events'][0].update(speed_after_mph=None), 'missing_or_invalid_event_speed'),
    (lambda p:p['events'][0].update(speed_before_mph=90), 'event_speed_disagrees_with_trace'),
    (lambda p:p['events'][0].update(detector_version='missing'), 'event_detector_version_mismatch'),
    (lambda p:p['events'].append(deepcopy(p['events'][0])), 'duplicate_event_id'),
])
def test_rejection(payload, mutation, reason):
    mutation(payload)
    r = estimate_trip(**payload)
    assert r['quality_flags'] == [reason]
    assert r['fuel_gal'] is None and r['avoidable_usd'] is None


def test_short_gap_allowed_but_sparse_trace_rejected(payload):
    del payload['speed_samples'][40:42]
    assert estimate_trip(**payload)['status'] == 'scored'
    p = cruise_payload()
    p['speed_samples'] = p['speed_samples'][::2]
    assert estimate_trip(**p)['quality_flags'] == ['valid_time_coverage_below_95_percent']


def test_missing_braking_history(payload):
    start = datetime.fromisoformat(payload['trip_metadata']['started_at'])
    p = payload
    p['trip_metadata']['started_at'] = (start+timedelta(seconds=25)).isoformat()
    p['speed_samples'] = p['speed_samples'][25:]
    p['trip_metadata']['distance_mi'] -= 25*34*.44704/1609.344
    assert estimate_trip(**p)['quality_flags'] == ['missing_braking_comparison_history']


def test_overlap_rejected_even_when_no_event_dollars(payload):
    p = payload
    e = deepcopy(p['events'][2]); e.update(event_id='00000000-0000-0000-0000-000000000001')
    p['events'].append(e)
    assert estimate_trip(**p)['quality_flags'] == ['overlapping_event_comparisons']


def test_actual_cruise_history_required(payload):
    for s in payload['speed_samples'][20:25]: s['speed_mps'] = 10
    assert estimate_trip(**payload)['quality_flags'] == ['braking_cruise_scenario_unsupported']


def test_fractional_trace_and_bad_timestamps():
    p = payload_from_trace(np.arange(9)*.9, np.array([0,1,3,5,7,6,4,1,0]))
    t, _, _ = prepare_trace(p['speed_samples'],p['trip_metadata'])
    assert t[-1] == pytest.approx(7.2)
    p['trip_metadata']['started_at'] = '2026-10-19T12:00:00'
    assert estimate_trip(**p)['quality_flags'] == ['invalid_timezone_timestamp']


def test_price_and_model_config_immutable(payload):
    assert scoring_config(4,price_as_of='2026-10-24') == scoring_config(4.,price_as_of='2026-10-24')
    with pytest.raises(ValueError, match='six decimal'):
        scoring_config(3.1234567, price_as_of='2026-10-24')
    r = estimate_trip(**payload)
    payload['scoring_config'] = scoring_config(7, price_as_of='2026-10-24')
    assert estimate_trip(**payload)['avoidable_usd'] == pytest.approx(r['avoidable_usd']*2)


def test_validation_reports_errors_without_claiming_pass():
    r = validation_report()
    assert not r['release_gate_passed'] and not r['calibration_applied']
    assert [v['published_lab_mpg'] for v in r['laboratory_comparisons']] == [40.3,24.2]
    assert r['event_savings_accuracy'] == 'unverified'
    assert estimate_trip(**example_payload('udds'))['quality_flags'] == ['event_recording_incomplete']


def test_demo_computes_rankings():
    rows = four_player_demo()['standings']
    assert [r['rank'] for r in rows] == [1,2,3,4]
    assert rows[0]['improvement_pct'] == pytest.approx(100)
    assert rows[-1]['improvement_pct'] == pytest.approx(0)
    for r in rows:
        assert r['est_savings_usd'] == pytest.approx(r['baseline_usd_per_mile']*r['later_distance_mi'] - r['receipt']['avoidable_usd'])


def test_migration_receipt_matches_canonical():
    root = Path(__file__).resolve().parents[2]
    def receipt(path):
        return path.read_text().split('CREATE OR REPLACE FUNCTION public.drive_save_receipt',1)[1].split('$$;',1)[0]
    assert receipt(root/'analytics/queries.sql') == receipt(root/'analytics/migrations/004_mazda_math_model.sql')
