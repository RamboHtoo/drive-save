"""Standalone isolated-only integration audit; never uses backend's destructive conftest."""
import asyncio
import json
import os
from pathlib import Path
import sys
from uuid import UUID,uuid4

# Fixed local-only test database. Never accept DATABASE_URL inherited from a shell.
os.environ['DATABASE_URL']='postgresql://postgres:isolated-demo-test@127.0.0.1:55439/drivesave_demo_isolated'
os.environ['DRIVESAVE_ENABLE_LEAGUE_DEMO_WRITE']='1'
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
snapshot=Path(sys.argv[1]).resolve()
sys.path[:0]=[str(HERE),str(snapshot/'backend'),str(snapshot)]
import httpx
import db
from main import app
import backend_extension as demo

demo.install(app)
checks=0

def check(value,message):
    global checks
    assert value,message
    checks+=1
    print('PASS:',message)

async def main():
    await db.connect()
    try:
        # Unique fixture scope; no truncation, no existing user or league is selected by name.
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://localhost') as client:
            user=(await client.post('/users',json={'nickname':'Htoo'})).json()
            headers={'Authorization':'Bearer '+user['token']}
            vehicle=json.loads((ROOT/'DriveAndSave/MockData/Backend/catalog-mazda5.json').read_text())
            check((await client.put('/users/me/vehicle',headers=headers,json=vehicle)).status_code==200,'isolated presenter vehicle set through existing API')
            league=(await client.post('/crews',headers=headers,json={'name':'Existing Htoo league — isolated fixture'})).json()
            owner=UUID(user['user_id']); crew=UUID(league['crew_id'])
            os.environ['DRIVESAVE_DEMO_PRESENTER_ID']=str(owner)
            before=await db.pool().fetchrow('SELECT * FROM public.users WHERE id=$1',owner)
            before_membership=await db.pool().fetchrow('SELECT * FROM public.league_members WHERE user_id=$1',owner)
            # Controlled unscored fixture, not an actual Htoo recording or a fabricated score.
            await db.pool().execute('''INSERT INTO public.trips(user_id,client_trip_id,league_id,started_at,ended_at,distance_mi,source,is_demo)
                VALUES($1,$2,$3,now()-interval '2 minutes',now()-interval '1 minute',1,'recorded',false)''',owner,uuid4(),crew)
            progress_before=(await client.get(f'/users/{owner}/progress',headers=headers)).json()
            check((await client.get('/developer/league-demo/plan')).status_code==401,'unauthenticated league discovery rejected')
            plan=(await client.get('/developer/league-demo/plan',headers=headers)).json()
            check(plan['owner_id']==str(owner) and plan['league_id']==str(crew),'league resolved from authenticated membership, never guessed')
            check((await client.post('/developer/league-demo/seed/'+str(uuid4()),headers=headers)).status_code==409,'mismatched association fails without creating league')
            os.environ['DRIVESAVE_ENABLE_LEAGUE_DEMO_WRITE']='0'
            check((await client.post('/developer/league-demo/seed/'+str(crew),headers=headers)).status_code==403,'server write gate defaults closed unless explicitly enabled')
            os.environ['DRIVESAVE_ENABLE_LEAGUE_DEMO_WRITE']='1'
            os.environ['DRIVESAVE_DEMO_PRESENTER_ID']=str(uuid4())
            check((await client.post('/developer/league-demo/seed/'+str(crew),headers=headers)).status_code==403,'a duplicate nickname cannot bypass exact authenticated presenter approval')
            os.environ['DRIVESAVE_DEMO_PRESENTER_ID']=str(owner)
            responses=await asyncio.gather(*[client.post('/developer/league-demo/seed/'+str(crew),headers=headers) for _ in range(2)])
            check(all(r.status_code==200 for r in responses),'concurrent seeding is atomic and idempotent')
            members=(await client.get('/crews/'+str(crew),headers=headers)).json()
            check(members['member_count']==6 and not members['active'],'six members present; demo identities do not activate genuine competition')
            board=(await client.get('/leaderboard/demo',headers=headers)).json()
            check([r['nickname'].split(' · ')[0] for r in board['standings']]==['Alex','Jordan','Sam','Taylor','Casey','Htoo'],'all six appear in requested cost order, Htoo last unranked')
            check([r['weekly_avoidable_cost_usd'] for r in board['standings']]==[1.85,2.40,3.12,4.30,5.75,None],'only requested demo amounts displayed; Htoo has no invented cost')
            check([r['rank'] for r in board['standings']]==[1,2,3,4,5,None],'lowest weekly cost first, eligible examples only')
            check(all(r['is_synthetic_demo'] for r in board['standings'][:5]) and not board['standings'][-1]['is_synthetic_demo'],'fictional identities explicitly marked; Htoo retains real provenance')
            check(len({r['user_id'] for r in board['standings']})==6,'all identities have separate IDs')
            fixture_dir=ROOT/'DriveAndSave/MockData/Backend'
            fixture=(dict(board,viewer_id=str(owner)))
            (fixture_dir/'league-showcase.json').write_text(json.dumps(fixture,indent=2)+'\n')
            normal=(await client.get('/leaderboard/costs',headers=headers)).json()
            check(all(r['rank'] is None and r['weekly_avoidable_cost_usd'] is None for r in normal['standings']),'normal competition never includes illustrative costs')
            legacy=(await client.get('/leaderboard',headers=headers)).json()
            check(not legacy['active'] and all(r['rank'] is None for r in legacy['standings']),'legacy endpoint cannot count demo members toward real qualification')
            check((await client.get(f'/users/{owner}/progress',headers=headers)).json()==progress_before,'real financial progress unchanged by demo data')
            check(dict(await db.pool().fetchrow('SELECT * FROM public.users WHERE id=$1',owner))==dict(before),'Htoo account, token hash and complete vehicle remain byte-for-byte unchanged')
            check(dict(await db.pool().fetchrow('SELECT * FROM public.league_members WHERE user_id=$1',owner))==dict(before_membership),'Htoo membership and joined_at unchanged')
            check(await db.pool().fetchval('SELECT count(*) FROM drivesave_demo.synthetic_trips WHERE league_id=$1',crew)==5,'exactly five isolated example trip records; no duplicate on retry')
            check(await db.pool().fetchval('SELECT count(*) FROM public.trips WHERE user_id<>$1 AND league_id=$2',owner,crew)==0,'no demo records enter public trips or sensor/scoring pipeline')
            jordan=UUID(board['standings'][1]['user_id'])
            await db.pool().execute("UPDATE drivesave_demo.synthetic_trips SET status='unscored' WHERE user_id=$1",jordan)
            changed=(await client.get('/leaderboard/demo',headers=headers)).json()
            check(next(r for r in changed['standings'] if r['user_id']==str(jordan))['rank'] is None,'unscored synthetic examples are unranked')
            await db.pool().execute("UPDATE drivesave_demo.synthetic_trips SET status='demo_ready' WHERE user_id=$1",jordan)
            # Score a controlled recording fixture through the EXISTING fuel model. This is
            # isolated test input; it is never Htoo's production history or a claimed real drive.
            payload=json.loads((ROOT/'DriveAndSave/MockData/Backend/calculation-trip.json').read_text());payload['client_trip_id']=str(uuid4())
            for event in payload['events']: event['event_id']=str(uuid4())
            created=await client.post('/trips',headers=headers,json=payload)
            check(created.status_code==201,'existing recorded-mode model pipeline remains available in isolated test')
            receipt_response=await client.get(created.json()['receipt_url'],headers=headers)
            check(receipt_response.status_code==200,'model provides actual fixture result without fixed target price')
            receipt=receipt_response.json()
            scored=(await client.get('/leaderboard/demo',headers=headers)).json()
            own=next(r for r in scored['standings'] if r['user_id']==str(owner))
            check(round(own['weekly_avoidable_cost_usd'],4)==receipt['avoidable_cost_usd'] and own['rank'] is not None,'Htoo row uses actual scored recorded-mode model result when available')
            money=[r['weekly_avoidable_cost_usd'] for r in scored['standings'] if r['rank'] is not None]
            check(money==sorted(money),'genuine result ranks solely by weekly cost, independent of baseline/improvement')
            history_before_cleanup=await db.pool().fetchval('SELECT count(*) FROM public.trips WHERE user_id=$1',owner)
            other=(await client.post('/users',json={'nickname':'Unrelated isolated fixture'})).json()
            other_headers={'Authorization':'Bearer '+other['token']}
            check((await client.delete('/developer/league-demo/'+plan['batch_id'],headers=other_headers)).status_code==403,'unrelated authenticated user cannot clean the batch')
            alex=UUID(board['standings'][0]['user_id']); foreign_trip=uuid4()
            await db.pool().execute("INSERT INTO public.trips(user_id,client_trip_id,league_id,started_at,ended_at,distance_mi,source,is_demo) VALUES($1,$2,$3,now()-interval '2 minutes',now()-interval '1 minute',1,'synthetic',true)",alex,foreign_trip,crew)
            check((await client.delete('/developer/league-demo/'+plan['batch_id'],headers=headers)).status_code==409,'cleanup refuses unexpected public trip data instead of deleting it')
            check(await db.pool().fetchval('SELECT count(*) FROM drivesave_demo.players WHERE batch_id=$1',UUID(plan['batch_id']))==5,'failed cleanup is atomic and preserves all five identities')
            await db.pool().execute('DELETE FROM public.trips WHERE user_id=$1 AND client_trip_id=$2',alex,foreign_trip)  # only this controlled test row
            result=await client.delete('/developer/league-demo/'+plan['batch_id'],headers=headers)
            check(result.status_code==200 and result.json()['deleted_users']==5,'cleanup removes only its five fictional identities')
            check((await client.delete('/developer/league-demo/'+plan['batch_id'],headers=headers)).json()['deleted_users']==0,'cleanup retry is idempotent')
            check(await db.pool().fetchval('SELECT count(*) FROM public.trips WHERE user_id=$1',owner)==history_before_cleanup,'cleanup preserves every presenter history row')
            check(dict(await db.pool().fetchrow('SELECT * FROM public.users WHERE id=$1',owner))==dict(before),'cleanup preserves presenter token and vehicle')
            check((await client.get('/crews/'+str(crew),headers=headers)).json()['member_count']==1,'cleanup preserves existing league and original presenter membership')
            print(f'{checks} isolated database/API checks passed. No production data accessed.')
    finally:
        await db.close()

if __name__=='__main__': asyncio.run(main())
