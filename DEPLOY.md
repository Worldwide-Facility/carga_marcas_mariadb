# Carga MariaDB `marcas` → BigQuery

Destino: `worldwide-470917.cr_reportes.marcas_mariadb` (WRITE_TRUNCATE).

Repo: https://github.com/wwdiegovarela/carga_marcas_mariadb

## Local

```bash
cp .env.example .env   # MARIADB_USER / MARIADB_PASSWORD
pip install -r requirements.txt
python main.py preview
python main.py sync
```

## Cloud Run Job + Scheduler

- Job: `carga-marcas-mariadb` (región `us-east1`)
- Imagen: `gcr.io/worldwide-470917/carga-marcas-mariadb`
- SA: `cargar-cr@worldwide-470917.iam.gserviceaccount.com`
- Scheduler: `carga-marcas-mariadb-schedule` — `0 */4 * * *` America/Santiago
- Secretos: `carga-marcas-mariadb-user`, `carga-marcas-mariadb-password`

Push a `main` dispara Cloud Build (`cloudbuild.yaml`): construye la imagen, actualiza el job y el scheduler.

```bash
# Primera vez (secretos + IAM + trigger): ver scripts/bootstrap_gcp.sh
gcloud builds submit --config cloudbuild.yaml --project worldwide-470917

# Correr ahora
gcloud run jobs execute carga-marcas-mariadb --region us-east1 --project worldwide-470917
```
