import { createContext, useContext, useState, useEffect, ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { authApi, AdminUser, api } from "src/api/client";

function registerPushTokenIfAvailable() {
  const ua = navigator.userAgent;
  const isAndroid = /MYRAai-Android/.test(ua);
  const isIOS     = /MYRAai-iOS/.test(ua);
  if (!isAndroid && !isIOS) return;

  const platform = isAndroid ? "android" : "ios";
  const post = (token: string) => {
    api.post("/me/device-token", { token, platform }).catch(() => {});
  };

  if (isIOS) {
    // iOS pushes the token in: AppDelegate sets window.__myraApnsToken and
    // dispatches a 'myra:apns-token' CustomEvent on every page-load. Either
    // path may win the race depending on whether the token arrived before
    // or after the WebView finished navigating.
    if (typeof window.__myraApnsToken === "string" && window.__myraApnsToken) {
      post(window.__myraApnsToken);
      return;
    }
    window.addEventListener("myra:apns-token", (e: Event) => {
      const detail = (e as CustomEvent<{ token?: string }>).detail;
      if (detail?.token) post(detail.token);
    }, { once: true });
    return;
  }

  // Android: callback-pull. POST_NOTIFICATIONS is a runtime permission on
  // Android 13+; the native bridge shows the rationale + system prompt and
  // calls back with the granted bool. On Android <13 it returns true
  // immediately.
  if (!window.Android?.getDeviceToken) return;
  const fetchAndPostToken = () => {
    const cb = "__myraOnPushToken_" + Date.now();
    window[cb] = (token: string | null) => {
      delete window[cb];
      if (token) post(token);
    };
    window.Android!.getDeviceToken!(cb);
  };
  if (window.Android.requestNotificationPermission) {
    const cb = "__myraOnNotifPerm_" + Date.now();
    window[cb] = (granted: boolean) => {
      delete window[cb];
      if (granted) fetchAndPostToken();
    };
    window.Android.requestNotificationPermission(cb);
  } else {
    fetchAndPostToken();
  }
}

interface AuthContextValue {
  user: AdminUser | null;
  loading: boolean;
  login: (user: AdminUser) => void;
  logout: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue>({
  user: null,
  loading: true,
  login: () => {},
  logout: async () => {},
});

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser]     = useState<AdminUser | null>(null);
  const [loading, setLoading] = useState(true);
  const navigate = useNavigate();

  useEffect(() => {
    authApi.me()
      .then((u) => { setUser(u); registerPushTokenIfAvailable(); })
      .catch(() => setUser(null))
      .finally(() => setLoading(false));
  }, []);

  function login(userData: AdminUser) {
    setUser(userData);
    registerPushTokenIfAvailable();
  }

  async function logout() {
    await authApi.logout().catch(() => {});
    setUser(null);
    navigate("/login", { replace: true });
  }

  return (
    <AuthContext.Provider value={{ user, loading, login, logout }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}
