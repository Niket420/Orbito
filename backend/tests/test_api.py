import time

from tests.conftest import TOKEN, make_client, wav_bytes


def wait_for(client, task_id, predicate, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get(f"/tasks/{task_id}").json()
        if predicate(body):
            return body
        time.sleep(0.02)
    raise AssertionError(f"timed out; last state: {body}")


def test_health_is_public():
    with make_client() as c:
        r = c.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"
    assert r.json()["llm_provider"] == "mock"


def test_tasks_require_token():
    with make_client() as c:
        assert c.post("/tasks", json={"instruction": "open Safari"}).status_code == 401
        r = c.get("/tasks/" + "0" * 32, headers={"Authorization": "Bearer wrong"})
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "unauthorized"


def test_rejects_non_loopback_host_header():
    with make_client() as c:
        r = c.get("/health", headers={"Host": "evil.example.com"})
    assert r.status_code == 400


def test_create_task_validates_input(client):
    assert client.post("/tasks", json={"instruction": "   "}).status_code == 422
    assert client.post("/tasks", json={}).status_code == 422
    r = client.post("/tasks", json={"instruction": "hi", "shell": "rm -rf /"})
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "invalid_request"


def test_full_task_lifecycle(client):
    r = client.post("/tasks", json={"instruction": "Open Safari and search for AI news."})
    assert r.status_code == 201
    created = r.json()
    assert created["status"] == "pending"
    assert created["message"] == "Task created"
    task_id = created["task_id"]

    body = wait_for(client, task_id, lambda b: b["next_action"] is not None)
    assert body["status"] == "running"
    assert [a["type"] for a in body["actions"]] == ["open_application", "search_web"]

    for _ in range(2):
        action = body["next_action"]
        r = client.post(
            f"/tasks/{task_id}/actions/{action['action_id']}/result",
            json={"attempt": action["attempt"], "success": True, "observation": "ok"},
        )
        assert r.status_code == 200
        body = r.json()

    assert body["status"] == "completed"
    assert body["result"]
    assert body["next_action"] is None


def test_only_one_active_task(client):
    first = client.post("/tasks", json={"instruction": "open Safari"}).json()
    r = client.post("/tasks", json={"instruction": "open Notes"})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "task_active"
    client.post(f"/tasks/{first['task_id']}/cancel")
    assert client.post("/tasks", json={"instruction": "open Notes"}).status_code == 201


def test_cancel_task(client):
    task_id = client.post("/tasks", json={"instruction": "open Safari"}).json()["task_id"]
    r = client.post(f"/tasks/{task_id}/cancel")
    assert r.status_code == 200
    assert r.json()["status"] == "cancelled"
    # Cancelling again is idempotent.
    assert client.post(f"/tasks/{task_id}/cancel").json()["status"] == "cancelled"


def test_unknown_task_is_404(client):
    r = client.get("/tasks/" + "a" * 32)
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "not_found"
    assert client.get("/tasks/not-a-valid-id").status_code == 422


def test_approval_flow(client):
    task_id = client.post("/tasks", json={"instruction": "type hello world"}).json()["task_id"]
    body = wait_for(client, task_id, lambda b: b["status"] == "waiting_for_approval")
    assert body["next_action"] is None  # nothing executes before approval

    body = client.post(f"/tasks/{task_id}/approval", json={"approved": True}).json()
    assert body["status"] == "running"
    assert body["next_action"]["type"] == "type_text"


def test_declining_approval_cancels(client):
    task_id = client.post("/tasks", json={"instruction": "press command t"}).json()["task_id"]
    wait_for(client, task_id, lambda b: b["status"] == "waiting_for_approval")
    body = client.post(f"/tasks/{task_id}/approval", json={"approved": False}).json()
    assert body["status"] == "cancelled"


def test_stale_action_result_is_rejected(client):
    task_id = client.post("/tasks", json={"instruction": "open Safari"}).json()["task_id"]
    body = wait_for(client, task_id, lambda b: b["next_action"] is not None)
    action = body["next_action"]
    url = f"/tasks/{task_id}/actions/{action['action_id']}/result"
    assert client.post(url, json={"attempt": 5, "success": True}).status_code == 409
    assert client.post(url, json={"attempt": 1, "success": True}).status_code == 200
    assert client.post(url, json={"attempt": 1, "success": True}).status_code == 409


def test_transcribe(client):
    r = client.post("/speech/transcribe", content=wav_bytes(), headers={"Content-Type": "audio/wav"})
    assert r.status_code == 200
    assert r.json()["provider"] == "mock"
    assert r.json()["duration_seconds"] == 0.5


def test_transcribe_rejects_bad_audio(client):
    r = client.post("/speech/transcribe", content=b"nope", headers={"Content-Type": "audio/wav"})
    assert r.status_code == 422
    r = client.post(
        "/speech/transcribe", content=wav_bytes(rate=44_100), headers={"Content-Type": "audio/wav"}
    )
    assert r.status_code == 422
    r = client.post("/speech/transcribe", content=wav_bytes(), headers={"Content-Type": "text/plain"})
    assert r.status_code == 415


def test_token_header_is_case_sensitive():
    with make_client() as c:
        r = c.get("/tasks/" + "a" * 32, headers={"Authorization": f"Bearer {TOKEN.upper()}"})
    assert r.status_code == 401
