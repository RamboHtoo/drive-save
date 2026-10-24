"""Every error leaves the API as {"error": {"code", "message", "details"?}}."""

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

# Fallback codes for errors raised by FastAPI/Starlette themselves (unknown route, wrong method).
_STATUS_CODES = {
    400: "bad_request",
    401: "unauthorized",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
    409: "conflict",
}


class ApiError(Exception):
    """Raise this from route code to return a specific error code to the client."""

    def __init__(self, status_code: int, code: str, message: str):
        self.status_code = status_code
        self.code = code
        self.message = message


def _error(status_code: int, code: str, message: str, details: list | None = None) -> JSONResponse:
    body: dict = {"code": code, "message": message}
    if details:
        body["details"] = details
    return JSONResponse(status_code=status_code, content={"error": body})


async def _api_error(_: Request, exc: ApiError) -> JSONResponse:
    return _error(exc.status_code, exc.code, exc.message)


async def _http_error(_: Request, exc: StarletteHTTPException) -> JSONResponse:
    return _error(exc.status_code, _STATUS_CODES.get(exc.status_code, "http_error"), str(exc.detail))


async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
    details = [{"loc": list(e["loc"]), "msg": e["msg"], "type": e["type"]} for e in exc.errors()]
    message = details[0]["msg"] if details else "Invalid request"
    return _error(422, "validation_error", message, details)


def register_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(ApiError, _api_error)
    app.add_exception_handler(StarletteHTTPException, _http_error)
    app.add_exception_handler(RequestValidationError, _validation_error)
