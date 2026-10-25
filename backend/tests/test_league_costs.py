"""Disposable-database regression tests for the weekly cost contract."""
from datetime import timedelta
from uuid import UUID, uuid4
import pytest
from fastapi.testclient import TestClient
from conftest import query
from main import app
from services.league_demo import week_start
from test_api import new_user, fresh_trip

@pytest.fixture
def client():
    with TestClient(app) as client:
        yield client


def test_weekly_cost_order_ties_missing_data_and_source_isolation(client):
    ids = {}; headers = {}
    for name in ['High', 'Low', 'Tie', 'No data']:
        ids[name], headers[name] = new_user(client, name)
    crew = client.post('/crews', json={'name': 'Local cost fixtures'}, headers=headers['High']).json()
    for name in ['Low', 'Tie', 'No data']:
        assert client.post(f"/crews/{crew['crew_id']}/join", json={'join_code':crew['join_code']}, headers=headers[name]).status_code == 200
    config = query("INSERT INTO scoring_configs(model_version,vehicle_profile,fuel_price_usd_per_gal) VALUES('test-only','{}',3) RETURNING id")[0]['id']
    def row(name, amount, offset=1, source='recorded'):
        start = week_start() + timedelta(days=offset)
        query("""INSERT INTO trips(user_id,client_trip_id,league_id,started_at,ended_at,distance_mi,
            source,is_demo,status,scoring_config_id,fuel_gal,avoidable_usd)
            VALUES($1,$2,$3,$4,$5,1,$6,true,'scored',$7,1,$8)""",
            UUID(ids[name]),uuid4(),UUID(crew['crew_id']),start,start+timedelta(minutes=1),source,config,amount)
    # Controlled DB fixtures, never real accounts or claims of model outcomes.
    row('High', 5); row('High', 2); row('Low', 1); row('Low', 1); row('Tie', 2)
    row('Low', 100, -1); row('Low', 100, 7)
    row('No data', 100, source='replayed'); row('No data', 100, source='synthetic')
    board = client.get('/leaderboard/costs',headers=headers['High']).json()
    assert board['ranking_metric'] == 'weekly_avoidable_cost_usd'
    assert [(x['nickname'],x['rank'],x['weekly_avoidable_cost_usd']) for x in board['standings']] == [('Low',1,2),('Tie',1,2),('High',2,7),('No data',None,None)]
    assert board['standings'][0]['trips_counted'] == 2
    assert all(x['improvement_pct'] is None for x in board['standings'])
    _, outsider = new_user(client,'Outsider')
    assert client.get('/leaderboard/costs',headers=outsider).status_code == 409
    assert client.get('/leaderboard/costs').status_code == 401
    assert client.get('/crews/'+crew['crew_id'],headers=outsider).status_code == 403


def test_recorded_upload_cost_matches_server_receipt_without_baseline(client):
    owner, headers = new_user(client,'Recorder')
    crew = client.post('/crews',json={'name':'Receipt league'},headers=headers).json()
    for name in ['Two','Three','Four']:
        _, other = new_user(client,name)
        client.post('/crews/'+crew['crew_id']+'/join',json={'join_code':crew['join_code']},headers=other)
    payload = fresh_trip(); payload['source']='recorded'; payload['is_demo']=False
    uploaded = client.post('/trips',headers=headers,json=payload)
    assert uploaded.status_code == 201
    receipt = client.get(uploaded.json()['receipt_url'],headers=headers).json()
    own = next(s for s in client.get('/leaderboard/costs',headers=headers).json()['standings'] if s['user_id']==owner)
    assert own['rank'] == 1 and own['trips_counted'] == 1
    assert round(own['weekly_avoidable_cost_usd'],4) == receipt['avoidable_cost_usd']


def test_demo_write_routes_default_closed(client, monkeypatch):
    monkeypatch.delenv('DRIVESAVE_ENABLE_LEAGUE_DEMO_WRITE',raising=False)
    _, headers = new_user(client,'Htoo')
    assert client.post('/developer/league-demo/seed/'+str(uuid4()),headers=headers).status_code == 403
    assert client.delete('/developer/league-demo/'+str(uuid4()),headers=headers).status_code == 403


def test_openapi_current_routes_and_deprecated_compatibility():
    schema = app.openapi()
    for path in ['/leaderboard','/leaderboard/costs','/leaderboard/demo','/crews/{crew_id}']:
        assert 'get' in schema['paths'][path]
    assert schema['paths']['/leaderboard']['get']['deprecated'] is True
