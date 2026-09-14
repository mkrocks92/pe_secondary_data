{#
    Override dbt's default schema naming.

    Default behaviour concatenates the profile schema with the custom schema,
    e.g. target.schema = "preparation" + `+schema: presentation` -> "preparation_presentation".

    Here a custom schema is used verbatim, so models land in the schema named in
    dbt_project.yml (preparation, presentation). Models with no custom schema
    fall back to the profile's target schema.

    Trade-off: dev and prod runs of the same target database now share schemas,
    so environment isolation has to come from using a different database or
    profile per environment.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if custom_schema_name is none -%}

        {{ target.schema }}

    {%- else -%}

        {{ custom_schema_name | trim }}

    {%- endif -%}

{%- endmacro %}
