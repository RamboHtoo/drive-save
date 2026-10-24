"""Clearly labeled demo crews so the leaderboard is never empty during UI work.

TODO(stage 4): replace with seed.py, which writes demo crews and trips to the database.
"""

from uuid import NAMESPACE_URL, uuid5

from models.leaderboard import Standing

DEMO_CREWS = [
    Standing(rank=0, id=uuid5(NAMESPACE_URL, "drive-save/demo/east-halls"), name="East Halls (Demo)", members=5, improvement_pct=12.4, est_savings_usd=38.10, is_demo=True),
    Standing(rank=0, id=uuid5(NAMESPACE_URL, "drive-save/demo/west-halls"), name="West Halls (Demo)", members=4, improvement_pct=7.9, est_savings_usd=21.55, is_demo=True),
]
