#!/usr/bin/env python3
"""Dry-run by default. Authenticates the EXISTING account; never creates/moves a league."""
import argparse
import getpass
import json
import os
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError
from uuid import UUID

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None

class API:
    def __init__(self,url,token):
        self.url=url.rstrip('/'); self.token=token; self.opener=build_opener(NoRedirect)
    def call(self,method,path):
        request=Request(self.url+path,method=method,headers={'Authorization':'Bearer '+self.token,'Accept':'application/json'})
        try:
            with self.opener.open(request,timeout=30) as response: return json.load(response)
        except HTTPError as error:
            # Tokens are never printed or written to a manifest.
            status=error.code; detail=error.read().decode()[:1000]; error.close()
            raise SystemExit(f'{method} failed: HTTP {status}; '+detail) from None

def main(cleanup=False):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url',required=True)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--allow-production',action='store_true')
    parser.add_argument('--confirm-league',type=UUID)
    parser.add_argument('--batch',type=UUID)
    args=parser.parse_args()
    parsed=urlsplit(args.base_url)
    local=parsed.hostname in ('localhost','127.0.0.1','::1')
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('','/'):
        parser.error('Use an API origin without credentials, path, query or fragment.')
    if parsed.scheme!='https' and not (local and parsed.scheme=='http'): parser.error('HTTPS required outside localhost.')
    if args.apply and not local and not args.allow_production: parser.error('Production writes require --allow-production after explicit approval.')
    token=os.environ.get('DRIVESAVE_TOKEN') or getpass.getpass('Existing Htoo bearer token (not saved): ')
    api=API(args.base_url,token)
    plan=api.call('GET','/developer/league-demo/plan')
    if plan['owner_nickname']!='Htoo': parser.error('Authenticated account must be the existing Htoo account.')
    print(json.dumps(plan,indent=2))
    if not args.apply:
        print('DRY RUN: no identities, trips, memberships or financial records changed.')
        return
    if args.confirm_league is None or str(args.confirm_league)!=plan['league_id']:
        parser.error('Review the authenticated plan and pass its exact --confirm-league value.')
    if cleanup:
        if args.batch is None or str(args.batch)!=plan['batch_id']: parser.error('--batch must match this exact five-player plan.')
        result=api.call('DELETE','/developer/league-demo/'+str(args.batch))
    else:
        result=api.call('POST','/developer/league-demo/seed/'+plan['league_id'])
    print(json.dumps(result,indent=2))

if __name__=='__main__': main()
