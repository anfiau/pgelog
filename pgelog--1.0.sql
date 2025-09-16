\echo Use "CREATE EXTENSION pgelog" to load this file. \quit

-- 1) Tables of pgelog
--
-- 1.1) Table to store extended logging data
CREATE TABLE IF NOT EXISTS pgelog_logs
(
 log_stamp TIMESTAMP -- 1; Date and time of log record (got by clock_timestamp())
,log_type  TEXT      -- 2; Kind of log record - FAIL, WARN, INFO etc
,log_func  TEXT      -- 3; Name of log record source - stored function, trigger, SQL clause etc
,phase     TEXT      -- 4; Serial number or label of current phase of logical operation inside above mentioned log_func, for example 1, 2, 2.a
,log_info  TEXT      -- 5; Body of log record
,xact_id   TEXT      -- 6; txid::text from txid_current() or txid_current_if_assigned() for PG < 13 or txid8::text from pg_current_xact_id() or pg_current_xact_id_if_assigned() for PG >= 13
,sqlstate  TEXT      -- 7; Current Postgres SQLSTATE
,sqlerrm   TEXT      -- 8; Current Postgres SQLERRM
,conn_name TEXT      -- 9; Name of dblink used for pseudo-autonomous transaction execution
);

COMMENT ON TABLE  pgelog_logs           IS 'pgelog extension table to store extended logging data';
COMMENT ON COLUMN pgelog_logs.log_stamp IS 'Date and time of log record (got by clock_timestamp())';
COMMENT ON COLUMN pgelog_logs.log_type  IS 'Kind of log record - FAIL, WARN, INFO etc';
COMMENT ON COLUMN pgelog_logs.log_func  IS 'Name of log record source - stored function, trigger, SQL clause etc';
COMMENT ON COLUMN pgelog_logs.phase     IS 'Serial number or label of current phase of logical operation inside above mentioned log_func, for example 1, 2, 2.a';
COMMENT ON COLUMN pgelog_logs.log_info  IS 'Body of log record';
COMMENT ON COLUMN pgelog_logs.xact_id   IS 'txid::text from txid_current() or txid_current_if_assigned() for PG < 13 or txid8::text from pg_current_xact_id() or pg_current_xact_id_if_assigned() for PG >= 13';
COMMENT ON COLUMN pgelog_logs.sqlstate  IS 'Current Postgres SQLSTATE';
COMMENT ON COLUMN pgelog_logs.sqlerrm   IS 'Current Postgres SQLERRM';
COMMENT ON COLUMN pgelog_logs.conn_name IS 'Name of dblink used for pseudo-autonomous transaction execution';

GRANT SELECT ON pgelog_logs TO PUBLIC;

SELECT pg_catalog.pg_extension_config_dump('pgelog_logs', '');
-----------------
--
-- 1.2) Table to store pgelog control parameters
CREATE TABLE IF NOT EXISTS pgelog_params
(
 param_name  TEXT NOT NULL -- 1; Name of pgelog control parameter
,param_value TEXT          -- 2; Value of pgelog control parameter
,CONSTRAINT  pk_pgelog_params PRIMARY KEY(param_name)
);

COMMENT ON TABLE  pgelog_params             IS 'pgelog extension table to store pgelog control parameters';
COMMENT ON COLUMN pgelog_params.param_name  IS 'Name of pgelog control parameter';
COMMENT ON COLUMN pgelog_params.param_value IS 'Value of pgelog control parameter';

GRANT SELECT ON pgelog_params TO PUBLIC;

SELECT pg_catalog.pg_extension_config_dump('pgelog_params', '');

INSERT INTO pgelog_params(param_name, param_value)
VALUES
 ('pgelog_pgv_package'      ,'pgelog')
,('pgelog_is_active'        ,'y')
,('pgelog_port'             ,'5432')
,('pgelog_assign_xact_id'   ,'n')
,('pgelog_timestamp_format' ,'YYYY-MM-DD HH24:MI:SS.US')
,('pgelog_pgv_transactional','y')
,('pgelog_ttl_minutes'      ,'1440')
,('pgelog_log_clean_call'   ,'y')
,('pgelog_log_init_call'    ,'n')
;
-----------------
--
-- 2) Functions of pgelog
--
-- SQL functions ------------------
--
-- 2.1) Read pgelog control parameter
CREATE OR REPLACE FUNCTION pgelog_get_param -- Read pgelog control parameter
(
 p_name TEXT -- 1; Name of pgelog control parameter
)
RETURNS TEXT -- pgelog control parameter
LANGUAGE SQL STRICT
-----------------------------------
AS $BODY$
   SELECT P.param_value
   FROM   pgelog_params P
   WHERE  P.param_name = p_name
$BODY$;

GRANT EXECUTE ON FUNCTION pgelog_get_param(TEXT) TO PUBLIC;
-----------------------------------

-- 2.2) Set pgelog control parameter
CREATE OR REPLACE FUNCTION pgelog_set_param -- Set pgelog control parameter
(
 p_name  TEXT -- 1; Name of pgelog control parameter
,p_value TEXT -- 2; Value of pgelog control parameter
)
RETURNS VOID
LANGUAGE SQL
-----------------------------------
AS $BODY$
  INSERT INTO pgelog_params(param_name, param_value)
  SELECT p_name, p_value
  WHERE  p_name IS NOT NULL -- STRICT only to p_name
  ON CONFLICT ON CONSTRAINT pk_pgelog_params
  DO UPDATE SET param_value = EXCLUDED.param_value
$BODY$;

GRANT EXECUTE ON FUNCTION pgelog_set_param(TEXT, TEXT) TO PUBLIC;
-----------------------------------

-- 2.3) Delete pgelog control parameter
CREATE OR REPLACE FUNCTION pgelog_delete_param -- Delete pgelog control parameter
(
 p_name TEXT -- 1; Name of pgelog control parameter
)
RETURNS VOID
LANGUAGE SQL STRICT
-----------------------------------
AS $BODY$
   DELETE
   FROM   pgelog_params
   WHERE  param_name = p_name
$BODY$;

GRANT EXECUTE ON FUNCTION pgelog_delete_param(TEXT) TO PUBLIC;
-----------------------------------
--
-- PL/pgSQL functions -------------
--
-- 2.4) Initialize pgelog logger and set required pg_variables
CREATE OR REPLACE FUNCTION pgelog_init()
RETURNS BOOLEAN -- TRUE if logger initialized
-----------------------------------
AS $BODY$
DECLARE
v_Phase      TEXT;
v_Proc_Name  TEXT := 'pgelog_init';
v_Port       TEXT;
v_Package    TEXT;
v_Conn_Str   TEXT;
v_Conn_Name  TEXT;
v_Pg_Version INTEGER;
v_Is_Active  TEXT;
v_Assign_XID TEXT;
v_Time_Fmt   TEXT;
v_Is_Trans   TEXT;
v_Transact   BOOLEAN;
v_Log_Call   TEXT;
v_Log_Type   TEXT;
v_Log_Func   TEXT;
v_Log_Info   TEXT;
-----------------------------------
BEGIN
-- 1) Get information about logging mode
-- 1.1) Get pg_variables package name
v_Phase := '1.1)';
v_Package := COALESCE(pgelog_get_param('pgelog_pgv_package'),'pgelog');
-- 1.2) Read pgelog parameters for transactional mode
v_Phase := '1.2)';
v_Is_Trans := COALESCE(lower(pgelog_get_param('pgelog_pgv_transactional')),'y');
v_Transact := (v_Is_Trans = 'y');
-- 1.3) Check if 'pgelog_is_active' pg_variable already set for current session by pgelog_enable_locally()/pgelog_disable_localy() call
v_Phase := '1.3)';
IF (pgv_exists(v_Package,'pgelog_is_active')) THEN
    -- 1.3.1) 'pgelog_is_active' pg_variable already set, read it from pg_variable 'pgelog_is_active'
    v_Phase := '1.3.1)';
    v_Is_Active := pgv_get(v_Package,'pgelog_is_active' ,NULL::TEXT);
ELSE
    -- 1.3.2) 'pgelog_is_active' pg_variable NOT set, read it from table pgelog_params
    v_Phase := '1.3.2)';
    v_Is_Active := COALESCE(lower(pgelog_get_param('pgelog_is_active')),'n');
    -- 1.3.3) Set pg_variable 'pgelog_is_active'
    v_Phase := '1.3.3)';
    PERFORM pgv_set(v_Package, 'pgelog_is_active', v_Is_Active, v_Transact);
END IF;
-- 1.4) Read pgelog parameters from table pgelog_params
v_Phase := '1.4)';
v_Assign_XID := COALESCE(lower(pgelog_get_param('pgelog_assign_xact_id')),'n');
v_Time_Fmt   := COALESCE(pgelog_get_param('pgelog_timestamp_format'),'YYYY-MM-DD HH24:MI:SS.US');
-- 1.5) Process case of inactive logging
IF (v_Is_Active <> 'y') THEN -- do not initialize if logging is NOT active
   -- 1.5.1) Set NULL to pg_variables to create it
   v_Phase := '1.5.1)';
   PERFORM pgv_set(v_Package, 'pgelog_conn_string'     , v_Conn_Str  , v_Transact);
   PERFORM pgv_set(v_Package, 'pgelog_conn_name'       , v_Conn_Name , v_Transact);
   PERFORM pgv_set(v_Package, 'pgelog_pg_version'      , v_Pg_Version, v_Transact);
   PERFORM pgv_set(v_Package, 'pgelog_assign_xact_id'  , v_Assign_XID, v_Transact);
   PERFORM pgv_set(v_Package, 'pgelog_timestamp_format', v_Time_Fmt  , v_Transact);
   RETURN FALSE; -- do not connect and exit
END IF;
-- 2) Get Postgres port and major version
v_Phase := '2)';
v_Port       := COALESCE(pgelog_get_param('pgelog_port'),'5432');
v_Pg_Version := COALESCE(split_part(current_setting('server_version'),'.', 1)::INTEGER, 0);
-- 3) Compose connection string (with search_path security issue)
v_Phase := '3)';
v_Conn_Str := format('host=localhost port=%s dbname=%s user=%s options=-csearch_path=%s', v_Port, current_database(), current_user, current_schema);
-- 4) Get random unique connection name for current session
v_Phase := '4)';
v_Conn_Name := gen_random_uuid();
-- 5) Open connection as unprivileged user
v_Phase := '5)';
PERFORM dblink_connect_u(v_Conn_Name,v_Conn_Str);
-- 6) Save connection name, connection string, Postgres major version etc (with is_transactional = v_Transact)
v_Phase := '6)';
PERFORM pgv_set(v_Package, 'pgelog_conn_string'     , v_Conn_Str  , v_Transact);
PERFORM pgv_set(v_Package, 'pgelog_conn_name'       , v_Conn_Name , v_Transact);
PERFORM pgv_set(v_Package, 'pgelog_pg_version'      , v_Pg_Version, v_Transact);
PERFORM pgv_set(v_Package, 'pgelog_assign_xact_id'  , v_Assign_XID, v_Transact);
PERFORM pgv_set(v_Package, 'pgelog_timestamp_format', v_Time_Fmt  , v_Transact);
-- 7) Write report to pgelog_logs if enabled
v_Phase := '7)';
v_Log_Call := COALESCE(lower(pgelog_get_param('pgelog_log_init_call')),'y');
IF (v_Log_Call = 'y') THEN
   v_Log_Type  := 'pgelog';
   v_Log_Func  := format('%s.pgelog_init',current_schema);
   v_Phase     := '7)';
   v_Log_Info  := format('v_Conn_Str=%s',COALESCE(v_Conn_Str,'NULL'));
   PERFORM pgelog_to_log(
                         v_Log_Type -- 1; Kind of log record - FAIL, WARN, INFO etc
                        ,v_Log_Func -- 2; Name of log record source - stored function, trigger, SQL clause etc
                        ,v_Log_Info -- 3; Body of log record
                        ,v_Phase    -- 4; Serial number or label of current phase of logical operation inside above mentioned log_func, for example 1, 2, 2.a
                        );
END IF;
-- 8) Return positive result
RETURN TRUE;
-- 9) Swallow exceptions to prevent influence to the caller
EXCEPTION
   WHEN OTHERS THEN
     RAISE NOTICE 'FAIL of %() at phase %',v_Proc_Name,v_Phase;
     RETURN FALSE;
END;
$BODY$ LANGUAGE plPGSQL VOLATILE;

GRANT EXECUTE ON FUNCTION pgelog_init() TO PUBLIC;
-----------------------------------

-- 2.5) Close logger dblink connection and delete pg_variables
CREATE OR REPLACE FUNCTION pgelog_close()
RETURNS BOOLEAN -- TRUE if logger closed
-----------------------------------
AS $BODY$
DECLARE
v_Phase     TEXT;
v_Proc_Name TEXT := 'pgelog_close';
v_Package   TEXT;
v_Conn_Name TEXT;
-----------------------------------
BEGIN
-- 1) Get pg_variables package name used in pgelog
v_Phase := '1)';
v_Package := COALESCE(pgelog_get_param('pgelog_pgv_package'),'pgelog');
-- 2) Check if connection exists
IF (pgv_exists(v_Package,'pgelog_conn_name')) THEN
   -- 2.1) Get connection name
   v_Phase := '2.1)';
   v_Conn_Name := pgv_get(v_Package,'pgelog_conn_name',NULL::TEXT);
   -- 2.3) Close connection
   v_Phase := '2.1)';
   PERFORM dblink_disconnect(v_Conn_Name);
   -- 2.3) Delete all pg_variables for package v_Package
   v_Phase := '2.3)';
   IF (pgv_exists(v_Package)) THEN
       v_Phase := '2.3.1)';
       PERFORM pgv_remove(v_Package);
   END IF;
   -- 2.4) Success
   RETURN TRUE;
ELSE
   RETURN TRUE;
END IF;
-- 3) Swallow exceptions to prevent influence to the caller
EXCEPTION
   WHEN OTHERS THEN
     RAISE NOTICE 'FAIL of %() at phase %',v_Proc_Name,v_Phase;
     RETURN FALSE;
END;
$BODY$ LANGUAGE plPGSQL VOLATILE;

GRANT EXECUTE ON FUNCTION pgelog_close() TO PUBLIC;
-----------------------------------

-- 2.6) Delete records of logger table pgelog_logs records older than TTL in minutes and writes report to log if 'pgelog_log_clean_call'='y'
CREATE OR REPLACE FUNCTION pgelog_clean_log
(
 p_ttl_minutes INTEGER = NULL -- 1; TTL (time to live) of pgelog_logs records in minutes; NULL means value set by 'pgelog_ttl_minutes' parameter
)
RETURNS BOOLEAN -- TRUE if pgelog_logs ceaned
-----------------------------------
AS $BODY$
DECLARE
v_Phase       TEXT;
v_Proc_Name   TEXT := 'pgelog_clean_log';
v_TTL_Minutes INTEGER;
v_Log_Call    TEXT;
v_Num_Deleted INTEGER;
v_Boundary    TIMESTAMP;
v_Log_Type    TEXT;
v_Log_Func    TEXT;
v_Log_Info    TEXT;
-----------------------------------
BEGIN
-- 1) Get TTL (time to live) of pgelog_logs records in minutes
v_Phase := '1)';
v_TTL_Minutes := COALESCE(p_ttl_minutes, pgelog_get_param('pgelog_ttl_minutes')::INTEGER, 1);
v_Log_Call    := COALESCE(lower(pgelog_get_param('pgelog_log_clean_call')),'y');

-- 2) Delete obsolete pgelog_logs records
v_Phase := '2)';
v_Boundary := clock_timestamp() - interval '1 minute'*v_TTL_Minutes;
DELETE
FROM  pgelog_logs
WHERE log_stamp < v_Boundary;
GET DIAGNOSTICS v_Num_Deleted = ROW_COUNT;

-- 3) Write report to pgelog_logs if enabled
IF (v_Log_Call = 'y') THEN
   v_Phase := '3)';
   v_Log_Type := 'pgelog';
   v_Log_Func := format('%s.pgelog_clean_log',current_schema);
   v_Log_Info := format('p_ttl_minutes=%s, v_TTL_Minutes=%s, deleted %s rows of pgelog_logs'
                         ,COALESCE(p_ttl_minutes::TEXT,'NULL')
                         ,COALESCE(v_TTL_Minutes::TEXT,'NULL')
                         ,COALESCE(v_Num_Deleted::TEXT,'NULL')
                        );
   PERFORM pgelog_to_log(
                         v_Log_Type -- 1; Kind of log record - FAIL, WARN, INFO etc
                        ,v_Log_Func -- 2; Name of log record source - stored function, trigger, SQL clause etc
                        ,v_Log_Info -- 3; Body of log record
                        ,v_Phase    -- 4; Serial number or label of current phase of logical operation inside above mentioned log_func, for example 1, 2, 2.a
                        );
END IF;

-- 4) Success
RETURN TRUE;

-- 5) Swallow exceptions to prevent influence to the caller
EXCEPTION
   WHEN OTHERS THEN
     RAISE NOTICE 'FAIL of %() at phase %',v_Proc_Name,v_Phase;
     RETURN FALSE;
END;
$BODY$ LANGUAGE plPGSQL VOLATILE;

GRANT EXECUTE ON FUNCTION pgelog_clean_log(INTEGER) TO PUBLIC;
-----------------------------------

-- 2.7) Disable logging permanently but can be overrided for current session by pgelog_enable_locally() call
CREATE OR REPLACE FUNCTION pgelog_disable()
RETURNS BOOLEAN -- TRUE if logging permanently disabled
-----------------------------------
AS $BODY$
DECLARE
v_Phase     TEXT;
v_Proc_Name TEXT := 'pgelog_disable';
v_Is_Active TEXT := 'n';
-----------------------------------
BEGIN
-- 1) Set pg_variable package name
v_Phase := '1)';
PERFORM pgelog_set_param('pgelog_is_active', v_Is_Active);

-- 2) Disable right now!
v_Phase := '2)';
PERFORM pgelog_disable_locally();

-- 3) Return positive result
RETURN TRUE;

-- 4) Swallow exceptions to prevent influence to the caller
EXCEPTION
   WHEN OTHERS THEN
     RAISE NOTICE 'FAIL of %() at phase %',v_Proc_Name,v_Phase;
     RETURN FALSE;
END;
$BODY$ LANGUAGE plPGSQL VOLATILE;

GRANT EXECUTE ON FUNCTION pgelog_disable() TO PUBLIC;
-----------------------------------

-- 2.8) Disable logging for current session only
CREATE OR REPLACE FUNCTION pgelog_disable_locally()
RETURNS BOOLEAN -- TRUE if logging locally disabled
-----------------------------------
AS $BODY$
DECLARE
v_Phase     TEXT;
v_Proc_Name TEXT := 'pgelog_disable_locally';
v_Package   TEXT;
v_Is_Active TEXT := 'n';
v_Is_Trans  TEXT;
v_Transact  BOOLEAN;
v_Conn_Name TEXT;
-----------------------------------
BEGIN
-- 1) Get pg_variable package name
v_Phase := '1)';
v_Package := COALESCE(pgelog_get_param('pgelog_pgv_package'),'pgelog');

-- 2) Read pgelog parameters for transactional mode
v_Phase := '2)';
v_Is_Trans := COALESCE(lower(pgelog_get_param('pgelog_pgv_transactional')),'y');
v_Transact := (v_Is_Trans = 'y');

-- 3) Set pg_variable pgelog_is_active
v_Phase := '3)';
IF (pgv_exists(v_Package, 'pgelog_is_active')) THEN
   -- 3.1) Delete pgelog_is_active pg_variable
   v_Phase := '3.1)';
   PERFORM pgv_remove(v_Package, 'pgelog_is_active');
END IF;
-- 3.2) Set pgelog_is_active pg_variable
v_Phase := '3.2)';
PERFORM pgv_set(v_Package, 'pgelog_is_active', v_Is_Active, v_Transact);

-- 4) Check if pgelog_conn_name pg_variable already set for current session
v_Phase := '4)';
IF (pgv_exists(v_Package, 'pgelog_conn_name')) THEN
   -- 4.1) Get connection name
   v_Phase := '4.1)';
   v_Conn_Name := pgv_get(v_Package, 'pgelog_conn_name', NULL::TEXT);
   -- 4.2) Close connection
   v_Phase := '4.2)';
   PERFORM dblink_disconnect(v_Conn_Name);
   -- 4.3) Delete pgelog_conn_string pg_variable to invoke pgelog_init() later in required
   v_Phase := '4.3)';
   PERFORM pgv_remove(v_Package, 'pgelog_conn_name');
END IF;

-- 5) Return positive result
RETURN TRUE;

-- 6) Swallow exceptions to prevent influence to the caller
EXCEPTION
   WHEN OTHERS THEN
     RAISE NOTICE 'FAIL of %() at phase %',v_Proc_Name,v_Phase;
     RETURN FALSE;
END;
$BODY$ LANGUAGE plPGSQL VOLATILE;

GRANT EXECUTE ON FUNCTION pgelog_disable_locally() TO PUBLIC;
-----------------------------------

-- 2.9) Enable logging permanently but can be overrided for current session by pgelog_disable_locally() call
CREATE OR REPLACE FUNCTION pgelog_enable()
RETURNS BOOLEAN -- TRUE if logging permanently enabled
-----------------------------------
AS $BODY$
DECLARE
v_Phase     TEXT;
v_Proc_Name TEXT := 'pgelog_enable';
v_Is_Active TEXT := 'y';
-----------------------------------
BEGIN
-- 1) Set pg_variable package name
v_Phase := '1)';
PERFORM pgelog_set_param('pgelog_is_active', v_Is_Active);

-- 2) Enable right now!
v_Phase := '2)';
PERFORM pgelog_enable_locally();

-- 3) Return positive result
RETURN TRUE;

-- 4) Swallow exceptions to prevent influence to the caller
EXCEPTION
   WHEN OTHERS THEN
     RAISE NOTICE 'FAIL of %() at phase %',v_Proc_Name,v_Phase;
     RETURN FALSE;
END;
$BODY$ LANGUAGE plPGSQL VOLATILE;

GRANT EXECUTE ON FUNCTION pgelog_enable() TO PUBLIC;
-----------------------------------

-- 2.10) Enable logging for current session only
CREATE OR REPLACE FUNCTION pgelog_enable_locally()
RETURNS BOOLEAN -- TRUE if logging locally enabled
-----------------------------------
AS $BODY$
DECLARE
v_Phase     TEXT;
v_Proc_Name TEXT := 'pgelog_enable_locally';
v_Package    TEXT;
v_Is_Active  TEXT := 'y';
v_Is_Trans   TEXT;
v_Transact   BOOLEAN;
-----------------------------------
BEGIN
-- 1) Get pg_variable package name
v_Phase := '1)';
v_Package := COALESCE(pgelog_get_param('pgelog_pgv_package'),'pgelog');

-- 2) Read pgelog parameters for transactional mode
v_Phase := '2)';
v_Is_Trans := COALESCE(lower(pgelog_get_param('pgelog_pgv_transactional')),'y');
v_Transact := (v_Is_Trans = 'y');

-- 3) Set pg_variable pgelog_is_active
v_Phase := '3)';
IF (pgv_exists(v_Package, 'pgelog_is_active')) THEN
    -- 3.1) Delete pgelog_is_active pg_variable
    v_Phase := '3.1)';
    PERFORM pgv_remove(v_Package, 'pgelog_is_active');
END IF;
-- 3.2) Set pgelog_is_active pg_variable
v_Phase := '3.2)';
PERFORM pgv_set(v_Package, 'pgelog_is_active', v_Is_Active, v_Transact);

-- 4) Return positive result
RETURN TRUE;

-- 5) Swallow exceptions to prevent influence to the caller
EXCEPTION
   WHEN OTHERS THEN
     RAISE NOTICE 'FAIL of %() at phase %',v_Proc_Name,v_Phase;
     RETURN FALSE;
END;
$BODY$ LANGUAGE plPGSQL VOLATILE;

GRANT EXECUTE ON FUNCTION pgelog_enable_locally() TO PUBLIC;
-----------------------------------

-- 2.11) Write log info into pgelog_logs table
CREATE OR REPLACE FUNCTION pgelog_to_log
(
 p_log_type  TEXT        -- 1; Kind of log record - FAIL, WARN, INFO etc
,p_log_func  TEXT        -- 2; Name of log record source - stored function, trigger, SQL clause etc
,p_log_info  TEXT        -- 3; Body of log record
,p_phase     TEXT        -- 4; Serial number or label of current phase of logical operation inside above mentioned log_func, for example 1, 2, 2.a
,p_sqlerrm   TEXT = NULL -- 5; Current Postgres SQLSTATE
,p_sqlstate  TEXT = NULL -- 6; Current Postgres SQLERRM
)
RETURNS BOOLEAN -- Returns TRUE on success and FALSE on any exception
-----------------------------------
AS $BODY$
DECLARE
v_Phase      TEXT;
v_Proc_Name  TEXT := 'pgelog_to_log';
v_Log_DT     TIMESTAMP := clock_timestamp();
v_Log_Stamp  TEXT;
v_ShouldLog  BOOLEAN := TRUE;
v_Package    TEXT;
v_Conn_Name  TEXT;
v_Pg_Version INTEGER;
v_Set_XID    BOOLEAN := TRUE;
v_Xact_ID    TEXT;
v_Time_Fmt   TEXT;
v_SQL        TEXT;
v_Is_Active  TEXT;
v_Need_Init  BOOLEAN := TRUE;
-----------------------------------
BEGIN
-- 1) Check environment and call pgelog_init() if required
-- 1.1) Get pg_variables package name from table
v_Phase := '1.1)';
v_Package := COALESCE(pgelog_get_param('pgelog_pgv_package'),'pgelog');
-- 1.2) Check if pg_variable pgelog_is_active exist
v_Phase := '1.2)';
IF (pgv_exists(v_Package,'pgelog_is_active')) THEN
    -- 1.2.1) Read pg_variable pgelog_is_active
    v_Phase := '1.2.1)';
    v_Is_Active := pgv_get(v_Package,'pgelog_is_active',NULL::TEXT);
    -- 1.2.2) Exit if pgelog_is_active = 'n' (i.e., logging is disabled)
    v_Phase := '1.2.2)';
    IF (v_Is_Active = 'n') THEN
        RETURN TRUE;
    END IF;
END IF;
-- 1.3) Check if pg_variable pgelog_conn_name exist
v_Phase := '1.3)';
IF (pgv_exists(v_Package,'pgelog_conn_name')) THEN
    -- 1.3.1) If pgelog_conn_name esixt it's not need to call pgelog_init()
    v_Need_Init := FALSE;
END IF;
-- 1.4) Call pgelog_init() if required
v_Phase := '1.4)';
IF (v_Need_Init) THEN
    v_ShouldLog := pgelog_init();
END IF;

-- 2) Get prepared connection and other parameters from prepared pg_variables
IF (v_ShouldLog) THEN
    -- 2.1) Get connection name, Postgres major version and xact_id processing type
    v_Phase := '2.1)';
    v_Conn_Name   := pgv_get(v_Package,'pgelog_conn_name' ,NULL::TEXT);
    v_Pg_Version  := pgv_get(v_Package,'pgelog_pg_version',NULL::INTEGER);
    v_Set_XID := (lower(COALESCE(pgv_get(v_Package,'pgelog_assign_xact_id',NULL::TEXT),'n')) = 'y');
    -- 2.2) Ask a transaction's ID or assign a new transaction's ID if the current transaction does not have one already
    IF (v_Set_XID) THEN
       -- 2.2.1) Assign xact_id
       IF (v_Pg_Version < 13) THEN
           v_Phase := '2.2.1.1)';
           v_Xact_ID := txid_current()::TEXT;
       ELSE
           v_Phase := '2.2.1.2)';
           v_Xact_ID := pg_current_xact_id()::TEXT;
       END IF;
    ELSE
       -- 2.2.2) Ask xact_id
       IF (v_Pg_Version < 13) THEN
           v_Phase := '2.2.2.1)';
           v_Xact_ID := txid_current_if_assigned()::TEXT;
       ELSE
           v_Phase := '2.2.2.2)';
           v_Xact_ID := pg_current_xact_id_if_assigned()::TEXT;
       END IF;
    END IF;
ELSE
    -- 2.3) Logging is not activated, exiting...
    RETURN TRUE;
END IF;

-- 3) Prepare SQL and execute it via dblink()
-- 3.1) Get other parameters
v_Phase := '3.1)';
v_Time_Fmt  := pgv_get(v_Package,'pgelog_timestamp_format',NULL::TEXT);
v_Log_Stamp := to_char(v_Log_DT, v_Time_Fmt);

-- 3.2) Prepare SQL
v_Phase := '3.2)';
v_SQL := format($DYNSQL$
INSERT INTO pgelog_logs
(
 log_stamp
,log_type
,log_func
,phase
,log_info
,xact_id
,sqlstate
,sqlerrm
,conn_name
)
VALUES
(
 to_timestamp(%L,%L)
,%L
,%L
,%L
,%L
,%L
,%L
,%L
,%L
)$DYNSQL$
,v_Log_Stamp,v_Time_Fmt
,p_log_type
,p_log_func
,p_phase
,p_log_info
,v_Xact_ID
,p_sqlstate
,p_sqlerrm
,v_Conn_Name
); -- end of format()

-- 3.3) Execute SQL via dblink()
v_Phase := '3.3)';
PERFORM dblink_exec(v_Conn_Name, v_SQL);

-- 4) Exit
RETURN TRUE;

-- 5) Swallow exceptions to prevent influence to the caller
EXCEPTION
   WHEN OTHERS THEN
     RAISE NOTICE 'FAIL of %() at phase %',v_Proc_Name,v_Phase;
     RETURN FALSE;
END;
$BODY$ LANGUAGE plPGSQL VOLATILE;

GRANT EXECUTE ON FUNCTION pgelog_to_log(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO PUBLIC;
-----------------------------------
--
-- 3) Views of pgelog
--
-- 3.1) View to show stored extended logging data with times
CREATE OR REPLACE VIEW pgelog_vw_logs
AS
SELECT L.log_stamp AS log_stamp -- 1; Date and time of log record (got by LOCALTIMESTAMP)
      ,L.log_type  AS log_type  -- 2; Kind of log record - FAIL, WARN, INFO etc
      ,L.log_func  AS log_func  -- 3; Name of log record source - stored function, trigger, SQL clause etc
      ,L.phase     AS phase     -- 4; Serial number or label of current phase of logical operation inside above mentioned log_func, for example 1, 2, 2.a
      ,CASE WHEN (L.xact_id = LEAD(L.xact_id) OVER W1)
            THEN ROUND(EXTRACT(EPOCH FROM (L.log_stamp - LEAD(L.log_stamp) OVER W1))::NUMERIC,3)
            ELSE NULL
       END         AS time_s    -- 5; Time in seconds since the previous log entry for the same xact_id
      ,CASE WHEN (L.xact_id IS NOT NULL)
            THEN ROUND(EXTRACT(EPOCH FROM (L.log_stamp - MIN(L.log_stamp) OVER W2))::NUMERIC,3)
            ELSE NULL
       END         AS delta_t   -- 6; Time in seconds since first log entry for the same xact_id (~ time from function call to this phase)
      ,L.log_info  AS log_info  -- 7; Body of log record
      ,L.xact_id   AS xact_id   -- 8; txid::text from txid_current() or txid_current_if_assigned() for PG < 13 or txid8::text from pg_current_xact_id() or pg_current_xact_id_if_assigned() for PG >= 13
      ,L.sqlstate  AS sqlstate  -- 9; Current Postgres SQLSTATE
      ,L.sqlerrm   AS sqlerrm   --10; Current Postgres SQLERRM
      ,L.conn_name AS conn_name --11; Name of dblink used for pseudo-autonomous transaction execution
FROM   pgelog_logs L
WINDOW W1 AS (PARTITION BY L.log_func, L.xact_id ORDER BY L.log_stamp DESC)
      ,W2 AS (PARTITION BY L.log_func, L.xact_id ORDER BY L.log_stamp ASC)
;

COMMENT ON VIEW   pgelog_vw_logs           IS 'pgelog extension view to show stored extended logging data with times';
COMMENT ON COLUMN pgelog_vw_logs.log_stamp IS 'Date and time of log record (got by LOCALTIMESTAMP)';
COMMENT ON COLUMN pgelog_vw_logs.log_type  IS 'Kind of log record - FAIL, WARN, INFO etc';
COMMENT ON COLUMN pgelog_vw_logs.log_func  IS 'Name of log record source - stored function, trigger, SQL clause etc';
COMMENT ON COLUMN pgelog_vw_logs.phase     IS 'Serial number or label of current phase of logical operation inside above mentioned log_func, for example 1, 2, 2.a';
COMMENT ON COLUMN pgelog_vw_logs.time_s    IS 'Time in seconds since the previous log entry for the same xact_id';
COMMENT ON COLUMN pgelog_vw_logs.delta_t   IS 'Time in seconds since first log entry for the same xact_id (~ time from function call to this phase)';
COMMENT ON COLUMN pgelog_vw_logs.log_info  IS 'Body of log record';
COMMENT ON COLUMN pgelog_vw_logs.xact_id   IS 'txid::text from txid_current() or txid_current_if_assigned() for PG < 13 or txid8::text from pg_current_xact_id() or pg_current_xact_id_if_assigned() for PG >= 13';
COMMENT ON COLUMN pgelog_vw_logs.sqlstate  IS 'Current Postgres SQLSTATE';
COMMENT ON COLUMN pgelog_vw_logs.sqlerrm   IS 'Current Postgres SQLERRM';
COMMENT ON COLUMN pgelog_vw_logs.conn_name IS 'Name of dblink used for pseudo-autonomous transaction execution';

GRANT SELECT ON pgelog_vw_logs TO PUBLIC;
-----------------

