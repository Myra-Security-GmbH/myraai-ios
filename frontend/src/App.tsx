import { Core } from "@myraui/core";
import { Route, Routes, Navigate } from "react-router-dom";
import { ThemeProvider } from "src/common/contexts/ThemeContext";
import { AuthProvider } from "src/common/contexts/AuthContext";
import AuthGuard from "src/common/components/AuthGuard";
import Sidebar from "src/common/components/sidebar/Sidebar";
import Dashboard from "src/modules/dashboard/pages/Dashboard";
import Monitor from "src/modules/monitor/pages/Monitor";
import Tenants from "src/modules/tenants/pages/Tenants";
import Gateways from "src/modules/gateways/pages/Gateways";
import Logs from "src/modules/logs/pages/Logs";
import ModelPrices from "src/modules/prices/pages/ModelPrices";
import Playground from "src/modules/playground/pages/Playground";
import Users from "src/modules/users/pages/Users";
import TenantAnalytics from "src/modules/analytics/pages/TenantAnalytics";
import LoginPage from "src/pages/LoginPage";
import Organizations from "src/pages/OrganizationsPage";

function AppShell() {
  return (
    <div style={{ display: "flex", minHeight: "100dvh" }}>
      <Sidebar />
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0, overflowX: "hidden", backgroundColor: "var(--content-bg)" }}>
        <Routes>
          <Route path="/" element={<Navigate to="/dashboard" replace />} />
          <Route path="/dashboard" element={<Dashboard />} />
          <Route path="/monitor" element={<Monitor />} />
          <Route path="/tenants" element={<Tenants />} />
          <Route path="/tenants/:tenantId" element={<Tenants />} />
          <Route path="/tenants/:tenantId/gateways" element={<Gateways />} />
          <Route path="/tenants/:tenantId/gateways/:gatewayId" element={<Gateways />} />
          <Route path="/gateways" element={<Gateways />} />
          <Route path="/users" element={<Users />} />
          <Route path="/users/:userId" element={<Users />} />
          <Route path="/logs" element={<Logs />} />
          <Route path="/analytics" element={<TenantAnalytics />} />
          <Route path="/playground" element={<Playground />} />
          <Route path="/model-prices" element={<ModelPrices />} />
          <Route path="/organizations" element={<Organizations />} />
        </Routes>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <Core>
      <ThemeProvider>
        <AuthProvider>
          <Routes>
            <Route path="/login" element={<LoginPage />} />
            <Route path="/*" element={
              <AuthGuard>
                <AppShell />
              </AuthGuard>
            } />
          </Routes>
        </AuthProvider>
      </ThemeProvider>
    </Core>
  );
}
