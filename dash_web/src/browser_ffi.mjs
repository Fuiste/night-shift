let activeSource = null;

export function initialRunTarget() {
  const root = document.querySelector("#app");
  const value = root?.dataset?.initialRun ?? "";
  return value.length > 0 ? value : "latest";
}

function respond(response, onSuccess, onError) {
  response
    .text()
    .then((text) => {
      if (response.ok) {
        onSuccess(text);
      } else {
        onError(text || `Request failed: ${response.status}`);
      }
    })
    .catch((error) => onError(String(error)));
}

export function fetchWorkspace(targetRun, onSuccess, onError) {
  const suffix =
    targetRun && targetRun !== "latest"
      ? `?run=${encodeURIComponent(targetRun)}`
      : "";
  fetch(`/api/workspace${suffix}`, { cache: "no-store" })
    .then((response) => respond(response, onSuccess, onError))
    .catch((error) => onError(String(error)));
}

export function fetchModels(provider, onSuccess, onError) {
  fetch(`/api/init/models?provider=${encodeURIComponent(provider)}`, {
    cache: "no-store",
  })
    .then((response) => respond(response, onSuccess, onError))
    .catch((error) => onError(String(error)));
}

export function postJson(path, payload, onSuccess, onError) {
  fetch(path, {
    method: "POST",
    cache: "no-store",
    headers: { "content-type": "application/json" },
    body: payload,
  })
    .then((response) => respond(response, onSuccess, onError))
    .catch((error) => onError(String(error)));
}

export function openEventStream(targetRun, onOpen, onMessage, onError) {
  if (activeSource) {
    activeSource.close();
  }

  const runId = targetRun && targetRun.length > 0 ? targetRun : "latest";
  const source = new EventSource(`/api/runs/${encodeURIComponent(runId)}/events`);
  activeSource = source;

  source.onopen = () => {
    onOpen("connected");
  };

  source.onmessage = (event) => {
    onMessage(event.data);
  };

  source.onerror = () => {
    onError("disconnected");
  };
}
