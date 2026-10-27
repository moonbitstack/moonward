// The browser bridge. The panel engine is the library itself, compiled to
// JavaScript: `moon build src/examples/browser --target js` drops it beside this file and it
// hands us one function that answers with JSON.
//
// Nothing on the page simulates anything. Every number drawn comes back through
// that one call.

let run = null;

globalThis.moonward_register = (f) => {
  run = f;
};

try {
  await import("./moonward.js");
} catch (err) {
  console.warn(
    "moonward: engine bundle missing — build it with `moon build src/examples/browser --target js`",
    err.message,
  );
}

/** The compiled entry, or null when the bundle has not been built. */
export function engine() {
  return run;
}

/** True once the engine has answered something. */
export function ready() {
  return typeof run === "function";
}
