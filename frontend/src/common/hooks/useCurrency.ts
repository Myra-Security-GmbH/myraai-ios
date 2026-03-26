import { useEffect, useState } from "react";
import { Currency, fetchEurRate, fmtCurrency } from "src/common/utils/currency";

const LS_KEY = "aig_currency";

export function useCurrency() {
  const [currency, setCurrencyState] = useState<Currency>(() => {
    const stored = localStorage.getItem(LS_KEY);
    return stored === "EUR" ? "EUR" : "USD";
  });
  const [eurRate, setEurRate] = useState(1);

  function setCurrency(c: Currency) {
    setCurrencyState(c);
    localStorage.setItem(LS_KEY, c);
  }

  useEffect(() => {
    if (currency !== "EUR") return;
    fetchEurRate().then(setEurRate).catch(() => {});
  }, [currency]);

  const fc = (n: number | undefined | null) => fmtCurrency(n, currency, eurRate);

  return { currency, setCurrency, eurRate, fc };
}
