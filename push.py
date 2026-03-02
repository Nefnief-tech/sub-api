"""
In-process WebSocket push server.

Exposes a /stream endpoint that is API-compatible with Gotify's client stream,
so the Flutter app can connect directly without needing a separate Gotify server.

Message format sent to clients:
  {"id": <int>, "title": "...", "message": "...", "priority": <int>}
"""
import asyncio
import json
import logging
from typing import Set

from fastapi import WebSocket, WebSocketDisconnect

log = logging.getLogger(__name__)

_msg_counter = 0


class WebSocketManager:
    def __init__(self):
        self._clients: Set[WebSocket] = set()
        self._loop: asyncio.AbstractEventLoop | None = None

    def set_loop(self, loop: asyncio.AbstractEventLoop):
        self._loop = loop

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self._clients.add(ws)
        log.info("Push client connected (%d total)", len(self._clients))

    def disconnect(self, ws: WebSocket):
        self._clients.discard(ws)
        log.info("Push client disconnected (%d total)", len(self._clients))

    async def _broadcast(self, payload: dict):
        dead: Set[WebSocket] = set()
        for ws in set(self._clients):
            try:
                await ws.send_text(json.dumps(payload, ensure_ascii=False))
            except Exception:
                dead.add(ws)
        self._clients -= dead

    def broadcast_sync(self, title: str, message: str, priority: int = 5):
        """Thread-safe broadcast callable from sync (scheduler) threads."""
        if not self._loop or not self._clients:
            return
        global _msg_counter
        _msg_counter += 1
        payload = {"id": _msg_counter, "title": title, "message": message, "priority": priority}
        asyncio.run_coroutine_threadsafe(self._broadcast(payload), self._loop)
        log.debug("Broadcast push: %s", title)


manager = WebSocketManager()
