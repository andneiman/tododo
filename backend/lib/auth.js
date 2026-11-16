import { timingSafeEqual, createHash } from 'node:crypto';
const h = (s) => createHash('sha256').update(String(s)).digest();
export function tokenOk(given, expected) {
  if (!given || !expected) return false;
  return timingSafeEqual(h(given), h(expected));
}
