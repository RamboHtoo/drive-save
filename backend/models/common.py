from pydantic import BaseModel


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
