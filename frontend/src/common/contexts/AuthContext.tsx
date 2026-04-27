import { createContext, useContext, useState, useEffect, ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { authApi, AdminUser, api } from "src/api/client";

function registerPushTokenIfAvailable() {
  if (!window.Android?.getDeviceToken) return;

  // Both iOS and Android expose the bridge under window.Android. The Android
  // WebView appends "MYRAai-Android" to the user-agent so we can tell which
  // OS we're talking to and tag tokens correctly server-side.
  const isAndroid = /MYRAai-Android/.test(navigator.userAgent);
  const platform = isAndroid ? "android" : "ios";

  const fetchAndPostToken = () => {
    const cb = "__myraOnPushToken_" + Date.now();
    window[cb] = (token: string | null) => {
      delete window[cb];
      if (!token) return;
      api.post("/me/device-token", { token, platform }).catch(() => {});
    };
    window.Android!.getDeviceToken!(cb);
  };

  // On Android 13+ POST_NOTIFICATIONS is a runtime permission. The native
  // bridge shows a rationale dialog, then triggers the system prompt, then
  // calls our callback with the result. On older Android and on iOS this
  // is a no-op (the bridge returns granted=true immediately on Android <13;
  // iOS uses a separate flow).
  if (isAndroid && window.Android?.requestNotificationPermission) {
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
