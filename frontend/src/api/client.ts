const BASE = import.meta.env.VITE_ADMIN_URL ?? "/admin/v1";

async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(err.error ?? "Request failed");
  }
  if (res.status === 204) return undefined as T;
  return res.json();
}

export const api = {
  get:    <T>(path: string) => apiFetch<T>(path),
  post:   <T>(path: string, body: unknown) => apiFetch<T>(path, { method: "POST",   body: JSON.stringify(body) }),
  put:    <T>(path: string, body: unknown) => apiFetch<T>(path, { method: "PUT",    body: JSON.stringify(body) }),
  patch:  <T>(path: string, body: unknown) => apiFetch<T>(path, { method: "PATCH",  body: JSON.stringify(body) }),
  delete: <T>(path: string)               => apiFetch<T>(path, { method: "DELETE" }),
};
