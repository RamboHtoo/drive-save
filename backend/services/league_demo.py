"""Weekly cost standings and isolated, explicitly gated showcase provisioning."""
import hashlib
import secrets
import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import UUID, uuid5

import db
import repo
from errors import ApiError

TAG = 'htoo-five-fictional-v1'
NAMESPACE = UUID('bef4be09-5bbb-46b8-bd27-b3e5936b3411')
PLAYERS = [('Alex', Decimal('1.85')), ('Jordan', Decimal('2.40')), ('Sam', Decimal('3.12')), ('Taylor', Decimal('4.30')), ('Casey', Decimal('5.75'))]

def week_start():
    now = datetime.now(timezone.utc)
    return (now - timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)

def identifiers(owner, league):
    batch = uuid5(NAMESPACE, f'{TAG}:{owner}:{league}')
    return batch, [(name, cost, uuid5(batch, name)) for name, cost in PLAYERS]

async def association(conn, user):
    # Resolve from the authenticated identity, never a nickname lookup or guessed crew ID.
    row = await conn.fetchrow('SELECT l.id,l.name,l.join_code,l.is_demo FROM public.league_members m JOIN public.leagues l ON l.id=m.league_id WHERE m.user_id=$1', user.user_id)
    if row is None:
        raise ApiError(409, 'no_existing_league', 'The authenticated account has no league. No league will be created.')
    return row

async def plan_for(user):
    if user.nickname != 'Htoo':
        raise ApiError(403, 'wrong_presenter', 'Use the existing authenticated Htoo account; no account will be renamed.')
    async with db.pool().acquire() as conn:
        league = await association(conn, user)
        batch, players = identifiers(user.user_id, league['id'])
        existing_count=await conn.fetchval('SELECT count(*) FROM public.league_members WHERE league_id=$1',league['id'])
        existing_demo_count=await conn.fetchval('SELECT count(*) FROM drivesave_demo.players p JOIN public.league_members m ON m.user_id=p.user_id WHERE p.batch_id=$1 AND m.league_id=$2',batch,league['id'])
    return dict(batch_id=str(batch), owner_id=str(user.user_id), owner_nickname=user.nickname,
                existing_member_count=existing_count, expected_member_count_after_seed=existing_count+5-existing_demo_count,
                league_id=str(league['id']), league_name=league['name'], week_start=week_start().isoformat(),
                players=[dict(user_id=str(uid), nickname=name+' · Synthetic demo', example_avoidable_usd=str(cost)) for name,cost,uid in players])

def require_writes_enabled(user):
    if os.environ.get('DRIVESAVE_ENABLE_LEAGUE_DEMO_WRITE') != '1':
        raise ApiError(403,'demo_writes_disabled','Demo writes require explicit server enablement after approval.')
    try:
        approved = UUID(os.environ.get('DRIVESAVE_DEMO_PRESENTER_ID',''))
    except ValueError:
        raise ApiError(403,'presenter_not_approved','An authenticated presenter UUID must be explicitly approved first.') from None
    if approved != user.user_id:
        raise ApiError(403,'presenter_not_approved','Only the explicitly approved existing presenter may seed or clean this demo.')


async def seed(user, expected_league):
    require_writes_enabled(user)
    plan = await plan_for(user)
    if plan['league_id'] != str(expected_league):
        raise ApiError(409, 'league_changed', 'League association changed; review a new plan.')
    batch = UUID(plan['batch_id']); league = UUID(plan['league_id']); week = datetime.fromisoformat(plan['week_start'])
    async with db.pool().acquire() as conn, conn.transaction():
        await conn.execute('SELECT pg_advisory_xact_lock(hashtext($1))', str(batch))
        current = await association(conn, user)
        if current['id'] != league:
            raise ApiError(409, 'league_changed', 'League changed before the seed transaction.')
        await conn.execute('INSERT INTO drivesave_demo.batches VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING', batch,user.user_id,league,TAG)
        for name,cost,uid in identifiers(user.user_id,league)[1]:
            expected_name = name+' · Synthetic demo'
            registered = await conn.fetchrow('SELECT p.batch_id,p.display_name,u.nickname,m.league_id FROM drivesave_demo.players p JOIN public.users u ON u.id=p.user_id JOIN public.league_members m ON m.user_id=u.id WHERE p.user_id=$1',uid)
            if registered:
                if registered['batch_id'] != batch or registered['display_name'] != name or registered['nickname'] != expected_name or registered['league_id'] != league:
                    raise ApiError(409,'demo_identity_changed','A demo identity was modified; refusing to overwrite it.')
            else:
                if await conn.fetchval('SELECT EXISTS(SELECT 1 FROM public.users WHERE id=$1)',uid):
                    raise ApiError(409,'demo_id_collision','Reserved demo UUID already exists; refusing to adopt it.')
                # Existing API lacks idempotent account creation/deletion. Create only these
                # deterministic identities transactionally. Random credentials are discarded.
                token_hash = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
                await conn.execute('INSERT INTO public.users(id,nickname,token_hash) VALUES($1,$2,$3)',uid,expected_name,token_hash)
                await conn.execute('INSERT INTO drivesave_demo.players VALUES($1,$2,$3)',uid,batch,name)
                await repo._join(conn,league,uid)  # existing membership semantics, synthetic accounts only
            trip_id = uuid5(uid, week.isoformat())
            await conn.execute('''INSERT INTO drivesave_demo.synthetic_trips(id,user_id,league_id,week_start,status,example_avoidable_usd)
                VALUES($1,$2,$3,$4,'demo_ready',$5) ON CONFLICT(user_id,week_start) DO NOTHING''',trip_id,uid,league,week,cost)
    return plan

async def cleanup(user,batch):
    require_writes_enabled(user)
    async with db.pool().acquire() as conn, conn.transaction():
        await conn.execute('SELECT pg_advisory_xact_lock(hashtext($1))',str(batch))
        row=await conn.fetchrow('SELECT * FROM drivesave_demo.batches WHERE id=$1',batch)
        if row is None: return dict(deleted_users=0)
        if row['owner_id'] != user.user_id or row['tag'] != TAG:
            raise ApiError(403,'forbidden','Only the original authenticated owner may clean this batch.')
        expected=identifiers(row['owner_id'],row['league_id'])[1]
        actual=await conn.fetch('SELECT p.*,u.nickname,m.league_id FROM drivesave_demo.players p JOIN public.users u ON u.id=p.user_id LEFT JOIN public.league_members m ON m.user_id=p.user_id WHERE p.batch_id=$1',batch)
        expected_map={uid:name for name,_,uid in expected}
        for player in actual:
            if player['user_id'] not in expected_map or player['nickname'] != expected_map[player['user_id']]+' · Synthetic demo' or player['league_id'] != row['league_id']:
                raise ApiError(409,'demo_identity_changed','Cleanup stopped: identity or membership was modified.')
            if await conn.fetchval('SELECT EXISTS(SELECT 1 FROM public.trips WHERE user_id=$1)',player['user_id']):
                raise ApiError(409,'unexpected_public_trips','Cleanup stopped: a demo identity has public trips; review manually.')
        ids=[p['user_id'] for p in actual]
        await conn.execute('DELETE FROM drivesave_demo.synthetic_trips WHERE user_id=ANY($1::uuid[])',ids)
        await conn.execute('DELETE FROM drivesave_demo.players WHERE batch_id=$1',batch)
        await conn.execute('DELETE FROM public.league_members WHERE user_id=ANY($1::uuid[])',ids)
        await conn.execute('DELETE FROM public.users WHERE id=ANY($1::uuid[])',ids)
        await conn.execute('DELETE FROM drivesave_demo.batches WHERE id=$1',batch)
        return dict(deleted_users=len(ids))

async def board_for(user,showcase=False):
    async with db.pool().acquire() as conn:
        league=await association(conn,user)
        members=await conn.fetch('''SELECT u.id,u.nickname,p.user_id IS NOT NULL AS synthetic FROM public.league_members m
            JOIN public.users u ON u.id=m.user_id LEFT JOIN drivesave_demo.players p ON p.user_id=u.id WHERE m.league_id=$1''',league['id'])
        costs=await conn.fetch('''SELECT t.user_id,sum(t.avoidable_usd) AS cost,count(*) AS trips FROM public.trips t
            LEFT JOIN drivesave_demo.players p ON p.user_id=t.user_id WHERE t.league_id=$1 AND t.source='recorded'
            AND t.status='scored' AND p.user_id IS NULL AND t.started_at >= $2 AND t.started_at < $2+interval '7 days' GROUP BY t.user_id''',league['id'],week_start())
        examples=await conn.fetch('''SELECT user_id,sum(example_avoidable_usd) AS cost,count(*) AS trips FROM drivesave_demo.synthetic_trips
            WHERE league_id=$1 AND week_start=$2 AND status='demo_ready' AND is_demo AND source='synthetic' GROUP BY user_id''',league['id'],week_start()) if showcase else []
    eligible={r['user_id']:r for r in [*costs,*examples]}
    real_count=sum(not m['synthetic'] for m in members)
    active=len(members)>=4 if showcase else real_count>=4
    ordered=sorted(members,key=lambda m:(eligible[m['id']]['cost'] if m['id'] in eligible and active else Decimal('Infinity'),m['nickname'],str(m['id'])))
    result=[]; previous=None; rank=0
    for member in ordered:
        value=eligible.get(member['id']) if active else None
        if value is not None:
            if previous is None or value['cost']!=previous: rank+=1
            previous=value['cost']
        result.append(dict(user_id=str(member['id']),nickname=member['nickname'],rank=rank if value else None,
            weekly_avoidable_cost_usd=float(value['cost']) if value else None,trips_counted=value['trips'] if value else 0,
            improvement_pct=None,est_savings_usd=None,state='ready' if value else 'no_eligible_trips',
            is_synthetic_demo=member['synthetic'],estimate_source='supplied_demo_example' if member['synthetic'] else 'recorded_scored_trips'))
    return dict(crew_id=str(league['id']),crew_name=league['name'],member_count=len(members),active=active,period='week',
                generated_at=datetime.now(timezone.utc).isoformat(),standings=result,is_demo=showcase or league['is_demo'],is_estimate=True,
                ranking_metric='weekly_avoidable_cost_usd',demo_preview=showcase)

async def real_member_count(league_id):
    return await db.pool().fetchval("""SELECT count(*) FROM public.league_members m
        LEFT JOIN drivesave_demo.players p ON p.user_id=m.user_id
        WHERE m.league_id=$1 AND p.user_id IS NULL""", league_id)


async def legacy_board(user, period):
    # Compatibility endpoint only. Current iOS uses /leaderboard/costs.
    result = await repo.leaderboard(user.user_id, period)
    costs = await board_for(user)
    result.active = costs['active']
    synthetic = {row['user_id'] for row in costs['standings'] if row['is_synthetic_demo']}
    for row in result.standings:
        if (synthetic and not result.active) or str(row.user_id) in synthetic:
            row.rank = None
            row.improvement_pct = None
            row.est_savings_usd = 0
            row.state = 'collecting_baseline'
    return result
