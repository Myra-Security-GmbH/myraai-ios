import { useState, useEffect } from "react";
import { createPortal } from "react-dom";
import { NavLink } from "react-router-dom";
import { getCyDataId } from "@myraui/utils";
import { useTheme } from "src/common/contexts/ThemeContext";
import { useAuth } from "src/common/contexts/AuthContext";
import { docsUrl } from "src/common/components/DocLink";
import styles from "./Sidebar.module.scss";

const cyId = getCyDataId("sidebar");

function NavIcon({ children }: { children: React.ReactNode }) {
  return <span className={styles["nav-icon"]}>{children}</span>;
}

function SunIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="5" />
      <line x1="12" y1="1" x2="12" y2="3" /><line x1="12" y1="21" x2="12" y2="23" />
      <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" /><line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
      <line x1="1" y1="12" x2="3" y2="12" /><line x1="21" y1="12" x2="23" y2="12" />
      <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" /><line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
    </svg>
  );
}
function MoonIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
    </svg>
  );
}
function ChevronLeftIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="15 18 9 12 15 6" /></svg>;
}
function ChevronRightIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="9 18 15 12 9 6" /></svg>;
}
function HamburgerIcon() {
  return <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><line x1="3" y1="6" x2="21" y2="6" /><line x1="3" y1="12" x2="21" y2="12" /><line x1="3" y1="18" x2="21" y2="18" /></svg>;
}
function XIcon() {
  return <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" /></svg>;
}

// Simple inline icons for nav items
function DashboardIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>;
}
function TenantsIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>;
}
function GatewayIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/></svg>;
}
function LogsIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg>;
}
function MonitorIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>;
}
function UsersIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>;
}
function PricesIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/></svg>;
}
function PlaygroundIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polygon points="5 3 19 12 5 21 5 3"/></svg>;
}
function AnalyticsIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>;
}
function ChatIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>;
}
function ProjectsIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>;
}
function TokenIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>;
}

function CommandsIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>;
}
function LogoutIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>;
}
function DocsIcon() {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>;
}

function SectionLabel({ label, collapsed }: { label: string; collapsed: boolean }) {
  if (collapsed) return <div className={styles["section-divider"]} />;
  return <span className={styles["section-label"]}>{label}</span>;
}

function NavItem({ to, label, icon, collapsed, onMobileClose }: { to: string; label: string; icon: React.ReactNode; collapsed: boolean; onMobileClose?: () => void }) {
  return (
    <NavLink
      to={to}
      onClick={onMobileClose}
      className={({ isActive }) =>
        [styles["nav-item"], isActive ? styles["active"] : ""].filter(Boolean).join(" ")
      }
      title={collapsed ? label : undefined}
      data-cy={cyId(`nav-${label.toLowerCase().replace(/\s+/g, "-")}`)}
    >
      <NavIcon>{icon}</NavIcon>
      {!collapsed && <span className={styles["nav-label"]}>{label}</span>}
    </NavLink>
  );
}

export default function Sidebar() {
  const { theme, toggleTheme } = useTheme();
  const { user, logout } = useAuth();
  const [collapsed, setCollapsed] = useState(
    () => localStorage.getItem("aig-sidebar-collapsed") === "true"
  );
  const [mobileOpen, setMobileOpen] = useState(false);

  function toggleCollapsed() {
    setCollapsed((v) => {
      const next = !v;
      localStorage.setItem("aig-sidebar-collapsed", String(next));
      return next;
    });
  }

  function closeMobile() { setMobileOpen(false); }

  // Lock body scroll while mobile sidebar is open
  useEffect(() => {
    if (mobileOpen) document.body.style.overflow = "hidden";
    else document.body.style.overflow = "";
    return () => { document.body.style.overflow = ""; };
  }, [mobileOpen]);

  // On mobile the drawer is always full-width, so never treat it as collapsed.
  const effectiveCollapsed = collapsed && !mobileOpen;
  const navProps = { collapsed: effectiveCollapsed, onMobileClose: closeMobile };

  return (
    <>
      {/* Hamburger trigger — portaled to body so it is never clipped by the sidebar's transform */}
      {createPortal(
        <button
          className={styles["mobile-trigger"]}
          onClick={() => setMobileOpen(true)}
          aria-label="Open navigation menu"
          style={mobileOpen ? { display: "none" } : undefined}
        >
          <HamburgerIcon />
        </button>,
        document.body
      )}

      {/* Dim overlay — tapping it closes the sidebar */}
      {mobileOpen && createPortal(
        <div className={styles["mobile-overlay"]} onClick={closeMobile} />,
        document.body
      )}

      <nav
        className={[
          styles["sidebar"],
          collapsed ? styles["sidebar--collapsed"] : "",
          mobileOpen ? styles["sidebar--mobile-open"] : "",
        ].filter(Boolean).join(" ")}
        data-theme={theme}
      >
        <div className={styles["header"]}>
          {effectiveCollapsed ? (
            <div className={styles["header-icon"]}>
              <img src="/favicon.svg" width="24" height="24" alt="Logo" />
            </div>
          ) : (
            <img src="/logo.svg" alt="AI Gateway by Myra Security" className={styles["header-logo"]} />
          )}
          {/* Close button — visible only on mobile */}
          <button className={styles["mobile-close"]} onClick={closeMobile} aria-label="Close menu">
            <XIcon />
          </button>
        </div>

        <div className={styles["nav-sections"]}>
          <SectionLabel label="MAIN" collapsed={effectiveCollapsed} />
          <NavItem to="/dashboard" label="Dashboard" icon={<DashboardIcon />} {...navProps} />
          <NavItem to="/chat" label="Chat" icon={<ChatIcon />} {...navProps} />
          <NavItem to="/projects" label="Projects" icon={<ProjectsIcon />} {...navProps} />
          <NavItem to="/playground" label="Playground" icon={<PlaygroundIcon />} {...navProps} />

          {(user?.role === "admin" || user?.role === "tenant_admin") && (<>
            <SectionLabel label="MANAGEMENT" collapsed={effectiveCollapsed} />
            <NavItem to="/tenants" label="Tenants" icon={<TenantsIcon />} {...navProps} />
            <NavItem to="/gateways" label="Gateways" icon={<GatewayIcon />} {...navProps} />
            <NavItem to="/users" label="Users" icon={<UsersIcon />} {...navProps} />
          </>)}

          <SectionLabel label="OBSERVABILITY" collapsed={effectiveCollapsed} />
          <NavItem to="/analytics" label="Cost Analytics" icon={<AnalyticsIcon />} {...navProps} />
          <NavItem to="/monitor" label="Live Monitor" icon={<MonitorIcon />} {...navProps} />
          <NavItem to="/logs" label="Request Logs" icon={<LogsIcon />} {...navProps} />

          <SectionLabel label="CONFIG" collapsed={effectiveCollapsed} />
          <NavItem to="/model-prices" label="Model Prices" icon={<PricesIcon />} {...navProps} />

          <SectionLabel label="ACCOUNT" collapsed={effectiveCollapsed} />
          <NavItem to="/profile" label="My Tokens" icon={<TokenIcon />} {...navProps} />
          <NavItem to="/commands" label="My Commands" icon={<CommandsIcon />} {...navProps} />
        </div>

        <div className={`${styles["bottom-bar"]} ${effectiveCollapsed ? styles["bottom-bar--collapsed"] : ""}`}>
          <a className={styles["bottom-btn"]} href={docsUrl("/")} target="_blank" rel="noopener noreferrer" title="Documentation">
            <DocsIcon />
          </a>
          <button className={styles["bottom-btn"]} onClick={toggleTheme} title={theme === "dark" ? "Light mode" : "Dark mode"}>
            {theme === "dark" ? <SunIcon /> : <MoonIcon />}
          </button>
          <button className={styles["bottom-btn"]} onClick={logout} title="Sign out">
            <LogoutIcon />
          </button>
          <button className={styles["bottom-btn"]} onClick={toggleCollapsed} title={collapsed ? "Expand" : "Collapse"}>
            {collapsed ? <ChevronRightIcon /> : <ChevronLeftIcon />}
          </button>
        </div>
      </nav>
    </>
  );
}
