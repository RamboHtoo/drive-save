#!/usr/bin/env python3
"""Same dry-run, account, batch and production gates as the seed; deletes only its five identities."""
from seed_existing_league import main
if __name__=='__main__': main(cleanup=True)
