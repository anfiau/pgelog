-- Install pgelog prerequisites
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE EXTENSION IF NOT EXISTS pg_variables;

-- Install pgelog prerequisites
CREATE EXTENSION IF NOT EXISTS pgelog;

-- Test call
SELECT pgelog_get_param('pgelog_port') AS pgelog_port;

