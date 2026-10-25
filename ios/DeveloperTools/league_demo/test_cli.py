import contextlib
import io
import os
import sys
import unittest
from unittest.mock import patch
from uuid import uuid4
import seed_existing_league as seed

class GuardTests(unittest.TestCase):
    def setUp(self):
        self.league=str(uuid4()); self.batch=str(uuid4()); self.calls=[]
        outer=self
        class FakeAPI:
            def __init__(self,url,token): pass
            def call(self,method,path):
                outer.calls.append((method,path))
                return dict(owner_nickname='Htoo',league_id=outer.league,batch_id=outer.batch)
        self.api=patch.object(seed,'API',FakeAPI);self.api.start()
        self.env=patch.dict(os.environ,{'DRIVESAVE_TOKEN':'unit-test-secret'});self.env.start()
        self.output=io.StringIO()
    def tearDown(self): self.api.stop();self.env.stop()
    def run_cli(self,args,cleanup=False):
        with patch.object(sys,'argv',['seed',*args]),contextlib.redirect_stdout(self.output),contextlib.redirect_stderr(self.output): seed.main(cleanup=cleanup)
    def test_default_dry_run(self):
        self.run_cli(['--base-url','https://example.invalid'])
        self.assertEqual(self.calls,[('GET','/developer/league-demo/plan')]);self.assertNotIn('unit-test-secret',self.output.getvalue())
    def test_production_write_requires_explicit_opt_in(self):
        with self.assertRaises(SystemExit): self.run_cli(['--base-url','https://example.invalid','--apply'])
        self.assertEqual(self.calls,[])
    def test_http_remote_is_rejected(self):
        with self.assertRaises(SystemExit): self.run_cli(['--base-url','http://example.invalid'])
        self.assertEqual(self.calls,[])
    def test_wrong_confirmation_does_not_write(self):
        with self.assertRaises(SystemExit): self.run_cli(['--base-url','http://localhost','--apply','--confirm-league',str(uuid4())])
        self.assertEqual(len(self.calls),1)
    def test_cleanup_requires_exact_batch(self):
        with self.assertRaises(SystemExit): self.run_cli(['--base-url','http://localhost','--apply','--confirm-league',self.league,'--batch',str(uuid4())],True)
        self.assertEqual(len(self.calls),1)
    def test_approved_fake_call_targets_authenticated_association(self):
        self.run_cli(['--base-url','https://example.invalid','--allow-production','--apply','--confirm-league',self.league])
        self.assertEqual(self.calls[-1],('POST','/developer/league-demo/seed/'+self.league))
    def test_read_only_discovery_disambiguates_duplicate_names_by_auth(self):
        import json
        import inspect_existing_league as inspector
        from urllib.error import HTTPError
        other, owner = str(uuid4()), str(uuid4())
        league = self.league
        class Opener:
            def open(self, request, timeout):
                if other in request.full_url: raise HTTPError(request.full_url,403,"forbidden",None,None)
                return io.BytesIO(json.dumps({'user_id':owner}).encode())
        class ReadAPI:
            def __init__(self,url,token): self.url=url;self.token=token;self.opener=Opener()
            def call(self,method,path):
                if method!='GET': raise AssertionError('Discovery attempted a write')
                if path=='/leaderboard': return {'crew_id':league}
                return {'crew_id':league,'name':'Existing league','members':[{'nickname':'Htoo','user_id':other},{'nickname':'Htoo','user_id':owner}]}
        with patch.object(inspector,'API',ReadAPI),patch.object(sys,'argv',['inspect','--base-url','https://example.invalid']),contextlib.redirect_stdout(self.output): inspector.main()
        self.assertIn(owner,self.output.getvalue());self.assertNotIn(other,self.output.getvalue());self.assertNotIn('unit-test-secret',self.output.getvalue())
    def test_redirect_never_forwards_token(self):
        self.assertIsNone(seed.NoRedirect().redirect_request(None,None,None,None,None,None))

if __name__=='__main__': unittest.main()
