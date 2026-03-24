import { describe, it, expect } from "vitest";
import { fmtDate, fmtDateTime, fmtTime } from "./date";

describe("fmtDate", () => {
  it("formats an ISO string to a local date string", () => {
    const result = fmtDate("2024-03-15T12:00:00Z");
    expect(result).toBeTruthy();
    expect(typeof result).toBe("string");
  });

  it("returns empty string for null", () => {
    expect(fmtDate(null)).toBe("");
  });

  it("returns empty string for undefined", () => {
    expect(fmtDate(undefined)).toBe("");
  });

  it("returns empty string for empty string", () => {
    expect(fmtDate("")).toBe("");
  });
});

describe("fmtDateTime", () => {
  it("formats an ISO string to a local date+time string", () => {
    const result = fmtDateTime("2024-03-15T12:00:00Z");
    expect(result).toBeTruthy();
    expect(typeof result).toBe("string");
  });

  it("returns empty string for null", () => {
    expect(fmtDateTime(null)).toBe("");
  });

  it("returns empty string for undefined", () => {
    expect(fmtDateTime(undefined)).toBe("");
  });

  it("returns empty string for empty string", () => {
    expect(fmtDateTime("")).toBe("");
  });
});

describe("fmtTime", () => {
  it("formats a Date object to a local time string", () => {
    const d = new Date("2024-03-15T14:30:00Z");
    const result = fmtTime(d);
    expect(result).toBeTruthy();
    expect(typeof result).toBe("string");
  });

  it("returns empty string for null", () => {
    expect(fmtTime(null)).toBe("");
  });

  it("returns empty string for undefined", () => {
    expect(fmtTime(undefined)).toBe("");
  });
});
