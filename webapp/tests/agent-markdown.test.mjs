import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { renderMarkdown } from "../agent/markdown.mjs";

const { Parser } = createRequire(import.meta.url)(
  "../agent/vendor/commonmark.min.js",
);

class Element {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
  }
  append(...children) {
    this.children.push(...children);
  }
}
const document = {
  createDocumentFragment: () => new Element("fragment"),
  createElement: (tag) => new Element(tag),
  createTextNode: (text) => ({ tag: "text", textContent: text }),
};
const render = (text) =>
  renderMarkdown(text, {
    document,
    parser: new Parser(),
    codeBlock(text, language) {
      const element = new Element("pre");
      element.textContent = text;
      element.language = language;
      return element;
    },
  });
function descendants(node) {
  return [node, ...(node.children || []).flatMap(descendants)];
}

test("CommonMark handles nested emphasis, ordered lists, entities and fenced code", () => {
  const nodes = descendants(
    render(
      "### Build &amp; test\n\n3. **Bold and *nested***\n4. `inline`\n\n```js\nconst ready = true;\n```",
    ),
  );
  assert(nodes.some((n) => n.tag === "h3"));
  const heading = nodes.find((n) => n.tag === "h3");
  assert.equal(
    descendants(heading)
      .map((n) => n.textContent || "")
      .join(""),
    "Build & test",
  );
  assert(nodes.some((n) => n.tag === "ol" && n.start === 3));
  assert(
    nodes.some(
      (n) => n.tag === "strong" && descendants(n).some((n) => n.tag === "em"),
    ),
  );
  assert(
    nodes.some(
      (n) =>
        n.tag === "pre" &&
        n.language === "js" &&
        n.textContent === "const ready = true;\n",
    ),
  );
});

test("HTML, image URLs, executable links and credential URLs never become active elements", () => {
  const nodes = descendants(
    render(
      "<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[bad](javascript:alert%281%29) [secret](https://user:password@example.com) ![image](https://tracker.example.com/pixel) [good](https://example.com)",
    ),
  );
  assert(!nodes.some((n) => ["script", "img", "iframe"].includes(n.tag)));
  assert(nodes.some((n) => n.textContent === "<script>alert(1)</script>"));
  const links = nodes.filter((n) => n.tag === "a");
  assert.equal(links.length, 1);
  assert.equal(links[0].href, "https://example.com/");
  assert.equal(links[0].rel, "noopener noreferrer");
});

test("vendored parser matches the reviewed pinned asset", () => {
  const actual = createHash("sha256")
    .update(
      readFileSync(
        new URL("../agent/vendor/commonmark.min.js", import.meta.url),
      ),
    )
    .digest("hex");
  const readme = readFileSync(
    new URL("../agent/vendor/README.md", import.meta.url),
    "utf8",
  );
  assert.match(readme, new RegExp(`SHA-256 .commonmark.min.js.: .${actual}.`));
});
