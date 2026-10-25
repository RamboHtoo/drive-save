-- Reviewed deployment prerequisite; never run automatically by the seed client.
-- Dedicated demo data stays outside public.trips, metrics, baselines and savings.
BEGIN;
CREATE SCHEMA IF NOT EXISTS drivesave_demo;
CREATE TABLE IF NOT EXISTS drivesave_demo.batches (
 id uuid PRIMARY KEY, owner_id uuid NOT NULL REFERENCES public.users(id),
 league_id uuid NOT NULL REFERENCES public.leagues(id), tag text NOT NULL CHECK(tag='htoo-five-fictional-v1'),
 UNIQUE(owner_id,league_id,tag)
);
CREATE TABLE IF NOT EXISTS drivesave_demo.players (
 user_id uuid PRIMARY KEY REFERENCES public.users(id), batch_id uuid NOT NULL REFERENCES drivesave_demo.batches(id),
 display_name text NOT NULL CHECK(display_name IN ('Alex','Jordan','Sam','Taylor','Casey')),
 UNIQUE(batch_id,display_name)
);
CREATE TABLE IF NOT EXISTS drivesave_demo.synthetic_trips (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES drivesave_demo.players(user_id),
 league_id uuid NOT NULL REFERENCES public.leagues(id), week_start timestamptz NOT NULL,
 source text NOT NULL DEFAULT 'synthetic' CHECK(source='synthetic'),
 is_demo boolean NOT NULL DEFAULT true CHECK(is_demo),
 estimate_kind text NOT NULL DEFAULT 'supplied_demo_example' CHECK(estimate_kind='supplied_demo_example'),
 status text NOT NULL CHECK(status IN ('demo_ready','unscored')),
 example_avoidable_usd numeric(12,2) NOT NULL CHECK(example_avoidable_usd>=0 AND example_avoidable_usd<'Infinity'::numeric),
 UNIQUE(user_id,week_start)
);
-- Never allow ordinary application roles to write demonstration records accidentally.
REVOKE ALL ON SCHEMA drivesave_demo FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA drivesave_demo FROM PUBLIC;
COMMIT;
