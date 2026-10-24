"""The driver's car, exactly as the app sends it.

The app picks the car from the EPA dataset and sends that car's fields. The
backend never reads or reshapes them: it stores the object and hands it to the
cost model unchanged, so field names are agreed between the app and the model.
"""

import json

from pydantic import JsonValue, RootModel, model_validator

MAX_FIELDS = 200
MAX_BYTES = 20_000


class VehicleData(RootModel[dict[str, JsonValue]]):
    @model_validator(mode="after")
    def check_size(self) -> "VehicleData":
        if not self.root:
            raise ValueError("vehicle data needs at least one field")
        if len(self.root) > MAX_FIELDS:
            raise ValueError(f"vehicle data can have at most {MAX_FIELDS} fields")
        try:
            encoded = json.dumps(self.root, allow_nan=False)
        except ValueError:
            raise ValueError("vehicle data can't contain NaN or infinity") from None
        if len(encoded) > MAX_BYTES:
            raise ValueError(f"vehicle data must be under {MAX_BYTES} bytes")
        return self
