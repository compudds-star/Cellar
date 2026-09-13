#!/usr/bin/env python3
"""Convert the Liv-ex LWIN download into the trimmed CSV the app bundles.

Usage:
    python3 scripts/import_lwin.py ~/Downloads/LWINdatabase.xlsx   # or .csv
    python3 scripts/import_lwin.py <file> --include-spirits         # keep spirits/cider
    xcodegen generate      # first time only, so Xcode bundles the new file

Reads the official download (CSV or XLSX, no third-party packages), drops
retired rows (STATUS Deleted/Combined), spirits and cider (unless
--include-spirits), mixed/assortment cases and placeholder rows; keeps one row
per 7-digit LWIN and only the columns the app uses (TYPE becomes Still /
Sparkling / Fortified (Port) / Sake …, from TYPE + SUB_TYPE), and writes UTF-8 with LF endings to
Cellar/Resources/LWIN.csv, which the app prefers over the bundled sample.

LWIN data (c) Liv-ex, licensed CC BY 4.0: https://www.liv-ex.com/lwin/
The output is a filtered subset (columns and retired rows removed).
"""
import csv
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

OUT_COLUMNS = ["LWIN", "DISPLAY_NAME", "PRODUCER_TITLE", "PRODUCER_NAME", "WINE", "COUNTRY",
               "REGION", "COLOUR", "TYPE", "FIRST_VINTAGE", "FINAL_VINTAGE"]
ALIASES = {
    "LWIN": ["LWIN", "LWIN7", "LWIN_7"],
    "STATUS": ["STATUS"],
    "DISPLAY_NAME": ["DISPLAY_NAME", "DISPLAYNAME"],
    "PRODUCER_TITLE": ["PRODUCER_TITLE"],
    "SUB_TYPE": ["SUB_TYPE"],
    "PRODUCER_NAME": ["PRODUCER_NAME", "PRODUCER"],
    "WINE": ["WINE"],
    "COUNTRY": ["COUNTRY"],
    "REGION": ["REGION"],
    "COLOUR": ["COLOUR", "COLOR"],
    "TYPE": ["TYPE"],
    "FIRST_VINTAGE": ["FIRST_VINTAGE", "FIRSTVINTAGE"],
    "FINAL_VINTAGE": ["FINAL_VINTAGE", "LATEST_VINTAGE", "FINALVINTAGE"],
}
RETIRED = {"deleted", "combined"}
EMPTY_MARKERS = {"NA", "N/A"}
NON_WINE_TYPES = {"spirit", "cider"}
PACK_MARKERS = ("assortment case", "mixed case", "standard lwin")
NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        yield from csv.reader(f)


def col_index(ref):
    letters = re.match(r"[A-Z]+", ref).group(0)
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def read_xlsx(path):
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            root = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in root.findall("m:si", NS):
                shared.append("".join(t.text or "" for t in si.iter(f"{{{NS['m']}}}t")))
        sheets = sorted(n for n in z.namelist() if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n))
        if not sheets:
            sys.exit("No worksheet found in the XLSX file.")
        with z.open(sheets[0]) as f:
            for _, row in ET.iterparse(f):
                if row.tag != f"{{{NS['m']}}}row":
                    continue
                cells = {}
                for c in row.findall("m:c", NS):
                    t = c.get("t")
                    if t == "inlineStr":
                        val = "".join(x.text or "" for x in c.iter(f"{{{NS['m']}}}t"))
                    else:
                        v = c.find("m:v", NS)
                        val = "" if v is None or v.text is None else v.text
                        if t == "s" and val:
                            val = shared[int(val)]
                    cells[col_index(c.get("r"))] = val
                row.clear()
                if cells:
                    yield [cells.get(i, "") for i in range(max(cells) + 1)]


def clean_number(s):
    s = (s or "").strip()
    if re.fullmatch(r"\d+\.0+", s):
        s = s.split(".")[0]
    return s


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    include_spirits = "--include-spirits" in sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    src = os.path.expanduser(args[0])
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dst = args[1] if len(args) > 1 else os.path.join(repo, "Cellar", "Resources", "LWIN.csv")

    rows = read_xlsx(src) if src.lower().endswith(".xlsx") else read_csv(src)
    header = [h.strip().upper() for h in next(rows)]
    idx = {}
    for key, names in ALIASES.items():
        idx[key] = next((header.index(n) for n in names if n in header), None)
    if idx["LWIN"] is None:
        sys.exit(f"No LWIN column in header: {header[:12]}")

    def get(fields, key):
        i = idx[key]
        value = fields[i].strip() if i is not None and i < len(fields) else ""
        return "" if value.upper() in EMPTY_MARKERS else value  # Liv-ex writes "NA" for blanks

    def app_type(fields):
        kind, sub = get(fields, "TYPE"), get(fields, "SUB_TYPE")
        if kind.lower() == "wine":
            return sub or "Still"
        if kind.lower() == "fortified wine":
            return f"Fortified ({sub})" if sub else "Fortified"
        return sub or kind

    seen, kept, retired, invalid, non_wine, packs = set(), 0, 0, 0, 0, 0
    with open(dst, "w", newline="", encoding="utf-8") as out:
        w = csv.writer(out, lineterminator="\n")
        w.writerow(OUT_COLUMNS)
        for fields in rows:
            if get(fields, "STATUS").lower() in RETIRED:
                retired += 1
                continue
            if not include_spirits and get(fields, "TYPE").lower() in NON_WINE_TYPES:
                non_wine += 1
                continue
            if any(m in get(fields, "DISPLAY_NAME").lower() for m in PACK_MARKERS):
                packs += 1
                continue
            lwin7 = clean_number(get(fields, "LWIN"))[:7]
            if len(lwin7) != 7 or not lwin7.isdigit():
                invalid += 1
                continue
            if lwin7 in seen:
                continue
            seen.add(lwin7)
            w.writerow([lwin7] + [clean_number(get(fields, k)) if "VINTAGE" in k
                                  else app_type(fields) if k == "TYPE" else get(fields, k)
                                  for k in OUT_COLUMNS[1:]])
            kept += 1
    size = os.path.getsize(dst) / 1e6
    print(f"Wrote {kept:,} wines to {dst} ({size:.1f} MB); skipped {retired:,} retired, "
          f"{non_wine:,} spirits/cider, {packs:,} cases/placeholders, {invalid:,} invalid rows.")


if __name__ == "__main__":
    main()
