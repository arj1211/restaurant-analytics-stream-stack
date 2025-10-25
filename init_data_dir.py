import os
import shutil

paths = [
    "data/airflow/dags",
    "data/airflow/logs",
    "data/airflow/plugins",
    "data/pgadmin",
    "data/postgres",
    "data/metabase",
]

for path in paths:
    if os.path.exists(path):
        try:
            os.remove(path)
        except PermissionError as e:
            shutil.rmtree(path)
    os.makedirs(path)
