import { createContext, useContext, useState, useEffect, ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { authApi, AdminUser, api } from "src/api/client";

function registerPushTokenIfAvailable() {
  if (!window.Android?.getDeviceToken) return;
  const cb = "__myraOnPushToken_" + Date.now();
  window[cb] = (token: string | null) => {
    delete window[cb];
    if (!token) return;
    api.post("/me/device-token", { token, platform: "ios" }).catch(() => {});
  };
  window.Android.getDeviceToken(cb);
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
