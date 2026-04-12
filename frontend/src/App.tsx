// @myraui packages in use:
//   @myraui/core    — loaded here as <Core> to inject global styles
//   @myraui/styles  — imported in Layout.module.scss for design tokens
//   @myraui/utils   — getCyDataId used in Sidebar and LoginPage for data-cy attributes
//   @myraui/badge   — available for notification count indicators (number overlaid on an icon,
//                     e.g. unread count on a sidebar item). Import Badge from "@myraui/badge"
//                     when adding such indicators. Do NOT confuse with <StatusBadge> (colored
//                     text pill in src/common/components/StatusBadge.tsx).
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
import Profile from "src/modules/profile/pages/Profile";
import Commands from "src/modules/commands/pages/Commands";
import MCPConnectors from "src/modules/mcp/pages/MCPConnectors";
import Chat from "src/modules/chat/pages/Chat";
import Projects from "src/modules/projects/pages/Projects";
import LoginPage from "src/pages/LoginPage";
import SharedConversation from "src/pages/SharedConversation";
import DebugPage from "src/pages/DebugPage";

function AppShell() {
  return (
    <div style={{ display: "flex", minHeight: "100vh" }}>
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
          <Route path="/chat" element={<Chat />} />
          <Route path="/projects" element={<Projects />} />
          <Route path="/projects/:projectId" element={<Projects />} />
          <Route path="/model-prices" element={<ModelPrices />} />
          <Route path="/profile" element={<Profile />} />
          <Route path="/commands" element={<Commands />} />
          <Route path="/mcp" element={<MCPConnectors />} />
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
            <Route path="/debug" element={<DebugPage />} />
            <Route path="/shared/:token" element={<SharedConversation />} />
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
