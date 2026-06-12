"""
REST API Layer for SAP Datasphere MCP Server
=============================================
Exposes MCP tools as standard REST endpoints so that:
  - M365 Copilot Studio  → imports /openapi.json and calls /api/tools/{tool_name}
  - Gemini Enterprise    → calls /api/tools/{tool_name} directly via REST
  - Claude Client        → uses native MCP over Streamable HTTP (/mcp)

Endpoints:
  GET  /health              — liveness probe
  GET  /api/tools           — list all available tools (name + description)
  POST /api/tools/{name}    — invoke a tool by name, body = { "arguments": {...} }
  GET  /openapi.json        — OpenAPI 3.0 spec (auto-generated from tool list)

Authentication (optional, same token as MCP layer):
  Header: Authorization: Bearer <MCP_HTTP_AUTH_TOKEN>

Usage:
  Import build_rest_app() into sap_datasphere_mcp_server.py and mount
  the returned Starlette sub-application at /api and /openapi.json.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any, Callable, Coroutine

logger = logging.getLogger("sap-datasphere-rest")


# ---------------------------------------------------------------------------
# Factory: call this once you have a reference to the MCP Server object and
# the call_tool coroutine (the same handler registered with @server.call_tool)
# ---------------------------------------------------------------------------

def build_rest_app(
    call_tool_fn: Callable[[str, dict], Coroutine],
    list_tools_fn: Callable[[], Coroutine],
    auth_token: str | None = None,
    public_base_url: str = "",
):
    """
    Build and return a Starlette application that wraps the MCP tools as REST.

    Parameters
    ----------
    call_tool_fn  : async (name: str, arguments: dict) -> list[TextContent]
    list_tools_fn : async () -> list[Tool]
    auth_token    : if set, every request must carry  Authorization: Bearer <token>
    public_base_url : used in the OpenAPI spec server URL (e.g. https://mcp.example.com)
    """
    from starlette.applications import Starlette
    from starlette.routing import Route, Mount
    from starlette.requests import Request
    from starlette.responses import JSONResponse, Response
    from starlette.middleware import Middleware
    from starlette.middleware.base import BaseHTTPMiddleware

    # ── Auth middleware ───────────────────────────────────────────────────
    class BearerAuthMiddleware(BaseHTTPMiddleware):
        async def dispatch(self, request: Request, call_next):
            # Health and OpenAPI spec are always public
            if request.url.path in ("/health", "/openapi.json"):
                return await call_next(request)
            if auth_token:
                header = request.headers.get("authorization", "")
                if not header.startswith("Bearer ") or header[7:] != auth_token:
                    return JSONResponse({"error": "unauthorized"}, status_code=401)
            return await call_next(request)

    # ── Helpers ───────────────────────────────────────────────────────────
    def _content_to_text(content_list) -> Any:
        """Convert MCP TextContent list → plain value for JSON response."""
        if not content_list:
            return None
        texts = []
        for item in content_list:
            if hasattr(item, "text"):
                texts.append(item.text)
            elif isinstance(item, dict):
                texts.append(item.get("text", str(item)))
        combined = "\n".join(texts)
        # Try to parse as JSON so callers get structured data
        try:
            return json.loads(combined)
        except (json.JSONDecodeError, TypeError):
            return combined

    # ── Endpoint handlers ─────────────────────────────────────────────────
    async def health(request: Request):
        return JSONResponse({"status": "ok", "transport": "rest"})

    async def list_tools(request: Request):
        try:
            tools = await list_tools_fn()
            return JSONResponse({
                "tools": [
                    {
                        "name": t.name,
                        "description": t.description or "",
                        "inputSchema": t.inputSchema if hasattr(t, "inputSchema") else {},
                    }
                    for t in tools
                ]
            })
        except Exception as exc:
            logger.exception("Error listing tools")
            return JSONResponse({"error": str(exc)}, status_code=500)

    async def invoke_tool(request: Request):
        tool_name = request.path_params.get("tool_name", "")
        try:
            body = await request.json()
        except Exception:
            body = {}

        arguments = body.get("arguments", body)  # accept flat body too

        try:
            result = await call_tool_fn(tool_name, arguments)
            return JSONResponse({"result": _content_to_text(result)})
        except Exception as exc:
            logger.exception(f"Error invoking tool {tool_name!r}")
            return JSONResponse({"error": str(exc)}, status_code=500)

    async def openapi_spec(request: Request):
        """Dynamically generate OpenAPI 3.0 spec from live tool list."""
        try:
            tools = await list_tools_fn()
        except Exception:
            tools = []

        base_url = public_base_url or str(request.base_url).rstrip("/")

        paths: dict = {}
        for tool in tools:
            input_schema = {}
            if hasattr(tool, "inputSchema") and tool.inputSchema:
                input_schema = dict(tool.inputSchema)

            path = f"/api/tools/{tool.name}"
            paths[path] = {
                "post": {
                    "operationId": tool.name,
                    "summary": (tool.description or tool.name)[:120],
                    "description": tool.description or "",
                    "requestBody": {
                        "required": True,
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "properties": {
                                        "arguments": input_schema or {"type": "object"}
                                    },
                                    "required": ["arguments"],
                                }
                            }
                        },
                    },
                    "responses": {
                        "200": {
                            "description": "Successful tool result",
                            "content": {
                                "application/json": {
                                    "schema": {
                                        "type": "object",
                                        "properties": {
                                            "result": {"description": "Tool output (string or object)"}
                                        },
                                    }
                                }
                            },
                        },
                        "400": {"description": "Bad request / invalid arguments"},
                        "401": {"description": "Unauthorized — missing or wrong bearer token"},
                        "500": {"description": "Internal server error"},
                    },
                    "security": [{"bearerAuth": []}] if auth_token else [],
                }
            }

        spec = {
            "openapi": "3.0.3",
            "info": {
                "title": "SAP Datasphere MCP — REST API",
                "version": "1.0.0",
                "description": (
                    "REST wrapper around the SAP Datasphere MCP server. "
                    "Each endpoint corresponds to one MCP tool. "
                    "Used by M365 Copilot Studio and Gemini Enterprise."
                ),
            },
            "servers": [{"url": base_url, "description": "MCP Server"}],
            "components": {
                "securitySchemes": {
                    "bearerAuth": {
                        "type": "http",
                        "scheme": "bearer",
                        "bearerFormat": "opaque",
                    }
                }
            },
            "paths": paths,
        }

        return Response(
            content=json.dumps(spec, ensure_ascii=False, indent=2),
            media_type="application/json",
        )

    # ── Route table ───────────────────────────────────────────────────────
    middleware = [Middleware(BearerAuthMiddleware)] if True else []  # always add, checks token internally

    app = Starlette(
        routes=[
            Route("/health", endpoint=health, methods=["GET"]),
            Route("/openapi.json", endpoint=openapi_spec, methods=["GET"]),
            Route("/api/tools", endpoint=list_tools, methods=["GET"]),
            Route("/api/tools/{tool_name}", endpoint=invoke_tool, methods=["POST"]),
        ],
        middleware=middleware,
    )
    return app
