import './global.scss';
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import { ErrorBoundary } from "src/common/components/ErrorBoundary";
import { reportError } from "src/common/utils/reportError";

// Tag <html> for the Android WebView so safe-area CSS variables
// resolve to 0 — see global.scss for the full reasoning.
if (/MYRAai-Android/.test(navigator.userAgent)) {
  document.documentElement.classList.add("aig-android");
}

window.addEventListener("error", (e) => {
  reportError(e.message ?? "Uncaught error", e.error?.stack);
});

window.addEventListener("unhandledrejection", (e) => {
  const msg = e.reason instanceof Error ? e.reason.message : String(e.reason ?? "Unhandled rejection");
  const stack = e.reason instanceof Error ? e.reason.stack : undefined;
  reportError(msg, stack);
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <BrowserRouter>
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </BrowserRouter>
  </StrictMode>
);
