import { Component, ErrorInfo, ReactNode } from "react";
import { reportError } from "src/common/utils/reportError";

interface Props { children: ReactNode; }
interface State { hasError: boolean; message: string; }

export class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false, message: "" };

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, message: error.message };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    reportError(error.message, (error.stack ?? "") + "\n" + (info.componentStack ?? ""));
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={{ padding: 40, fontFamily: "sans-serif" }}>
          <h2 style={{ color: "#dc2626" }}>Something went wrong</h2>
          <pre style={{ fontSize: 12, color: "#555", whiteSpace: "pre-wrap" }}>{this.state.message}</pre>
          <button onClick={() => this.setState({ hasError: false, message: "" })}
            style={{ marginTop: 16, padding: "8px 16px", cursor: "pointer" }}>
            Try again
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}
