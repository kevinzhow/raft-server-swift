import { fromMarkdown } from 'mdast-util-from-markdown';
import { gfmFromMarkdown } from 'mdast-util-gfm';
import { gfm } from 'micromark-extension-gfm';

// Production AST adapter for the observable mention contract. The mature
// packages parse all Markdown syntax. This adapter only selects AST ranges.
function raftMarkdownSurface(source) {
  if (typeof source !== 'string') throw new TypeError('raft_markdown_source_must_be_string');
  const code = [];
  const links = [];
  const tree = fromMarkdown(source, {
    extensions: [gfm(), { disable: { null: ['codeIndented'] } }],
    mdastExtensions: [gfmFromMarkdown()],
  });
  function visit(node) {
    const start = node.position?.start.offset;
    const end = node.position?.end.offset;
    if (start !== undefined && end !== undefined) {
      if (node.type === 'code' || node.type === 'inlineCode') {
        code.push({ kind: 'code', start, end });
        return;
      }
      let kind;
      if (node.type === 'link' || node.type === 'linkReference') kind = 'link';
      else if (node.type === 'image' || node.type === 'imageReference') kind = 'image';
      else if (node.type === 'definition') kind = 'definition';
      if (kind !== undefined) {
        // The pinned helper intentionally has no resolved URL for a reference
        // use or an image. Only actual link/definition nodes carry that value.
        const href = node.type === 'link' || node.type === 'definition' ? node.url : '';
        links.push({ kind, start, end, href });
        return;
      }
    }
    if (Array.isArray(node.children)) for (const child of node.children) visit(child);
  }
  visit(tree);
  return JSON.stringify([...code, ...links]);
}
Object.defineProperty(globalThis, 'raftMarkdownSurface', {
  value: raftMarkdownSurface, writable: false, configurable: false,
});
