select
    T.table_catalog,
    T.table_schema,
    T.table_name,
    T.table_type,
    C.column_name,
    C.ordinal_position
from information_schema."tables" as T
    right join information_schema."columns" as C
    on 
T.table_catalog=C.table_catalog AND
        T.table_schema=C.table_schema AND
        T.table_name=C.table_name
where T.table_catalog='restaurant_analytics'
    and T.table_schema in ('raw_data','analytics','staging')
order by T.table_catalog, 
	T.table_schema, 
	T.table_name, 
	C.ordinal_position;