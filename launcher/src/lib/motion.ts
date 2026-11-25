import type { Transition } from "framer-motion";

/** Motion constants shared by every animated component (mirror the CSS tokens). */
export const spring: Transition = { type: "spring", stiffness: 420, damping: 32, mass: 0.8 };
export const softSpring: Transition = { type: "spring", stiffness: 260, damping: 30 };
export const easeOutExpo: Transition = { duration: 0.45, ease: [0.16, 1, 0.3, 1] };
export const fade: Transition = { duration: 0.2, ease: "easeOut" };
