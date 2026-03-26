import { Currency } from "src/common/utils/currency";

interface CurrencySelectorProps {
  value: Currency;
  onChange: (c: Currency) => void;
}

export function CurrencySelector({ value, onChange }: CurrencySelectorProps) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value as Currency)}
      aria-label="Currency"
      style={{
        background: "var(--section-bg)", border: "1px solid var(--card-border)",
        borderRadius: 6, padding: "5px 10px", fontSize: 13,
        color: "var(--text-primary)", cursor: "pointer",
      }}
    >
      <option value="USD">USD $</option>
      <option value="EUR">EUR €</option>
    </select>
  );
}
