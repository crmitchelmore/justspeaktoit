"""What every loopback route shares: bounds, the JSON log and fragmented JSON text.

`conn` below is the ProbeHandler serving one connection; its send_frame writes
one RFC6455 frame.
"""
import json
import threading

MAX_PAYLOAD = 4 * 1024 * 1024
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOG_LOCK = threading.Lock()


def log(event, **fields):
    with LOG_LOCK:
        print(json.dumps({"event": event, **fields}, sort_keys=True), flush=True)


def send_text(conn, event, fragmented):
    """One JSON text message; fragmented, it splits in three inside a multi-byte
    scalar when there is one, so the client's transport must assemble the
    message before decoding its UTF-8."""
    payload = json.dumps(event, ensure_ascii=False).encode("utf-8")
    if not fragmented:
        conn.send_frame(1, payload)
        return
    split = next((index for index, byte in enumerate(payload) if 0x80 <= byte <= 0xBF), 2)
    conn.send_frame(1, payload[:split], final=False)
    conn.send_frame(0, payload[split:split + 3], final=False)
    conn.send_frame(0, payload[split + 3:])


def send_json(conn, event, request_id="loopback"):
    """One compact JSON text message, split inside a multi-byte UTF-8 scalar when
    it has one, so the client must assemble the message before decoding it. Ink-2
    events name their connection; Rev.ai's and Voice Live's pass request_id=None."""
    body = {**event, "request_id": request_id} if request_id else event
    payload = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    continuation = (index for index, byte in enumerate(payload) if (byte & 0xC0) == 0x80)
    split = max(1, min(next(continuation, len(payload) // 2), len(payload) - 1))
    conn.send_frame(1, payload[:split], final=False)
    conn.send_frame(0, payload[split:])
