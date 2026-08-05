 terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

# -----------------------------
# Inputs
# -----------------------------
variable "lan_ip" {
  description = "Host LAN IP to bind nginx mTLS edge (Test_createEnvelope_v3.sh uses https://LAN:8443)"
  type        = string
  default     = "192.168.1.25"
}

variable "mtls_port" {
  description = "LAN port for nginx mTLS edge"
  type        = number
  default     = 8443
}

# Flower knobs
variable "run_id" {
  description = "Shared experiment identifier used by Hub, backend, and clients"
  type        = string
  default     = "local-pathmnist-ab-001"
}

variable "flower_rounds" {
  description = "Number of FL rounds"
  type        = number
  default     = 10
}

variable "local_epochs" {
  description = "Local epochs per client"
  type        = number
  default     = 1
}

variable "learning_rate" {
  description = "Client learning rate"
  type        = number
  default     = 0.001
}

variable "batch_size" {
  description = "PathMNIST client batch size"
  type        = number
  default     = 32
}

variable "train_fraction" {
  description = "Fraction of eligible PathMNIST training samples retained"
  type        = number
  default     = 0.80
}

variable "cancer_samples_per_ab_hospital" {
  description = "Cancer samples per label retained at Hospital A and B"
  type        = number
  default     = 100
}

variable "pathmnist_partition_profile" {
  description = "Named PathMNIST partition profile selected by all Flower participants"
  type        = string
  default     = "COMPLEMENTARY_ABC_V1"
}

variable "pathmnist_partition_seed" {
  description = "Deterministic seed used to allocate disjoint PathMNIST class slices"
  type        = number
  default     = 20260728
}

variable "org_a_id" { 
  type    = string 
  default = "org://HospitalA" 
}

variable "org_b_id" { 
   type = string
   default = "org://HospitalB" 
}

variable "org_c_id" {
  type    = string
  default = "org://HospitalC"
}

variable "issuer_mtls_port" {
  type = number
  default     = 9443
}

variable "bench" {
  type    = bool
  default = false
}

locals {
  repo_root = abspath("${path.module}/../..")
}

# -----------------------------
# Network
# -----------------------------
resource "docker_network" "fc" {
  name = "fc"
}

# -----------------------------
# Redis
#  - app.py default REDIS_URL expects hostname "redis"
# -----------------------------
resource "docker_image" "redis" {
  name         = "redis:7-alpine"
  keep_locally = true
}

resource "docker_container" "redis" {
  name  = "redis"
  image = docker_image.redis.name

  networks_advanced { name = docker_network.fc.name }

  must_run = true
  restart  = "unless-stopped"
}


# ------------------------------------------------------
# signer 
#    - simulate a secure enclave for members private keys
#    - it provides DPoP on request form clients
# -------------------------------------------------------
resource "docker_image" "holder_signer" {
  name = "fcac/holder-signer:local"
  build {
    context    = "${local.repo_root}/vfp-governance/signer"
    dockerfile = "${local.repo_root}/vfp-governance/signer/Dockerfile"
    no_cache   = false
  }
}

resource "docker_container" "holder_signer" {
  name  = "holder-signer"
  image = docker_image.holder_signer.name

  networks_advanced { name = docker_network.fc.name }

  env = [
    "HOLDER_KEYS_DIR=/vault/holder_keys",
  ]

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/vault/holder_keys")
    container_path = "/vault/holder_keys"
    read_only      = true
  }

  must_run = true
  restart  = "unless-stopped"
}



# -----------------------------
# verifier-app (Gatekeeper / envelope service)
#  - nginx.conf proxies to http://verifier-app:9000 (so container must be named verifier-app)
#  - app.py uses /app/state for binds+envelopes (FCAC_STATE_DIR)
# -----------------------------
resource "docker_image" "verifier_app" {
  name = "fcac/verifier-app:local"
  build {
    context    = "${local.repo_root}/vfp-governance/gatekeeper"
    dockerfile = "${local.repo_root}/vfp-governance/gatekeeper/Dockerfile"
    no_cache   = false
  }
  keep_locally = true
}

resource "docker_container" "verifier_app" {
  name  = "verifier-app"
  image = docker_image.verifier_app.name

  networks_advanced { name = docker_network.fc.name }

  env = [
    "FCAC_CERTS_DIR=/app/verifier/certs",
    "FCAC_STATE_DIR=/app/state",
    "REDIS_URL=redis://redis:6379/0",
    "FCAC_ENVELOPE_CHANNEL=fcac:envelopes:created",
    "REQUIRE_MTLS_HEADERS=true",
    "KYO_SESSION_TTL=1200",
    "ENVELOPE_TTL=1209600",    
    "BENCH=${var.bench ? "1" : "0"}"
  ]

  # Host state directory must exist; app will create /app/state/binds and /app/state/envelopes.
  volumes {
    host_path      = "${local.repo_root}/vfp-governance/verifier/state"
    container_path = "/app/state"
  }

 volumes {
    host_path      = "${local.repo_root}/vfp-governance/verifier/events"
    container_path = "/app/events"
  }

   volumes {
        host_path      = "${local.repo_root}/vfp-governance/verifier/certs"
        container_path = "/app/verifier/certs"
        read_only      = true
  }

  ports { 
    internal = 9000 
    external = 9000
    ip = "127.0.0.1"
  }


  depends_on = [docker_container.redis]
  must_run   = true
  restart    = "unless-stopped"
}

# -----------------------------
# nginx mTLS edge
#  - Dockerfile copies nginx.conf at build time
#  - certs are mounted at runtime to /etc/nginx/certs
# -----------------------------
resource "docker_image" "verifier_proxy" {
  name = "fcac/verifier-proxy:local"
  build {
    context    = "${local.repo_root}/vfp-governance/verifier/nginx"
    dockerfile = "${local.repo_root}/vfp-governance/verifier/nginx/Dockerfile"
  }
  keep_locally = true
}

resource "docker_container" "verifier_proxy" {
  name  = "verifier-proxy"
  image = docker_image.verifier_proxy.name

  networks_advanced { 
     name = docker_network.fc.name 
     aliases = ["verifier.local"]  
  }

  ports {
    internal = 8443
    external = var.mtls_port
    ip       = var.lan_ip
  }

  # mTLS material used by nginx; Test_createEnvelope_v3.sh also uses hub.crt/hub.key from this tree.
  volumes {
    host_path      = "${local.repo_root}/vfp-governance/verifier/certs"
    container_path = "/etc/nginx/certs"
    read_only      = true
  }

  depends_on = [docker_container.verifier_app]
  must_run   = true
  restart    = "unless-stopped"
}

# -------------------------------------------------------------------
#  issuer-proxy
# -------------------------------------------------------------------

resource "docker_volume" "issuer_registry_hospitala" { name = "issuer-registry-hospitala" }
resource "docker_volume" "issuer_registry_hospitalb" { name = "issuer-registry-hospitalb" }

resource "docker_image" "issuer_proxy" {
  name = "fcac/issuer-proxy:local"
  build {
    context    = "${local.repo_root}/vfp-core/issuers/nginx"
    dockerfile = "${local.repo_root}/vfp-core/issuers/nginx/Dockerfile"
  }
  keep_locally = true
}

resource "docker_container" "issuer_proxy" {
  name  = "issuer-proxy"
  image = docker_image.issuer_proxy.name

  networks_advanced {
    name    = docker_network.fc.name
    aliases = ["issuer-hospitala.local", "issuer-hospitalb.local"]
  }

  ports {
    internal = 8443
    external = var.issuer_mtls_port
    ip       = var.lan_ip
  }

  # reuse the same cert directory you already use; now it also contains issuer-proxy.crt/key
  volumes {
    host_path      = "${local.repo_root}/vfp-governance/verifier/certs"
    container_path = "/etc/nginx/certs"
    read_only      = true
  }

  depends_on = [
    docker_container.issuer_hospitala,
    docker_container.issuer_hospitalb
  ]

  must_run = true
  restart  = "unless-stopped"
}



# -------------------------------------------------------------------
#  Issuer container + 2 clients
# -------------------------------------------------------------------
resource "docker_image" "issuer" {
  name = "fcac/issuer:local"
  build {
    context    = "${local.repo_root}/vfp-core/issuers"
    dockerfile = "${local.repo_root}/vfp-core/issuers/Dockerfile"
    no_cache   = false
  }
}


resource "docker_container" "issuer_hospitala" {
  name  = "issuer-hospitala"
  image = docker_image.issuer.name

  networks_advanced { name = docker_network.fc.name }

  env = [
    "ORG=${var.org_a_id}",
    "VERIFIER_URL=https://verifier-proxy:8443",
    "CA_CRT=/run/certs/ca.crt",
    "VERIFY_TLS=1",
    "ADMIN_CRT=/run/certs/admin.crt",
    "ADMIN_KEY=/run/certs/admin.key",
    "REGISTRY_DIR=/vault/registry",
    "MEMBER_ENTITLEMENTS_PATH=/app/config/member_entitlements.json",
  ]


  volumes {
  volume_name    = docker_volume.issuer_registry_hospitala.name
  container_path = "/vault/registry"
  read_only      = false
 }


  volumes {
    host_path      = abspath("${local.repo_root}/vfp-core/issuers/config/hospital_a_entitlements.json")
    container_path = "/app/config/member_entitlements.json"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/ca.crt")
    container_path = "/run/certs/ca.crt"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/HospitalA-admin.crt")
    container_path = "/run/certs/admin.crt"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/HospitalA-admin.key")
    container_path = "/run/certs/admin.key"
    read_only      = true
  }

  depends_on = [docker_container.verifier_proxy]
  must_run   = true
  restart    = "unless-stopped"
}

resource "docker_container" "issuer_hospitalb" {
  name  = "issuer-hospitalb"
  image = docker_image.issuer.name

  networks_advanced { name = docker_network.fc.name }

  env = [
    "ORG=${var.org_b_id}",
    "VERIFIER_URL=https://verifier-proxy:8443",
    "CA_CRT=/run/certs/ca.crt",
    "VERIFY_TLS=1",
    "ADMIN_CRT=/run/certs/admin.crt",
    "ADMIN_KEY=/run/certs/admin.key",
    "REGISTRY_DIR=/vault/registry",
    "MEMBER_ENTITLEMENTS_PATH=/app/config/member_entitlements.json"
  ]

  volumes {
  volume_name    = docker_volume.issuer_registry_hospitalb.name
  container_path = "/vault/registry"
  read_only      = false
 }


  volumes {
    host_path      = abspath("${local.repo_root}/vfp-core/issuers/config/hospital_b_entitlements.json")
    container_path = "/app/config/member_entitlements.json"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/ca.crt")
    container_path = "/run/certs/ca.crt"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/HospitalB-admin.crt")
    container_path = "/run/certs/admin.crt"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/HospitalB-admin.key")
    container_path = "/run/certs/admin.key"
    read_only      = true
  }

  depends_on = [docker_container.verifier_proxy]
  must_run   = true
  restart    = "unless-stopped"
}




# -------------------------------------------------------------------
# Hub (coordination orchestrator)
# -------------------------------------------------------------------
resource "docker_image" "hub" {
  name = "fcac/hub:local"
  build {
    context    = "${local.repo_root}/vfp-core/hub" 
    dockerfile = "${local.repo_root}/vfp-core/hub/Dockerfile"
    no_cache   = false
  }
  keep_locally = true
}

resource "docker_container" "hub" {
  name  = "fc-hub"
  image = docker_image.hub.name

  networks_advanced { name = docker_network.fc.name }

  # Optional: expose for debugging
  ports {
    internal = 8080
    external = 8080
    ip       = "127.0.0.1"
  }

  env = [
    "REDIS_URL=redis://redis:6379",
    "RUN_ID=${var.run_id}",
    "FLOWER_ROUNDS=${var.flower_rounds}",
    "MIN_CLIENTS=2",
    "LOCAL_EPOCHS=${var.local_epochs}",
    "LEARNING_RATE=${var.learning_rate}",
    "FLOWER_BACKEND_URL=http://flower-server:8081",
    #"VERIFY_TLS=0",
    "HUB_CERT_CRT=/run/certs/hub.crt",
    "HUB_CERT_KEY=/run/certs/hub.key",
    "VERIFIER_URL=https://verifier.local:8443",
    "ACTOR_CATALOG_PATH=/app/config/actors.json",
  ]


  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/ca.crt")
    container_path = "/run/certs/ca.crt"
    read_only      = true
  }
 
 volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/hub.crt")
    container_path = "/run/certs/hub.crt"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/hub.key")
    container_path = "/run/certs/hub.key"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/vault")
    container_path = "/vault"
    read_only      = false
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-core/issuers/config/actors.json")
    container_path = "/app/config/actors.json"
    read_only      = true
  }


  depends_on = [docker_container.redis]
  must_run   = true
  restart    = "unless-stopped"
}


#------------------------------------------------------------------
# Frontend container (for Federated Hub coordination)
# -------------------------------------------------------------------
resource "docker_image" "frontend" {
  name = "fcac/frontend:local"
  build {
    context    = "${local.repo_root}/vfp-core/frontend" 
    dockerfile = "${local.repo_root}/vfp-core/frontend/Dockerfile"
    no_cache   = false
  }
}


resource "docker_container" "frontend_even" {
  name  = "fcac-frontend"
  image = docker_image.frontend.name
  
  networks_advanced { name = docker_network.fc.name }
  
  ports {
    internal = 80
    external = 8082
    ip       = "127.0.0.1"
  }

  env = [
    "HUB_URL=http://fc-hub:8080",
    "ISSUER_A_URL=http://issuer-hospitala:8080",
    "ISSUER_B_URL=http://issuer-hospitalb:8080",
    "DPoP_HTU=https://verifier.local/admission/check",
    "SIGNER_URL=http://holder-signer:8090",

  ]

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/vault/holder_keys")  
    container_path = "/vault/holder_keys"
    read_only      = true
  }

  depends_on = [ docker_container.hub, 
                 docker_container.verifier_proxy, 
                 docker_container.issuer_hospitala, 
                 docker_container.issuer_hospitalb,
                 docker_container.holder_signer
               ]

  must_run   = true
  restart    = "unless-stopped"
}

 
# -------------------------------------------------------------------
# Flower Backend (orchestrator) + 2 clients
# -------------------------------------------------------------------
resource "docker_image" "flower_server" {
  name = "fcac/flower-server:local"
  build {
    context    = "${local.repo_root}/vfp-core/backend"
    dockerfile = "${local.repo_root}/vfp-core/backend/flower_server/Dockerfile"
    no_cache   = false
  }
  keep_locally = true
}

resource "docker_container" "flower_server" {
  name  = "flower-server"
  image = docker_image.flower_server.name

  networks_advanced { name = docker_network.fc.name }

  # Expose HTTP API port for Hub coordination (and later predict)
  #ports {
  #  internal = 8081
  #  external = 8081
  #  ip       = "127.0.0.1"
  #}

  env = [
    "REDIS_URL=redis://redis:6379",
    "VERIFIER_URL=https://verifier-proxy:8443",
    "HUB_URL=http://fc-hub:8080",
    "RUN_ID=${var.run_id}",
    "BACKEND_URL=http://flower-server:8081",
    "CONTROL_PORT=8081",
    "VERIFY_TLS=0",
    "FLOWER_ROUNDS=${var.flower_rounds}",
    "MIN_CLIENTS=2",
    "DEVICE=cpu",
    "TRAIN_FRACTION=${var.train_fraction}",
    "CANCER_SAMPLES_PER_AB_HOSPITAL=${var.cancer_samples_per_ab_hospital}",
    "PATHMNIST_PARTITION_PROFILE=${var.pathmnist_partition_profile}",
    "PATHMNIST_PARTITION_SEED=${var.pathmnist_partition_seed}",
    "BATCH_SIZE=${var.batch_size}",
    "LOCAL_EPOCHS=${var.local_epochs}",
    "LEARNING_RATE=${var.learning_rate}",
    "MEDMNIST_ROOT=/tmp/medmnist",
    "HUB_CERT_CRT=/run/certs/hub.crt",
    "HUB_CERT_KEY=/run/certs/hub.key",

    # NEW requirement: simulated enclave storage root
    "VAULT_ROOT=/vault",
  ]

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/hub.crt")
    container_path = "/run/certs/hub.crt"
    read_only      = true
  }

  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/certs/hub.key")
    container_path = "/run/certs/hub.key"
    read_only      = true
  }

  # Simulated enclave/vault storage: host verifier/vault -> container /vault
  volumes {
    host_path      = abspath("${local.repo_root}/vfp-governance/verifier/vault")
    container_path = "/vault"
    read_only      = false
  }

  depends_on = [docker_container.redis, docker_container.hub, docker_container.verifier_proxy]
  must_run   = true
  restart    = "unless-stopped"
}


# Shared Flower client image
resource "docker_image" "flower_client" {
  name = "openhealth/flower-client:local"

  build {
    context    = "${local.repo_root}/vfp-core/backend"
    dockerfile = "${local.repo_root}/vfp-core/backend/flower_client/Dockerfile"
  }

  keep_locally = true
}


# Flower Client - Hospital A
resource "docker_container" "flower_client_a" {
  name  = "flower-client-a"
  image = docker_image.flower_client.name
  gpus  = "all"

  networks_advanced {
    name = docker_network.fc.name
  }

  env = [
    "HOSPITAL=A",
    "ORG_ID=${var.org_a_id}",
    "RUN_ID=${var.run_id}",
    "HUB_URL=http://fc-hub:8080",
    "SERVER_ADDRESS=flower-server:8080",
    "LOCAL_EPOCHS=${var.local_epochs}",
    "LEARNING_RATE=${var.learning_rate}",
    "BATCH_SIZE=${var.batch_size}",
    "TRAIN_FRACTION=${var.train_fraction}",
    "CANCER_SAMPLES_PER_AB_HOSPITAL=${var.cancer_samples_per_ab_hospital}",
    "PATHMNIST_PARTITION_PROFILE=${var.pathmnist_partition_profile}",
    "PATHMNIST_PARTITION_SEED=${var.pathmnist_partition_seed}",
    "MEDMNIST_ROOT=/tmp/medmnist",
    "DEVICE=cuda",
  ]

  depends_on = [docker_container.flower_server]
  must_run   = true
  restart    = "unless-stopped"
}

# Flower Client - Hospital B
resource "docker_container" "flower_client_b" {
  name  = "flower-client-b"
  image = docker_image.flower_client.name
  gpus  = "all"

  networks_advanced {
    name = docker_network.fc.name
  }

  env = [
    "HOSPITAL=B",
    "ORG_ID=${var.org_b_id}",
    "RUN_ID=${var.run_id}",
    "HUB_URL=http://fc-hub:8080",
    "SERVER_ADDRESS=flower-server:8080",
    "LOCAL_EPOCHS=${var.local_epochs}",
    "LEARNING_RATE=${var.learning_rate}",
    "BATCH_SIZE=${var.batch_size}",
    "TRAIN_FRACTION=${var.train_fraction}",
    "CANCER_SAMPLES_PER_AB_HOSPITAL=${var.cancer_samples_per_ab_hospital}",
    "PATHMNIST_PARTITION_PROFILE=${var.pathmnist_partition_profile}",
    "PATHMNIST_PARTITION_SEED=${var.pathmnist_partition_seed}",
    "MEDMNIST_ROOT=/tmp/medmnist",
    "DEVICE=cuda",
  ]

  depends_on = [docker_container.flower_server]
  must_run   = true
  restart    = "unless-stopped"
}

  

# Flower Client - Hospital C
# Hospital C is the data source. Charlie remains the sponsored guest principal.
resource "docker_container" "flower_client_c" {
  name  = "flower-client-c"
  image = docker_image.flower_client.name
  gpus  = "all"

  networks_advanced {
    name = docker_network.fc.name
  }

  env = [
    "HOSPITAL=C",
    "ORG_ID=${var.org_c_id}",
    "RUN_ID=${var.run_id}",
    "HUB_URL=http://fc-hub:8080",
    "SERVER_ADDRESS=flower-server:8080",
    "LOCAL_EPOCHS=${var.local_epochs}",
    "LEARNING_RATE=${var.learning_rate}",
    "BATCH_SIZE=${var.batch_size}",
    "TRAIN_FRACTION=${var.train_fraction}",
    "CANCER_SAMPLES_PER_AB_HOSPITAL=${var.cancer_samples_per_ab_hospital}",
    "PATHMNIST_PARTITION_PROFILE=${var.pathmnist_partition_profile}",
    "PATHMNIST_PARTITION_SEED=${var.pathmnist_partition_seed}",
    "MEDMNIST_ROOT=/tmp/medmnist",
    "DEVICE=cuda",
  ]

  depends_on = [docker_container.flower_server]
  must_run   = true
  restart    = "unless-stopped"
}


# -------------------------------------------------------------------
# Outputs
# -------------------------------------------------------------------
output "hub_container" {
  value = docker_container.hub.name
}

output "client_a_container" {
  value = docker_container.flower_client_a.name
}

output "client_b_container" {
  value = docker_container.flower_client_b.name
}

output "client_c_container" {
  value = docker_container.flower_client_c.name
}


output "mtls_base_url" {
  value       = "https://${var.lan_ip}:${var.mtls_port}"
  description = "Use this as LAN in Test_createEnvelope.sh (https://LAN:8443)"
}
