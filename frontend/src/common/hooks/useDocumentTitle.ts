import { useEffect } from "react";

export function useDocumentTitle(title: string) {
  useEffect(() => {
    document.title = title ? `${title} | AI Gateway` : "AI Gateway";
    return () => { document.title = "AI Gateway"; };
  }, [title]);
}
