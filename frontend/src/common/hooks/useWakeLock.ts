import { useEffect, useRef } from "react";

/**
 * Acquires a Screen Wake Lock while `active` is true.
 *
 * The lock is released when `active` becomes false or the component unmounts.
 * It is automatically re-acquired if the page regains visibility while still
 * active (the browser releases the lock whenever the tab goes to background).
 *
 * Silently no-ops on browsers that don't support the Wake Lock API (e.g. Firefox,
 * older Safari) — the only consequence is the device may still sleep.
 */
export function useWakeLock(active: boolean): void {
  const lockRef = useRef<WakeLockSentinel | null>(null);

  useEffect(() => {
    if (!("wakeLock" in navigator)) return;

    let cancelled = false;

    async function acquire() {
      if (cancelled || lockRef.current) return;
      try {
        lockRef.current = await navigator.wakeLock.request("screen");
        lockRef.current.addEventListener("release", () => {
          lockRef.current = null;
        });
      } catch {
        // Acquiring can fail if the document is hidden — harmless
      }
    }

    function release() {
      lockRef.current?.release().catch(() => {});
      lockRef.current = null;
    }

    // Re-acquire when the tab becomes visible again (browser auto-releases on hide)
    function onVisibilityChange() {
      if (document.visibilityState === "visible") {
        acquire();
      }
    }

    if (active) {
      acquire();
      document.addEventListener("visibilitychange", onVisibilityChange);
    }

    return () => {
      cancelled = true;
      document.removeEventListener("visibilitychange", onVisibilityChange);
      if (!active) return;
      release();
    };
  }, [active]);
}
