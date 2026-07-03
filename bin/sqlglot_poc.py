"""
PoC: transpile dbt Jinja-SQL macros between dialects using sqlglot.

Strategy
--------
sqlglot parses SQL, not Jinja. So we:
  1. Mask every Jinja construct ({{ expr }}, {% stmt %}, {# comment #})
     with a placeholder token that is *valid SQL* in that position.
       - {{ ... }}  -> a bareword identifier placeholder  (acts like a column)
       - {% ... %}  -> a SQL line-comment placeholder      (statement-level)
       - {# ... #}  -> a SQL line-comment placeholder
  2. Transpile the masked SQL body with sqlglot (read=src, write=tgt).
  3. Restore the original Jinja text from the placeholders.

We operate per-macro-body so the {% macro %}/{% endmacro %} wrapper is
preserved verbatim and only the SQL inside is transpiled.
"""

import re
import sys
import sqlglot

SRC = "redshift"
TGT = "snowflake"

# ---- Jinja masking ---------------------------------------------------------

JINJA_RE = re.compile(r"\{\{.*?\}\}|\{%.*?%\}|\{#.*?#\}", re.DOTALL)


def mask_jinja(sql):
    """Replace Jinja constructs with SQL-safe placeholders.

    Returns (masked_sql, mapping placeholder->original_jinja).
    """
    mapping = {}
    counter = {"n": 0}

    def repl(m):
        tok = m.group(0)
        i = counter["n"]
        counter["n"] += 1
        if tok.startswith("{{"):
            # inline expression -> identifier-like placeholder
            ph = f"JINJA_EXPR_{i}"
            mapping[ph] = tok
            return ph
        # {% %} statement / {# #} comment -> SQL line comment so the
        # surrounding statement still parses. sqlglot preserves it as /* */.
        ph = f"JINJA_STMT_{i}"
        mapping[ph] = tok
        return f"-- {ph}"

    return JINJA_RE.sub(repl, sql), mapping


def unmask_jinja(sql, mapping):
    # Restore longest placeholders first so JINJA_EXPR_1 doesn't clobber
    # the prefix of JINJA_EXPR_10. Also unwrap the /* */ comment we injected.
    for ph in sorted(mapping, key=len, reverse=True):
        original = mapping[ph]
        sql = sql.replace(f"/* {ph} */", original)
        sql = sql.replace(ph, original)
    return sql


# ---- Per-macro extraction --------------------------------------------------

MACRO_RE = re.compile(
    r"(\{%-?\s*macro\s+.*?-?%\})(.*?)(\{%-?\s*endmacro\s*-?%\})",
    re.DOTALL,
)


def transpile_body(body):
    """Mask jinja, transpile, restore. Returns (result, error_or_None)."""
    masked, mapping = mask_jinja(body)
    if not masked.strip():
        return body, None

    def _try(sql):
        out = sqlglot.transpile(sql, read=SRC, write=TGT, pretty=True)
        return ";\n".join(out)

    try:
        return unmask_jinja(_try(masked), mapping), None
    except Exception:  # noqa: BLE001
        # Many macro bodies are bare scalar expressions, which sqlglot's
        # statement parser mishandles. Retry as a SELECT projection.
        try:
            wrapped = _try(f"SELECT {masked.strip()}")
            stripped = re.sub(r"^SELECT\s+", "", wrapped, count=1)
            return unmask_jinja(stripped, mapping), None
        except Exception as e:  # noqa: BLE001 - PoC reports all failures
            return None, f"{type(e).__name__}: {e}"


COLW = 70


def _sidebyside(left, right, ltitle, rtitle):
    llines = left.strip("\n").splitlines() or [""]
    rlines = right.strip("\n").splitlines() or [""]
    n = max(len(llines), len(rlines))
    llines += [""] * (n - len(llines))
    rlines += [""] * (n - len(rlines))
    bar = "-" * COLW
    out = [f"  {ltitle:<{COLW}} | {rtitle}", f"  {bar} | {bar}"]
    for l, r in zip(llines, rlines):
        out.append(f"  {l:<{COLW}} | {r}")
    return "\n".join(out)


def process_file(path):
    with open(path) as f:
        content = f.read()

    macros = MACRO_RE.findall(content)
    if not macros:
        print(f"  (no {{% macro %}} blocks found)")
        return

    for open_tag, body, close_tag in macros:
        name = re.search(r"macro\s+(\w+)", open_tag)
        name = name.group(1) if name else "?"
        result, err = transpile_body(body)
        print(f"\n  ===== macro: {name} =====")
        if err:
            print(f"  [FAILED] {err}")
            continue
        # Left column is the verbatim source body (formatting differs from the
        # pretty-printed Snowflake output, but genuine dialect changes show).
        print(_sidebyside(body, result, f"{SRC} (source, verbatim)",
                          f"{TGT} (transpiled)"))


if __name__ == "__main__":
    print(f"sqlglot transpile  {SRC} -> {TGT}\n")
    for path in sys.argv[1:]:
        print(f"========== {path} ==========")
        process_file(path)
