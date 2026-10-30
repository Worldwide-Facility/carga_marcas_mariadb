# Carga API FRAX `marcas` → BigQuery

Destino: `worldwide-470917.cr_reportes.marcas_mariadb` (WRITE_TRUNCATE, `PARTITION BY DATE(fecha)`).

Origen:

- Principal: `https://frax.controltienda.com/api/v1/`
- Espejo: `https://frax2.controltienda.com/api/v1/` (si el principal no responde)

Repo: https://github.com/wwdiegovarela/carga_marcas_mariadb

## Local

```bash
cp .env.example .env   # FRAX_API_KEY
pip install -r requirements.txt
python main.py preview
python main.py sync
```

## Cloud Run Job + Scheduler

- Job marcas: `carga-marcas-mariadb` (región `southamerica-west1`) — `python main.py sync`
- Job personas: `carga-personas-frax` — `python main.py sync-personas`
- Imagen: `gcr.io/worldwide-470917/carga-marcas-mariadb`
- SA: `cargar-cr@worldwide-470917.iam.gserviceaccount.com`
- Scheduler marcas: `carga-marcas-mariadb-schedule` — `0 */4 * * *` America/Santiago
- Scheduler personas: `carga-personas-frax-schedule` — `0 8 * * *` America/Santiago
- Destino personas: `worldwide-470917.cr_reportes.personas_frax`
- Secreto: `carga-marcas-frax-api-key` (variable `FRAX_API_KEY`), en ambos jobs

### Conectar el repo a Cloud Build (una vez)

El GitHub App de Cloud Build todavía no ve este repositorio. Enlazalo aquí:

https://console.cloud.google.com/cloud-build/triggers;region=us-east1/connect?project=worldwide-470917

Elige GitHub → `wwdiegovarela/carga_marcas_mariadb`. Después:

```bash
gcloud builds triggers create github \
  --name=carga-marcas-mariadb \
  --repo-owner=wwdiegovarela \
  --repo-name=carga_marcas_mariadb \
  --branch-pattern="^main$" \
  --build-config=cloudbuild.yaml \
  --region=us-east1 \
  --project=worldwide-470917 \
  --service-account=projects/worldwide-470917/serviceAccounts/webscrapper@worldwide-470917.iam.gserviceaccount.com \
  --description="API FRAX marcas -> BigQuery cada push a main"
```

Push a `main` (con el trigger ya creado) reconstruye la imagen y actualiza el job.

```bash
# Primera vez (secretos + IAM): scripts/bootstrap_gcp.sh
gcloud builds submit --config cloudbuild.yaml --project worldwide-470917

# Correr ahora
gcloud run jobs execute carga-marcas-mariadb --region southamerica-west1 --project worldwide-470917
```
