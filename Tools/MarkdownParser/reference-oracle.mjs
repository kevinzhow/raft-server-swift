#!/usr/bin/env node
// Development-only reference: no Node or JavaScript engine is used by RaftServer.
import fs from 'node:fs';
import vm from 'node:vm';

const bundle = process.argv[2];
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(bundle, 'utf8'), context);
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const results = input.map(item => {
  const source = typeof item === 'string' ? item : item.source;
  const ranges = typeof item === 'string' || !item.ranges
    ? JSON.parse(context.raftMarkdownSurface(source)) : item.ranges;
  const linkedHandles = [];
  for (const range of ranges) {
    if (range.kind !== 'link') continue;
    const raw = source.slice(range.start, range.end);
    const href = range.href ?? '';
    if ((raw === `<${href}>` || /\]\(<[^<>\n]+>\)$/.test(raw))
        && /^@[\p{L}\p{N}_-]+$/u.test(href.trim())) {
      linkedHandles.push(href.trim().slice(1));
    }
  }
  const runs = [];
  let cursor = 0;
  const prose = text => text.replace(/\\<@[\p{L}\p{N}_-]+>/gu, '')
    .replace(/https?:\/\/[^\s<>]+/g, ' ');
  for (const range of [...ranges].sort((a, b) => a.start - b.start)) {
    if (range.end <= cursor) continue;
    if (range.start > cursor) runs.push(prose(source.slice(cursor, range.start)));
    cursor = Math.max(cursor, range.end);
  }
  if (cursor < source.length) runs.push(prose(source.slice(cursor)));
  return { ranges, surface: { runs, linkedHandles } };
});
process.stdout.write(JSON.stringify(results));
