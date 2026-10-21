import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { cn } from "../lib/cn";

type Value = string | string[] | null;
type Ctx = {
  value: Value;
  multiple: boolean;
  toggle: (name: string | null) => void;
};

const AccordionContext = createContext<Ctx | null>(null);

/** Single-open by default; `multiple` keeps an array of open item names. */
export function Accordion({
  value = null,
  multiple = false,
  onChange,
  children,
}: {
  value?: Value;
  multiple?: boolean;
  onChange?: (value: any) => void;
  children: ReactNode;
}) {
  const toggle = (name: string | null) => {
    if (!multiple) return onChange?.(name);
    if (name === null) return;
    const open = Array.isArray(value) ? value : [];
    onChange?.(
      open.includes(name) ? open.filter((v) => v !== name) : [...open, name],
    );
  };
  return (
    <AccordionContext value={{ value, multiple, toggle }}>
      <div>{children}</div>
    </AccordionContext>
  );
}

export function AccordionItem({
  title,
  name,
  small = false,
  lazy = false,
  symbol,
  children,
}: {
  title: ReactNode;
  name: string;
  small?: boolean;
  lazy?: boolean;
  symbol?: ReactNode;
  children?: ReactNode;
}) {
  const ctx = useContext(AccordionContext);
  if (!ctx) throw Error("AccordionItem must be used inside Accordion");
  const { value, multiple, toggle } = ctx;
  const open = multiple
    ? Array.isArray(value) && value.includes(name)
    : value === name;
  // Lazy items render their body on first open and keep it afterwards.
  const [visited, setVisited] = useState(false);
  useEffect(() => {
    if (open) setVisited(true);
  }, [open]);
  const onToggle = () => toggle(multiple || !open ? name : null);

  return (
    <div
      role="button"
      tabIndex={0}
      aria-expanded={open}
      className={cn(
        "relative flex cursor-pointer items-start space-x-4 select-none after:absolute after:inset-x-0 after:bottom-0 after:h-0.5 after:rounded-full after:bg-stone-800/5 last:after:hidden dark:after:bg-orange-50/10",
        small ? "pt-4 pb-5" : "pt-6 pb-7",
      )}
      onClick={onToggle}
      onKeyDown={(e) => {
        if (
          e.target !== e.currentTarget ||
          (e.key !== "Enter" && e.key !== " ")
        )
          return;
        e.preventDefault();
        onToggle();
      }}
    >
      <div className="flex h-8 items-center text-stone-500 dark:text-[#8d8881]">
        <svg
          className="size-[22px] fill-transparent stroke-current stroke-2"
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path
            className={cn(
              "origin-center transition duration-300",
              open && "rotate-180",
            )}
            d="M19.5 12H4.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <path
            className={cn(
              "origin-center transition duration-300",
              open && "scale-0 rotate-80",
            )}
            d="M12 4.5V19.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>
      <div className="grow">
        <div className="flex items-center justify-between space-x-4">
          <h2 className={cn("text-2xl font-bold", small && "opacity-75")}>
            {title}
          </h2>
          <div className="dark:text-orange-75/50 shrink-0 pr-1.5 text-orange-500">
            {symbol}
          </div>
        </div>
        <div
          className={cn(
            "grid cursor-auto pr-6 transition-all duration-300",
            open ? "grid-rows-[1fr]" : "grid-rows-[0fr]",
          )}
          onClick={(e) => e.stopPropagation()}
          inert={!open}
        >
          <div
            className={cn(
              "row-[1/span_2] overflow-hidden text-xl transition",
              open ? "delay-150 duration-300" : "opacity-0 duration-200",
            )}
          >
            <div className="mt-3 space-y-3 select-text">
              {!lazy || visited ? children : null}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
