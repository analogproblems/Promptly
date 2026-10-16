#!/usr/bin/env python3
"""Build the docs site from the repository's Markdown.

    python3 tools/site/build.py site

The README becomes the home page, each file in docs/ gets its own page
(docs/PRIVACY.md is served at /privacy/), and CHANGELOG.md is /changelog/.
Links between those files point at their pages, images they show are
copied next to them, and links to anything else in the repository go to
GitHub. One stylesheet, no scripts. Needs `pip install markdown`.
"""

import html
import os
import re
import shutil
import sys

import markdown

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPO_URL = "https://github.com/analogproblems/Promptly"
HERE = os.path.dirname(os.path.abspath(__file__))

# Navigation order; any other docs/*.md file still gets a page.
NAV = ["README.md", "docs/DESIGN.md", "docs/ROADMAP.md", "docs/DISTRIBUTION.md",
       "docs/DEVELOPMENT.md", "docs/VAULT.md", "docs/PRIVACY.md", "CHANGELOG.md"]
NAV_LABELS = {"README.md": "Home"}


def page_dir(source):
    """Site folder for a Markdown file, relative to the site root ('' is home)."""
    if source == "README.md":
        return ""
    return os.path.splitext(os.path.basename(source))[0].lower()


def slugify(text, separator="-"):
    """Heading ids the way GitHub makes them, so #anchors keep working."""
    text = re.sub(r"<[^>]+>", "", text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", separator)


def title_of(text, fallback):
    match = re.search(r"^#\s+(.+)$", text, re.MULTILINE)
    return match.group(1).strip() if match else fallback


def relative(from_dir, to_dir):
    """A relative URL from one page's folder to another page's folder."""
    path = os.path.relpath(to_dir or ".", from_dir or ".")
    return "./" if path == "." else path + "/"


def rewrite_links(body, source, pages, out, assets):
    here = page_dir(source)
    base = os.path.dirname(source)

    def fix(match):
        attr, url = match.group(1), html.unescape(match.group(2))
        if re.match(r"^[a-z][a-z0-9+.-]*:|^#|^//", url):
            return match.group(0)
        path, _, fragment = url.partition("#")
        target = os.path.normpath(os.path.join(base, path)).replace(os.sep, "/")
        anchor = "#" + fragment if fragment else ""
        if target in pages:
            new = relative(here, page_dir(target)) + anchor
        elif attr == "src" and os.path.isfile(os.path.join(ROOT, target)):
            # Images keep their place under the site root, e.g. screenshots/.
            dest = target[len("docs/"):] if target.startswith("docs/") else target
            if dest not in assets:
                os.makedirs(os.path.dirname(os.path.join(out, dest)) or out, exist_ok=True)
                shutil.copyfile(os.path.join(ROOT, target), os.path.join(out, dest))
                assets.add(dest)
            new = os.path.relpath(dest, here or ".")
        else:
            kind = "tree" if os.path.isdir(os.path.join(ROOT, target)) else "blob"
            new = f"{REPO_URL}/{kind}/main/{target}{anchor}"
        return f'{attr}="{html.escape(new, quote=True)}"'

    return re.sub(r'\b(href|src)="([^"]*)"', fix, body)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: build.py OUTPUT_DIR")
    out = os.path.abspath(sys.argv[1])
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)

    docs = sorted("docs/" + name for name in os.listdir(os.path.join(ROOT, "docs"))
                  if name.endswith(".md"))
    pages = [p for p in NAV if os.path.isfile(os.path.join(ROOT, p))]
    pages += [p for p in docs if p not in pages]

    with open(os.path.join(HERE, "template.html"), encoding="utf-8") as f:
        template = f.read()
    shutil.copyfile(os.path.join(HERE, "style.css"), os.path.join(out, "style.css"))

    texts = {}
    for source in pages:
        with open(os.path.join(ROOT, source), encoding="utf-8") as f:
            texts[source] = f.read()
    titles = {p: title_of(t, page_dir(p) or "Promptly") for p, t in texts.items()}

    assets = set()
    for source in pages:
        text, title = texts[source], titles[source]
        body = markdown.markdown(
            text,
            extensions=["tables", "fenced_code", "toc", "sane_lists"],
            extension_configs={"toc": {"slugify": slugify}},
        )
        body = rewrite_links(body, source, pages, out, assets)
        here = page_dir(source)
        nav = "\n".join(
            '<a href="{}"{}>{}</a>'.format(
                relative(here, page_dir(p)),
                ' aria-current="page"' if p == source else "",
                html.escape(NAV_LABELS.get(p, titles[p])),
            )
            for p in pages
        )
        page = (template
                .replace("{{title}}", html.escape(title if source != "README.md" else "Promptly"))
                .replace("{{root}}", relative(here, ""))
                .replace("{{nav}}", nav)
                .replace("{{body}}", body)
                .replace("{{repo}}", REPO_URL))
        os.makedirs(os.path.join(out, here), exist_ok=True)
        with open(os.path.join(out, here, "index.html"), "w", encoding="utf-8") as f:
            f.write(page)

    # Pages serves the files as they are; no Jekyll processing.
    open(os.path.join(out, ".nojekyll"), "w").close()
    print(f"Built {len(pages)} pages and {len(assets)} images into {out}")


if __name__ == "__main__":
    main()
