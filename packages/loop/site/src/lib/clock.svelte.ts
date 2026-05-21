/** A shared reactive "now" so running rows update their elapsed display. */
let now = $state(Date.now());

if (typeof window !== 'undefined') {
  setInterval(() => {
    now = Date.now();
  }, 500);
}

export const getNow = () => now;
