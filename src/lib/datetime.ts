const weekday = new Intl.DateTimeFormat("en-US", { weekday: "short" });
const month = new Intl.DateTimeFormat("en-US", { month: "short" });
const pad = (n: number) => String(n).padStart(2, "0");

export const formatWeekday = (d: Date) => weekday.format(d);
export const formatMonth = (d: Date) => month.format(d);
export const formatMonthYear = (d: Date) => `${month.format(d)} ${d.getFullYear()}`;
export const hours = (d: Date) => pad(d.getHours());
export const minutes = (d: Date) => pad(d.getMinutes());
export const dayOfMonth = (d: Date) => String(d.getDate());
export const isNight = (d: Date) => d.getHours() < 6 || d.getHours() >= 18;
