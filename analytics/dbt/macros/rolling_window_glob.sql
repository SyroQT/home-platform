{#
  rolling_window_glob(prefix)
  Returns a JSON array of S3 glob paths for the last analytics_history_days days.
  NOTE: dbt does not make project macros available during schema.yml rendering, so
  this macro cannot be called from external_location in _sources.yml. The equivalent
  inline Jinja is used there instead. This macro is available for use in model SQL.
#}
{% macro rolling_window_glob(prefix) %}
  {%- set days = var('analytics_history_days', 16) -%}
  {%- set paths = [] -%}
  {%- for i in range(days) -%}
    {%- set d = modules.datetime.date.today() - modules.datetime.timedelta(days=i) -%}
    {%- do paths.append(
      env_var('ANALYTICS_RAW_BASE_PATH') ~ '/' ~ prefix ~ '/'
      ~ d.strftime('%Y') ~ '/' ~ d.strftime('%m') ~ '/' ~ d.strftime('%d')
      ~ '/*.json'
    ) -%}
  {%- endfor -%}
  {{ paths | tojson }}
{% endmacro %}
