import s from "src/common/components/layout/Layout.module.scss";

export type BadgeVariant = "success" | "error" | "warning" | "neutral";

interface StatusBadgeProps {
  value: string | number;
  variant: BadgeVariant;
}

export function StatusBadge({ value, variant }: StatusBadgeProps) {
  return <span className={`${s.badge} ${s[`badge--${variant}`]}`}>{value}</span>;
}

/** Maps a user role to the appropriate badge variant. */
export function roleVariant(role: string): BadgeVariant {
  if (role === "admin" || role === "tenant_admin") return "success";
  if (role === "member") return "warning";
  return "neutral";
}

/** Maps a tenant plan to the appropriate badge variant. */
export function planVariant(plan: string): BadgeVariant {
  if (plan === "enterprise") return "success";
  if (plan === "standard") return "warning";
  return "neutral";
}
