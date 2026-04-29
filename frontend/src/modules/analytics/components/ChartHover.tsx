import {
  useState,
  useRef,
  useCallback,
  useEffect,
  useLayoutEffect,
  type MutableRefObject,
  type ReactNode,
  type MouseEvent as ReactMouseEvent,
} from "react";

// ─────────────────────────────────────────────────────────────────────────────
// Hover primitives shared by analytics charts (OverviewChart, BarChart).
//
// Why a hook + a sibling tooltip component, not a single wrapper:
//  • Charts render their own SVG geometry (bars, polylines). The hook gives
//    them access to the hovered index + the bind/onLeave/togglePin handlers
//    they need to spread on hit-target rects, without dictating layout.
//  • The tooltip is a separate <div> on `position: absolute`. It's positioned
//    imperatively (transform: translate(...)) by writing to a ref on every
//    mousemove. setState is only called when the hovered column changes, so
//    sweeping the cursor across 30 columns is one re-render per column,
//    not one per pixel.
//  • The wrapper div (chart card) must be `position: relative` so the
//    tooltip's absolute coords resolve to the chart container, not the
//    viewport — survives page scroll without extra listeners.
// ─────────────────────────────────────────────────────────────────────────────

type Pos = { x: number; y: number };

export type ChartHoverApi = {
  hovered: number | null;
  pinned: boolean;
  posRef: MutableRefObject<Pos>;
  bind: (i: number) => {
    onMouseEnter: (e: ReactMouseEvent) => void;
    onMouseMove: (e: ReactMouseEvent) => void;
    onFocus: () => void;
    onBlur: () => void;
    tabIndex: 0;
    role: "img";
  };
  onLeave: () => void;
  togglePin: (i: number) => void;
};

export function useChartHover(): ChartHoverApi {
  const [hovered, setHovered] = useState<number | null>(null);
  const [pinned, setPinned] = useState(false);
  const posRef = useRef<Pos>({ x: 0, y: 0 });

  const bind = useCallback((i: number) => ({
    onMouseEnter: (e: ReactMouseEvent) => {
      posRef.current = { x: e.clientX, y: e.clientY };
      setHovered(i);
    },
    onMouseMove: (e: ReactMouseEvent) => {
      posRef.current = { x: e.clientX, y: e.clientY };
      // Imperative update is performed by ChartTooltip's own listener; we
      // intentionally don't call setState here so we don't re-render per pixel.
    },
    onFocus: () => setHovered(i),
    onBlur: () => {
      if (!pinned) setHovered((cur) => (cur === i ? null : cur));
    },
    tabIndex: 0 as const,
    role: "img" as const,
  }), [pinned]);

  const onLeave = useCallback(() => {
    if (!pinned) setHovered(null);
  }, [pinned]);

  const togglePin = useCallback((i: number) => {
    setPinned((cur) => {
      if (cur) {
        // already pinned — clicking the same / a different column unpins
        setHovered(null);
        return false;
      }
      setHovered(i);
      return true;
    });
  }, []);

  // Tap-elsewhere clears a pinned tooltip.
  useEffect(() => {
    if (!pinned) return;
    const handler = (e: globalThis.MouseEvent) => {
      const t = e.target as Element | null;
      if (t && t.closest("[data-chart-hit]")) return;
      setPinned(false);
      setHovered(null);
    };
    window.addEventListener("click", handler);
    return () => window.removeEventListener("click", handler);
  }, [pinned]);

  return { hovered, pinned, posRef, bind, onLeave, togglePin };
}

// ─────────────────────────────────────────────────────────────────────────────
// <ChartTooltip>
//
// Renders nothing when no column is hovered. When `hovered !== null`, renders
// an absolutely-positioned <div> and starts listening to `mousemove` on the
// owning document so its `transform` follows the cursor. The listener is
// scoped to the time the tooltip is visible, so the hot path costs nothing
// while the user isn't hovering anything.
// ─────────────────────────────────────────────────────────────────────────────

export function ChartTooltip<T>({
  hover,
  data,
  containerRef,
  render,
}: {
  hover: ChartHoverApi;
  data: readonly T[];
  containerRef: MutableRefObject<HTMLElement | null>;
  render: (d: T) => ReactNode;
}) {
  const ref = useRef<HTMLDivElement | null>(null);

  useLayoutEffect(() => {
    if (hover.hovered === null) return;
    const el = ref.current;
    if (!el) return;

    const place = () => {
      const container = containerRef.current;
      const rect = container?.getBoundingClientRect();
      const { x: cx, y: cy } = hover.posRef.current;
      // Convert viewport cursor coords to coords local to the relative-positioned
      // chart container so the tooltip stays attached to the chart on scroll.
      const localX = cx - (rect?.left ?? 0);
      const localY = cy - (rect?.top ?? 0);
      // Offset the tooltip 12 px to the right of the cursor and ~56 px above
      // (so it sits above the bar/line we're inspecting, not over it).
      el.style.transform = `translate(${localX + 12}px, ${localY - 56}px)`;
    };

    place();
    const onMove = (e: globalThis.MouseEvent) => {
      hover.posRef.current = { x: e.clientX, y: e.clientY };
      place();
    };
    const onScroll = () => place();
    window.addEventListener("mousemove", onMove);
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onScroll);
    };
  }, [hover.hovered, hover.posRef, containerRef]);

  if (hover.hovered === null) return null;
  const datum = data[hover.hovered];
  if (datum === undefined) return null;

  return (
    <div
      ref={ref}
      style={{
        position: "absolute",
        left: 0,
        top: 0,
        transform: "translate(0px, 0px)",
        background: "var(--card-bg, #fff)",
        border: "1px solid var(--card-border)",
        borderRadius: 6,
        padding: "6px 10px",
        fontSize: 12,
        lineHeight: 1.4,
        pointerEvents: "none",
        zIndex: 9999,
        boxShadow: "0 2px 8px rgba(0, 0, 0, 0.15)",
        whiteSpace: "nowrap",
      }}
    >
      {render(datum)}
    </div>
  );
}
