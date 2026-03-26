import s from "src/common/components/layout/Layout.module.scss";

export type BadgeVariant = "success" | "error" | "warning" | "neutral";

interface StatusBadgeProps {
  value: string | number;
  variant: BadgeVariant;
}

export function StatusBadge({ value, variant }: StatusBadgeProps) {
  return <span className={`${s.badge} ${s[`badge--${variant}`]}`}>{value}</span>;
}
