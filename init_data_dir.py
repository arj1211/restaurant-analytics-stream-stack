import os
import shutil

paths = [
    ("data/airflow/dags", False),
    ("data/airflow/logs", True),
    ("data/airflow/plugins", False),
    ("data/pgadmin", True),
    ("data/postgres", True),
    ("data/metabase", True),
]

for path, to_replace in paths:
    try:
        if to_replace and os.path.exists(path):
            try:
                os.remove(path)
            except PermissionError as e:
                shutil.rmtree(path)
    except Exception as e:
        print(f"Couldn't remove {path}")
        print(e)
    os.makedirs(path, exist_ok=True)
