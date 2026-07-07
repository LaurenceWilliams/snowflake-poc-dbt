{% macro create_ci_database() %}
    {#-
      Ensure the CI database exists before dbt builds into it. dbt creates
      schemas and tables but never databases, so the GitHub Action calls this
      as a `dbt run-operation` step ahead of `dbt run`.

      Uses target.database (driven by SF_DATABASE, i.e. github_ci) so it tracks
      whatever target it's invoked with rather than hardcoding a name.
    -#}
    {% if execute %}
        {% do run_query('create database if not exists ' ~ target.database) %}
        {{ log('Ensured database ' ~ target.database ~ ' exists.', info=true) }}
    {% endif %}
{% endmacro %}
