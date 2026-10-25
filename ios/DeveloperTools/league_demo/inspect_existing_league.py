#!/usr/bin/env python3
"""Read-only discovery using the CURRENT deployed API; no extension required.
Bearer token is read from DRIVESAVE_TOKEN or a hidden prompt, never printed/saved.
"""
import argparse
import getpass
import json
import os
from urllib.parse import urlsplit
from urllib.error import HTTPError
from urllib.request import Request
from seed_existing_league import API


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url',required=True)
    args=parser.parse_args()
    origin=urlsplit(args.base_url)
    local=origin.hostname in ('localhost','127.0.0.1','::1')
    if origin.username or origin.password or origin.query or origin.fragment or origin.path not in ('','/') or not (origin.scheme=='https' or local and origin.scheme=='http'):
        parser.error('Use HTTPS API origin (HTTP permitted only on localhost).')
    api=API(args.base_url,os.environ.get('DRIVESAVE_TOKEN') or getpass.getpass('Existing Htoo token (not saved): '))
    board=api.call('GET','/leaderboard')  # Authenticated self-scoped league association.
    crew=api.call('GET','/crews/'+board['crew_id'])
    matches=[]
    for member in crew['members']:
        if member['nickname']!='Htoo': continue
        # Names are not unique. The self-only progress route authenticates the exact ID.
        request=Request(api.url+'/users/'+member['user_id']+'/progress',headers={'Authorization':'Bearer '+api.token})
        try:
            with api.opener.open(request,timeout=30) as response:
                progress=json.load(response)
                if progress['user_id']==member['user_id']: matches.append(member)
        except HTTPError as error:
            status=error.code; error.close()
            if status!=403: raise SystemExit(f'Account verification failed: HTTP {status}') from None
    if len(matches)!=1: raise SystemExit('Could not uniquely verify the authenticated Htoo account. Nothing changed.')
    print(json.dumps(dict(owner_id=matches[0]['user_id'],owner_nickname='Htoo',league_id=crew['crew_id'],league_name=crew['name'],verification='authenticated self leaderboard, private crew and self-only progress'),indent=2))
    print('READ ONLY: account, token, vehicle, memberships and trips unchanged.')

if __name__=='__main__': main()
