"""Refresh public source snapshots. Run deliberately; scoring is always offline."""
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
from urllib.request import Request, urlopen

DATA = Path(__file__).resolve().parents[1] / "drive_save_model/data"


def main():
    assets = []
    retrieved = datetime.now(timezone.utc).isoformat()
    def fetch(url):
        with urlopen(Request(url, headers={"Accept": "application/json"}), timeout=30) as r:
            return r.read()
    def save(name, content, url, original=None):
        (DATA / name).write_bytes(content)
        assets.append({"file": name, "source_url": url, "retrieved_at": retrieved,
                       "sha256": hashlib.sha256(content).hexdigest(),
                       "source_sha256": hashlib.sha256(original or content).hexdigest()})
    url = "https://www.fueleconomy.gov/ws/rest/vehicle/31284"
    raw = fetch(url)
    vehicle = json.loads(raw)
    assert str(vehicle["id"]) == "31284" and vehicle["trany"] == "Automatic (S5)"
    save("fueleconomy_31284.json", raw, url)
    url = "https://www.epa.gov/sites/default/files/2016-07/12tstcar.csv"
    raw = fetch(url)
    records = [r for r in csv.DictReader(io.StringIO(raw.decode("utf-8-sig")))
               if r["Test Vehicle ID"] == "2ECL5XS1-001" and r["Test Veh Configuration #"] == "1"]
    assert {r["Test Category"] for r in records} == {"FTP", "HWY", "US06"}
    for r in records:
        assert r["Target Coef A (lbf)"] == "34.059" and r["Rated Horsepower"] == "157"
    save("epa_2012_mazda5.json", (json.dumps(records, indent=2) + "\n").encode(), url, raw)
    for name, url in {
        "udds": "https://www.epa.gov/sites/default/files/2015-10/uddscol.txt",
        "hwfet": "https://www.epa.gov/sites/default/files/2015-10/hwycol.txt",
        "us06": "https://www.epa.gov/system/files/other-files/2025-03/us06col.txt",
    }.items():
        save(name + "_epa.txt", fetch(url), url)
    (DATA / "sources.json").write_text(json.dumps({"assets": assets,
        "independent_validation": "pending", "calibration_applied": False}, indent=2) + "\n")
    print("Cached vehicle, three matching laboratory records, and three official speed schedules.")


if __name__ == "__main__":
    main()
