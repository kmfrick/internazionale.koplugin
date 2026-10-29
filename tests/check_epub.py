"""Structural checks for an EPUB built by the plugin: python3 -I tests/check_epub.py file.epub"""

import posixpath
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

NS = {
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
    "x": "http://www.w3.org/1999/xhtml",
    "c": "urn:oasis:names:tc:opendocument:xmlns:container",
}

errors = []


def err(msg):
    errors.append(msg)


def main(path):
    z = zipfile.ZipFile(path)
    infos = z.infolist()
    names = set(z.namelist())
    first = infos[0]
    if first.filename != "mimetype" or first.compress_type != zipfile.ZIP_STORED:
        err("mimetype must be the first, uncompressed entry")
    if z.read("mimetype") != b"application/epub+zip":
        err("bad mimetype content")

    parsed = {}
    for n in names:
        if n.endswith((".xhtml", ".opf", ".ncx", ".xml")):
            try:
                parsed[n] = ET.fromstring(z.read(n))
            except ET.ParseError as e:
                err(f"{n}: not well-formed: {e}")

    container = parsed["META-INF/container.xml"]
    opf_path = container.find(".//c:rootfile", NS).get("full-path")
    base = posixpath.dirname(opf_path)
    opf = parsed[opf_path]

    manifest = {}
    for it in opf.find("opf:manifest", NS):
        href = posixpath.join(base, it.get("href"))
        manifest[it.get("id")] = (href, it.get("media-type"), it.get("properties") or "")
        if href not in names:
            err(f"manifest item missing from zip: {href}")
    in_manifest = {v[0] for v in manifest.values()}
    for n in names - in_manifest - {"mimetype", "META-INF/container.xml", opf_path}:
        err(f"zip entry not in manifest: {n}")
    spine = [r.get("idref") for r in opf.find("opf:spine", NS)]
    for idref in spine:
        if idref not in manifest:
            err(f"spine idref not in manifest: {idref}")
    if not any("nav" in v[2].split() for v in manifest.values()):
        err("no nav document")
    if not any("cover-image" in v[2].split() for v in manifest.values()):
        print("note: no cover image")

    ids = {}
    for n, root in parsed.items():
        if n.endswith(".xhtml"):
            ids[n] = {e.get("id") for e in root.iter() if e.get("id")}

    def resolve(src_file, href):
        if re.match(r"^[a-z]+:", href):
            return
        target, _, frag = href.partition("#")
        full = posixpath.normpath(posixpath.join(posixpath.dirname(src_file), target)) if target else src_file
        if full not in names:
            err(f"{src_file}: broken link {href}")
        elif frag and frag not in ids.get(full, set()):
            err(f"{src_file}: missing anchor {href}")

    for n, root in parsed.items():
        if not n.endswith(".xhtml"):
            continue
        for img in root.iter(f"{{{NS['x']}}}img"):
            resolve(n, img.get("src"))
        for a in root.iter(f"{{{NS['x']}}}a"):
            resolve(n, a.get("href"))
    ncx_path = next((v[0] for v in manifest.values() if v[1] == "application/x-dtbncx+xml"), None)
    nav_points = 0
    if ncx_path:
        for c in parsed[ncx_path].iter(f"{{{NS['ncx']}}}content"):
            resolve(ncx_path, c.get("src"))
            nav_points += 1

    title = opf.find(".//dc:title", NS).text
    articles = [i for i in spine if i.startswith("a")]
    images = [v for v in manifest.values() if v[1].startswith("image/")]
    img_bytes = sum(z.getinfo(v[0]).file_size for v in images)
    text_chars = 0
    for i in articles:
        root = parsed[manifest[i][0]]
        text_chars += len("".join(root.find("x:body", NS).itertext()))
    print(f"{title}")
    print(f"  {len(articles)} articles, {nav_points} TOC entries, {len(images)} images "
          f"({img_bytes / 1e6:.1f} MB), {text_chars / 1000:.0f}k characters of text, "
          f"file {sum(i.compress_size for i in infos) / 1e6:.1f} MB")
    if errors:
        print(f"{len(errors)} problems:")
        for e in errors[:50]:
            print("  -", e)
        return 1
    print("  structure OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
