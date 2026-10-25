"""Offline runnable demonstration and JSON interface for the estimator."""

import argparse
import json
from pathlib import Path
import sys

from .estimator import estimate_trip, reference_profile
from .validation import example_payload, four_player_demo, validation_report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("profile")
    example = sub.add_parser("example", help="Generate synthetic events, or an unscorable speed-only EPA replay")
    example.add_argument("--cycle", choices=("demo", "udds", "hwfet", "us06"), default="demo")
    estimate = sub.add_parser("estimate")
    estimate.add_argument("input", type=Path)
    sub.add_parser("demo", help="Calculate four players' standings from synthetic/replayed trips")
    sub.add_parser("validate", help="Exit 2 while independent laboratory validation is pending")
    args = parser.parse_args()
    try:
        exit_code = 0
        if args.command == "profile":
            result = reference_profile()
        elif args.command == "example":
            result = example_payload(args.cycle)
        elif args.command == "estimate":
            payload = json.loads(args.input.read_text(), parse_constant=lambda s: None)
            result = estimate_trip(**payload)
            exit_code = 0 if result["status"] == "scored" else 2
        elif args.command == "demo":
            result = four_player_demo()
        else:
            result = validation_report()
            exit_code = 0 if result["release_gate_passed"] else 2
        print(json.dumps(result, indent=2, allow_nan=False))
        return exit_code
    except (OSError, ValueError, TypeError, RuntimeError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
