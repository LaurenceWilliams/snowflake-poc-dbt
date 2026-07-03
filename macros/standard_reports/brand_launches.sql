{% macro brand_launches() %}
  {{ return([
    {'brand': 'rover', 'start': '1900-01-01', "import_source_names": none},
    {'brand': 'catinaflat',  'start': '2026-04-08', "import_source_names": ["catinaflat_eu", "catinaflat_na"]},
  ]) }}
{% endmacro %}
