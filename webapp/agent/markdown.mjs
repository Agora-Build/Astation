import { safeLink } from "./chat-core.mjs";

// Render parsed CommonMark with DOM APIs so HTML and image URLs never execute.
export function renderMarkdown(text, { document, parser, codeBlock }) {
  const root = document.createDocumentFragment();
  const stack = [root];
  const containers = new Set();
  const walker = parser.parse(text).walker();
  let event;
  while ((event = walker.next())) {
    const item = event.node;
    if (!event.entering) {
      if (containers.has(item)) stack.pop();
      continue;
    }
    const parent = stack[stack.length - 1];
    let element;
    switch (item.type) {
      case "document":
        continue;
      case "text":
      case "html_inline":
      case "html_block":
        parent.append(document.createTextNode(item.literal || ""));
        continue;
      case "softbreak":
        parent.append(document.createTextNode("\n"));
        continue;
      case "linebreak":
        parent.append(document.createElement("br"));
        continue;
      case "thematic_break":
        parent.append(document.createElement("hr"));
        continue;
      case "code":
        element = document.createElement("code");
        element.textContent = item.literal;
        parent.append(element);
        continue;
      case "code_block":
        parent.append(
          codeBlock(item.literal, (item.info || "code").split(/\s/)[0]),
        );
        continue;
      case "link": {
        const href = safeLink(item.destination);
        element = document.createElement(href ? "a" : "span");
        if (href) {
          element.href = href;
          element.target = "_blank";
          element.rel = "noopener noreferrer";
          if (item.title) element.title = item.title;
        }
        break;
      }
      case "list":
        element = document.createElement(
          item.listType === "ordered" ? "ol" : "ul",
        );
        if (item.listType === "ordered") element.start = item.listStart;
        break;
      default: {
        const tags = {
          paragraph: "p",
          heading: `h${item.level}`,
          item: "li",
          block_quote: "blockquote",
          emph: "em",
          strong: "strong",
          image: "span",
        };
        element = document.createElement(tags[item.type] || "span");
      }
    }
    parent.append(element);
    if (item.isContainer) {
      containers.add(item);
      stack.push(element);
    }
  }
  return root;
}
