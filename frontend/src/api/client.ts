const BASE     = import.meta.env.VITE_ADMIN_URL ?? "/admin/v1";
const AUTH_BASE = import.meta.env.VITE_AUTH_URL  ?? "/admin/auth";

function networkError(): Error {
  return new Error("Could not reach the server. Check your connection and try again.");
}

async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${BASE}${path}`, {
      ...init,
      credentials: "include",
      headers: {
        "Content-Type": "application/json",
        ...(init?.headers ?? {}),
      },
    });
  } catch {
    throw networkError();
  }
  if (res.status === 401) {
    // Redirect to login, preserving the intended destination
    window.location.href = "/login";
    throw new Error("unauthenticated");
  }
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(err.error ?? "Request failed");
  }
  if (res.status === 204) return undefined as T;
  return res.json();
}

async function authFetch<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${AUTH_BASE}${path}`, {
      ...init,
      credentials: "include",
      headers: {
        "Content-Type": "application/json",
        ...(init?.headers ?? {}),
      },
    });
  } catch {
    throw networkError();
  }
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

export const authApi = {
  me:          () => authFetch<AdminUser>("/me"),
  logout:      () => authFetch<{ ok: boolean }>("/logout", { method: "POST" }),
  otpRequest:  (email: string) => authFetch<{ message: string }>("/otp/request", { method: "POST", body: JSON.stringify({ email }) }),
  otpVerify:   (email: string, code: string, rememberMe = false) => authFetch<{ user: AdminUser }>("/otp/verify", { method: "POST", body: JSON.stringify({ email, code, remember_me: rememberMe }) }),
};

export interface AdminUser {
  id:        string;
  email:     string;
  role:      "admin" | "tenant_admin" | "member" | "viewer";
  tenant_id: string | null;
}
