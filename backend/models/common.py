from typing import Annotated

from pydantic import AfterValidator, BaseModel, StringConstraints


def storable_text(value: str) -> str:
    """Rejects text Postgres can't store: NUL characters, and lone surrogates (not valid UTF-8)."""
    if "\x00" in value:
        raise ValueError("text can't contain NUL characters")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise ValueError("text must be valid Unicode") from None
    return value


# Text that goes into the database as sent.
Text = Annotated[str, AfterValidator(storable_text)]


def display_name(max_length: int) -> type[str]:
    """A display name: surrounding whitespace removed, then 1 to max_length characters, as the schema's checks expect."""
    return Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=max_length), AfterValidator(storable_text)]


class ErrorDetail(BaseModel):
    loc: list[str | int]
    msg: str
    type: str


class ErrorBody(BaseModel):
    code: str
    message: str
    details: list[ErrorDetail] | None = None


class ErrorResponse(BaseModel):
    error: ErrorBody


class Health(BaseModel):
    status: str
    version: str
    database: str
    schema_version: int | None
