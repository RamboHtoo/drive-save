"""Reads the EPA Test Car List files (the repo's vehicle/ folder) into one row format.

EPA publishes a file per model year: CSV through 2016, Excel from 2017. The files
from 2010 on share one column layout (2014 added the three DT- columns). The
2007-2009 files use an older coded layout without a brand column, so they are
skipped.

Every column is kept under a snake_case name (COLUMNS). A value that doesn't parse
as its column's type, or a column this list doesn't know, goes to `unmapped` under
its original header, so nothing in the files is dropped. Each row also gets the
brand and model name normalized for the car picker, `make` and `model`: EPA spells
brands differently from year to year ("FORD", "Ford") and model names repeat the
brand ("MAZDA CX-5").
"""

import csv
import hashlib
import io
import math
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

# (column, header in the EPA files, type)
COLUMNS: list[tuple[str, str, type]] = [
    ("model_year", "Model Year", int),
    ("manufacturer", "Vehicle Manufacturer Name", str),
    ("manufacturer_code", "Veh Mfr Code", str),
    ("represented_make", "Represented Test Veh Make", str),
    ("represented_model", "Represented Test Veh Model", str),
    ("test_vehicle_id", "Test Vehicle ID", str),
    ("configuration", "Test Veh Configuration #", int),
    ("displacement_l", "Test Veh Displacement (L)", float),
    ("test_group", "Actual Tested Testgroup", str),
    ("vehicle_type", "Vehicle Type", str),
    ("rated_hp", "Rated Horsepower", float),
    ("cylinders", "# of Cylinders and Rotors", int),
    ("engine_code", "Engine Code", str),
    ("transmission_code", "Tested Transmission Type Code", str),
    ("transmission", "Tested Transmission Type", str),
    ("gears", "# of Gears", int),
    ("transmission_lockup", "Transmission Lockup?", str),
    ("drive_code", "Drive System Code", str),
    ("drive", "Drive System Description", str),
    ("overdrive_code", "Transmission Overdrive Code", str),
    ("overdrive", "Transmission Overdrive Desc", str),
    ("etw_lb", "Equivalent Test Weight (lbs.)", float),
    ("axle_ratio", "Axle Ratio", float),
    ("nv_ratio", "N/V Ratio", float),
    ("shift_indicator_code", "Shift Indicator Light Use Cd", str),
    ("shift_indicator", "Shift Indicator Light Use Desc", str),
    ("test_number", "Test Number", str),
    ("test_originator", "Test Originator", str),
    ("analytically_derived", "Analytically Derived FE?", str),
    ("adfe_test_number", "ADFE Test Number", str),
    ("adfe_road_load_hp", "ADFE Total Road Load HP", float),
    ("adfe_etw_lb", "ADFE Equiv. Test Weight (lbs.)", float),
    ("adfe_nv_ratio", "ADFE N/V Ratio", float),
    ("test_procedure_code", "Test Procedure Cd", int),
    ("test_procedure", "Test Procedure Description", str),
    ("fuel_code", "Test Fuel Type Cd", int),
    ("fuel", "Test Fuel Type Description", str),
    ("test_category", "Test Category", str),
    ("thc_g_per_mi", "THC (g/mi)", float),
    ("co_g_per_mi", "CO (g/mi)", float),
    ("co2_g_per_mi", "CO2 (g/mi)", float),
    ("nox_g_per_mi", "NOx (g/mi)", float),
    ("pm_g_per_mi", "PM (g/mi)", float),
    ("ch4_g_per_mi", "CH4 (g/mi)", float),
    ("n2o_g_per_mi", "N2O (g/mi)", float),
    ("fe", "RND_ADJ_FE", float),
    ("fe_unit", "FE_UNIT", str),
    ("fe_bag_1", "FE Bag 1", float),
    ("fe_bag_2", "FE Bag 2", float),
    ("fe_bag_3", "FE Bag 3", float),
    ("fe_bag_4", "FE Bag 4", float),
    ("target_a_lbf", "Target Coef A (lbf)", float),
    ("target_b_lbf_per_mph", "Target Coef B (lbf/mph)", float),
    ("target_c_lbf_per_mph2", "Target Coef C (lbf/mph**2)", float),
    ("set_a_lbf", "Set Coef A (lbf)", float),
    ("set_b_lbf_per_mph", "Set Coef B (lbf/mph)", float),
    ("set_c_lbf_per_mph2", "Set Coef C (lbf/mph**2)", float),
    ("aftertreatment_code", "Aftertreatment Device Cd", str),
    ("aftertreatment", "Aftertreatment Device Desc", str),
    ("police_emergency", "Police - Emergency Vehicle?", str),
    ("averaging_group_id", "Averaging Group ID", str),
    ("averaging_weighting_factor", "Averaging Weighting Factor", float),
    ("averaging_method_code", "Averaging Method Cd", str),
    ("averaging_method", "Averging Method Desc", str),
    ("dt_inertia_work_ratio", "DT-Inertia Work Ratio Rating", float),
    ("dt_absolute_speed_change", "DT-Absolute Speed Change Ratg", float),
    ("dt_energy_economy", "DT-Energy Economy Rating", float),
]
_KNOWN_HEADERS = {header for _, header, _ in COLUMNS}
LEGACY_HEADER = "MDLYR_DT"  # first column of the 2007-2009 layout

# EPA's spelling of the brand, upper case -> (brand shown in the app, text the model
# name should start with). Some rows put the model, a test id or a misspelling in the
# make column. A brand of None leaves the row out of the car picker.
_MAKES: dict[str, tuple[str | None, str | None]] = {
    "ACURA": ("Acura", None),
    "ALFA ROMEO": ("Alfa Romeo", None),
    "ASTON MARTIN": ("Aston Martin", None),
    "AUDI": ("Audi", None),
    "AZURE DYNAMICS": ("Azure Dynamics", None),
    "BENTLEY": ("Bentley", None),
    "BLUECAR": ("Bluecar", None),
    "BMW": ("BMW", None),
    "BMX": ("BMW", None),
    "BUGATTI": ("Bugatti", None),
    "BUGATTI RIMAC": ("Bugatti", None),
    "BUICK": ("Buick", None),
    "BYD": ("BYD", None),
    "C40 RECHARGE TWIN": ("Volvo", None),
    "CADILLAC": ("Cadillac", None),
    "CANOO": ("Canoo", None),
    "CHEVROLET": ("Chevrolet", None),
    "CHRYSLER": ("Chrysler", None),
    "CODA": ("CODA", None),
    "CRUISE": (None, None),  # driverless test fleet, not sold
    "CZINGER": ("Czinger", None),
    "DODGE": ("Dodge", None),
    "EPA": (None, None),  # EPA's own test car
    "FARADAY": ("Faraday Future", None),
    "FERRARI": ("Ferrari", None),
    "FIAT": ("Fiat", None),
    "FISKER": ("Fisker", None),
    "FORD": ("Ford", None),
    "GENESIS": ("Genesis", None),
    "GMC": ("GMC", None),
    "HONDA": ("Honda", None),
    "HUMMER": ("Hummer", None),
    "HYUNDAI": ("Hyundai", None),
    "INEOS AUTOMOTIVE LTD": ("INEOS", None),
    "INFINITI": ("Infiniti", None),
    "JAGUAR": ("Jaguar", None),
    "JEEP": ("Jeep", None),
    "KANDI": ("Kandi", None),
    "KARMA": ("Karma", None),
    "KIA": ("Kia", None),
    "KOENIGSEGG": ("Koenigsegg", None),
    "LAMBORGHINI": ("Lamborghini", None),
    "LAND ROVER": ("Land Rover", None),
    "LEXUS": ("Lexus", None),
    "LINCOLN": ("Lincoln", None),
    "LINCOLN-MERCURY": ("Lincoln", None),  # see _MODEL_MAKES for its Ford and Mercury models
    "LORDSTOWN MOTORS": ("Lordstown", None),
    "LOTUS": ("Lotus", None),
    "MAGNUM": ("Dodge", None),
    "MAHINDRA": ("Mahindra", None),
    "MASERATI": ("Maserati", None),
    "MAZDA": ("Mazda", None),
    "MBV": ("Mobility Ventures", None),
    "MCLAREN": ("McLaren", None),
    "MECEDES-BENZ": ("Mercedes-Benz", None),
    "MERCEDES-BENZ": ("Mercedes-Benz", None),
    "MERCURY": ("Mercury", None),
    "MINI": ("MINI", None),
    "MITSUBISHI": ("Mitsubishi", None),
    "MODEL S": ("Tesla", "Model S"),
    "MULLEN": ("Mullen", None),
    "MV": ("Mobility Ventures", None),
    "NISSAN": ("Nissan", None),
    "PAGANI AUTOMOBILI": ("Pagani", None),
    "PAGANI SPA": ("Pagani", None),
    "POLESTAR": ("Polestar", None),
    "POLESTAR 2": ("Polestar", None),
    "POLESTAR2 DUAL MOTOR": ("Polestar", None),
    "PONTIAC": ("Pontiac", None),
    "PORSCHE": ("Porsche", None),
    "QUANTUM IMPALA": ("Quantum", None),
    "RAM": ("Ram", None),
    "RANGE ROVER": ("Land Rover", "Range Rover"),
    "RIMAC": ("Rimac", None),
    "RIVIAN": ("Rivian", None),
    "ROLLS ROYCE": ("Rolls-Royce", None),
    "ROUSH": ("Roush", None),
    "RUF": ("RUF", None),
    "SAAB": ("Saab", None),
    "SATURN": ("Saturn", None),
    "SCION": ("Scion", None),
    "SPYKER": ("Spyker", None),
    "SRT": ("SRT", None),
    "STI": ("Subaru", None),
    "SUBARU": ("Subaru", None),
    "SUZUKI": ("Suzuki", None),
    "TESLA": ("Tesla", None),
    "TESLA MODEL 3": ("Tesla", "Model 3"),
    "TESLA MODEL S": ("Tesla", "Model S"),
    "TESLA MODEL X": ("Tesla", "Model X"),
    "TOYOTA": ("Toyota", None),
    "VINFAST": ("VinFast", None),
    "VOLKSWAGEN": ("Volkswagen", None),
    "VOLVO": ("Volvo", None),
    "VPG": ("VPG", None),
    "VW": ("Volkswagen", None),
    "W204E63-Z1011": ("Mercedes-Benz", None),
}
# Rows filed under one brand whose model belongs to another.
_MODEL_MAKES = {
    ("LINCOLN-MERCURY", "FUSION"): "Ford",
    ("LINCOLN-MERCURY", "GRAND MARQUIS"): "Mercury",
    ("LINCOLN-MERCURY", "MILAN"): "Mercury",
}
# Rows whose make column holds a model year instead of the brand.
_MANUFACTURER_MAKES = {"LUCID USA, INC": "Lucid"}


@dataclass
class SourceFile:
    name: str
    sha256: str
    rows: list[dict] = field(default_factory=list)
    skipped: str | None = None  # why the file wasn't read

    @property
    def model_year(self) -> int | None:
        years = Counter(row["model_year"] for row in self.rows if row["model_year"] is not None)
        return years.most_common(1)[0][0] if years else None


def read_folder(folder: Path) -> list[SourceFile]:
    """Every .csv and .xlsx file in the folder, in name order."""
    paths = sorted(p for p in Path(folder).iterdir() if p.suffix.lower() in (".csv", ".xlsx") and not p.name.startswith("~$"))
    return [read_file(path) for path in paths]


def read_file(path: Path) -> SourceFile:
    source = SourceFile(path.name, hashlib.sha256(path.read_bytes()).hexdigest())
    table = _read_csv(path) if path.suffix.lower() == ".csv" else _read_xlsx(path)
    if not table:
        source.skipped = "empty file"
        return source
    header = [_text(value) or "" for value in table[0]]
    if header and header[0] == LEGACY_HEADER:
        source.skipped = "2007-2009 layout without a brand column"
        return source
    if "Represented Test Veh Make" not in header:
        source.skipped = "not an EPA Test Car List layout"
        return source
    index = {name: i for i, name in enumerate(header) if name}
    for number, values in enumerate(table[1:], start=2):  # row 1 is the header
        if all(_blank(value) for value in values):
            continue
        source.rows.append(_parse_row(path.name, number, index, values))
    return source


def normalize_vehicle(represented_make: str | None, represented_model: str | None, manufacturer: str | None) -> tuple[str | None, str | None]:
    """The (brand, model name) the car picker shows, or (None, None) to leave the row out."""
    if not represented_model:
        return None, None
    raw_make = " ".join((represented_make or "").upper().split())
    raw_model = " ".join(represented_model.upper().split())
    if not raw_make or raw_make.isdigit():
        brand, prefix = _MANUFACTURER_MAKES.get(" ".join((manufacturer or "").upper().split())), None
    elif raw_make in _MAKES:
        brand, prefix = _MAKES[raw_make]
        brand = _MODEL_MAKES.get((raw_make, raw_model), brand)
    else:  # a brand this table doesn't know yet: keep EPA's spelling, title-cased if it's all capitals
        brand, prefix = (represented_make.strip().title() if represented_make.isupper() else represented_make.strip()), None
    if brand is None:
        return None, None
    return brand, _model_name(brand, represented_model, prefix)


def model_key(name: str) -> str:
    """What makes two spellings of a brand or model the same: case and spacing don't count."""
    return " ".join(name.upper().split())


def _model_name(brand: str, model: str, prefix: str | None) -> str:
    name = " ".join(model.replace("”", '"').split())
    if prefix and not name.upper().startswith(prefix.upper()):
        name = f"{prefix} {name}"
    for start in dict.fromkeys((brand.upper(), brand.upper().replace(" ", ""))):
        rest = name[len(start) + 1 :]
        # "MAZDA CX-5" -> "CX-5", but "Polestar 2" and "FERRARI 599 GTB" keep the brand: their name is a number
        if name.upper().startswith(start + " ") and rest[:1].isalpha():
            name = rest
            break
    if brand == "Mazda":  # "Mazda 3" and "MAZDA3" are the same car; Mazda writes it MAZDA3
        name = re.sub(r"^mazda\s+(?=\d)", "MAZDA", name, flags=re.IGNORECASE)
    return name


def _parse_row(file_name: str, number: int, index: dict[str, int], values) -> dict:
    row: dict = {"source_file": file_name, "source_row": number}
    unmapped: dict[str, str] = {}
    for column, header, kind in COLUMNS:
        i = index.get(header)
        raw = values[i] if i is not None and i < len(values) else None
        try:
            row[column] = _value(raw, kind)
        except ValueError:
            row[column] = None
            unmapped[header] = _text(raw)
    for header, i in index.items():
        if header not in _KNOWN_HEADERS and i < len(values) and not _blank(values[i]):
            unmapped[header] = _text(values[i])
    row["unmapped"] = unmapped
    row["make"], row["model"] = normalize_vehicle(row["represented_make"], row["represented_model"], row["manufacturer"])
    return row


def _value(raw, kind: type):
    """The cell as the column's type; None when blank. Raises ValueError when it isn't that type."""
    if kind is str:
        return _text(raw)
    if _blank(raw):
        return None
    if isinstance(raw, bool):
        raise ValueError(raw)
    number = float(raw.replace(",", "")) if isinstance(raw, str) else float(raw)
    if not math.isfinite(number):
        raise ValueError(raw)
    if kind is int:
        if not number.is_integer():
            raise ValueError(raw)
        return int(number)
    return number


def _text(raw) -> str | None:
    if _blank(raw):
        return None
    if isinstance(raw, float) and raw.is_integer():
        raw = int(raw)  # Excel stores some codes and ids as numbers
    return str(raw).strip()


def _blank(raw) -> bool:
    return raw is None or (isinstance(raw, str) and not raw.strip())


def _read_csv(path: Path) -> list[list]:
    data = path.read_bytes()
    for encoding in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            text = data.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    return list(csv.reader(io.StringIO(text, newline="")))


def _read_xlsx(path: Path) -> list[list]:
    import openpyxl  # only the loader reads Excel files; the API never imports this module

    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    try:
        return [list(values) for values in workbook.worksheets[0].iter_rows(values_only=True)]
    finally:
        workbook.close()
