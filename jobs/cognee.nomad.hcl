# Cognee unified memory on Nomad — vendored from KSonny4/cognee-setup
# (jobs/cognee.nomad.hcl); that repo remains authoritative for the spec.
# Deployed here as part of the 2026-09-19 migration (fabric/omniroute retired).
# Cognee unified memory on Nomad (single job, one group, count = 1).
#
# Shape: server (owns /cognee-storage, single-writer) + mcp (stateless, API mode
# against the server) + edge (Caddy basic-auth, the only tunnel target).
# Conventions follow NomadSetup/jobs/registry.nomad.hcl: digest-pinned images,
# loopback statics, TCP service checks (HTTP checks would 401 against auth).
#
# Secrets arrive as HCL2 vars at the deploy edge (values from Bao, never logged):
#   nomad job run -var="llm_api_key=..." -var="cognee_api_key" jobs/cognee.nomad.hcl
# They live in Nomad's job store (ACL-gated, same trust boundary as the mgmt
# token). The edge htpasswd is NOT a var: host file mounted ro, registry pattern.
#
# Deploy-edge host prerequisites (M3, via ssh ovh-cloudflare):
#   /opt/nomad-volumes/cognee (uid 1000, holds /cognee-storage bind-mount)
#   /opt/nomad-volumes/cognee-auth/htpasswd (root:root 600, `caddy hash-password`
#     output for the edge password escrowed in Bao secret/projects/cognee/edge)

variable "llm_api_key" {
  type        = string
  default     = ""
  description = "LLM_API_KEY for the server (OpenAI-compatible). Empty boots demo mode — the runbook forbids deploying that way."
}

variable "cognee_api_key" {
  type        = string
  default     = ""
  description = "Service API key minted post-boot via /api/v1/auth/* (x-api-key upstream for MCP, REST clients)."
}

variable "jwt_secret" {
  type        = string
  default     = ""
  description = "Stable FASTAPI_USERS_* secrets (Bao projects/cognee/env jwt_secret). Without it cognee generates per-process random auth secrets and minted API keys die on every restart (field hit 2026-09-19). One value for all three vars; empty reintroduces the rot."
}

variable "edge_user" {
  type        = string
  default     = "cognee"
  description = "Edge basic-auth username (Caddy basicauth, tunnel-facing)."
}

variable "edge_hash" {
  type        = string
  default     = ""
  description = "Edge basic-auth bcrypt hash from `caddy hash-password` (deploy edge, local docker). One-way: safe in the job store, never commit. Empty refuses to boot the edge (see template guard)."
}

job "cognee" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "cognee" {
    count = 1

    # DYNAMIC loopback ports for ALL tasks (measured 2026-09-19): every
    # fixed favorite (8080/8090/8091/13700 + five randoms + 18081, which
    # was free at scan and squatted by a [::] stub by deploy time) gets
    # shadowed by phantom responders that even spoof TCP checks. The
    # tunnel does NOT need a static origin: scripts/point-tunnel.sh re-
    # points the ingress at the current dynamic edge port post-deploy
    # (read-modify-write, cognee rule only). Host-mode tasks share host
    # lo, so scheduler-assigned 127.0.0.1:<dyn> addrs (NOMAD_ADDR_* /
    # NOMAD_PORT_*) are exact for every task. verify-ours (127.0.0.1 row
    # + body + anon-401) stays the deploy gate.
    network {
      port "server" {
        host_network = "loopback"
      }
      port "mcp" {
        host_network = "loopback"
      }
      port "edge" {
        host_network = "loopback"
      }
    }

    # Host-dir bootstrap (no SSH on this project): docker auto-creates a missing
    # bind-mount source as root, which uid-1000 tasks can't write. This prestart
    # sidecar (container root == host root, default userns) owns the mkdir/chown
    # so the server bind-mount below always lands on a uid-1000-writable dir.
    task "bootstrap" {
      driver = "docker"

      config {
        image = "registry.pkubelka.cz/caddy:2026-09-19@sha256:d8c17a862962def15cde69863a3a463f25a2664942eafd7bdbf050e9c3116b83"
        volumes = [
          "/opt/nomad-volumes:/vol",
        ]
        args = [
          "sh", "-c",
          "mkdir -p /vol/cognee && chown 1000:1000 /vol/cognee && ls -ld /vol/cognee",
        ]
      }

      user = "root"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      resources {
        cpu    = 100
        memory = 48
      }
    }

    # NETWORK MODEL (measured 2026-09-19, not assumed): tasks do NOT share
    # loopback — server→8000 OK but edge→8000 refused on the same alloc, and
    # NOMAD_ADDR_* resolves loopback statics to 127.0.0.1 (host-publisher
    # address, invisible from sibling netns). So all mains run network_mode
    # "host" with EXPLICIT loopback binds: one shared 127.0.0.1, nothing on
    # the public interface (tunnel-only posture preserved). Statics stay
    # globally unique on host lo (portscan-verified). Single-tenant box,
    # ACL-gated submission: host-netns sharing is acceptable here.
    task "server" {
      driver = "docker"

      config {
        network_mode = "host"
        # Per-arch amd64 manifest (cluster is amd64-only). Upstream list digest
        # 7b25a8f3... observed 2026-09-19; full-list mirror is blocked by the
        # 100MB edge cap, so scripts/mirror-chunked.py copies amd64 only.
        image = "registry.pkubelka.cz/cognee:2026-09-19@sha256:288cc62e70957b1e603eacbe181523015cfc0d2612cf04bc0681f0326dd37e24"
        ports = ["server"]

        # Bind-mount, not a host_volume stanza: no client-config reship and no
        # agent restart (registry/dump/keeper stay up). Single-writer enforced
        # by count = 1 above. Both images run as uid 1000; host dir must match.
        volumes = [
          "/opt/nomad-volumes/cognee:/cognee-storage",
        ]
      }

      env {
        ENV                             = "production"
        # Loopback-only bind (host netns): 0.0.0.0 here would sit on the
        # VPS public interface. Port is scheduler-assigned (see group).
        BIND_ADDRESS                    = "127.0.0.1"
        HTTP_PORT                       = "${NOMAD_PORT_server}"
        LOG_LEVEL                       = "INFO"
        SYSTEM_ROOT_DIRECTORY           = "/cognee-storage/system"
        DATA_ROOT_DIRECTORY             = "/cognee-storage/data"
        DB_PROVIDER                     = "sqlite"
        VECTOR_DB_PROVIDER              = "lancedb"
        REQUIRE_AUTHENTICATION          = "true"
        ENABLE_BACKEND_ACCESS_CONTROL   = "false"
        # LLM+embeddings (2026-09-19): OpenRouter :free chat + LOCAL fastembed.
        # Gemini-direct died (402 depleted prepay on the shared key); Moonshot
        # hard-429 both models; the OpenRouter account holds ~$0.001 (gpt-4o-mini
        # credit-hold fails). :free pools flip by the minute (qwen/glm/gemma
        # all seen 429 AND 200 within one hour) — ride whichever probes 200,
        # re-probe the live free-list on churn. Zero spend either way.
        # Embeddings = in-image fastembed (bge-small, 384 — user: local small).
        # Durable follow-up: paid direct key (Meta/OpenAI); block shape stays.
        LLM_PROVIDER                    = "openai"
        LLM_ENDPOINT                    = "https://openrouter.ai/api/v1"
        # DOUBLE-PREFIX routing (measured 2026-09-19): cognee passes
        # LLM_MODEL verbatim to litellm.acompletion(model=, api_base=). The
        # first segment must be a litellm provider ("openai" + our endpoint
        # override); the REMAINDER is the OpenRouter model ID. Bare
        # "google/..." matches no litellm provider ("LLM Provider NOT
        # provided" — the field error in pipeline_runs). Pick = deepseek
        # (probed 200 while gemma/qwen/glm 429d ~16:05Z; see pool note above).
        LLM_MODEL                       = "openai/deepseek/deepseek-v4-flash-0731:free"
        LLM_API_KEY                     = "${var.llm_api_key}"
        EMBEDDING_PROVIDER              = "fastembed"
        EMBEDDING_MODEL                 = "BAAI/bge-small-en-v1.5"
        EMBEDDING_DIMENSIONS            = "384"
        # Skip the 30s LLM pre-flight (2026-09-19): the :free pool answers
        # real calls with 429+backoff (recoverable) but rarely within the
        # test window, so every cognify/search would 500 at the gate.
        # Real calls still authenticate live; revisit on a paid key.
        COGNEE_SKIP_CONNECTION_TEST     = "true"
        # Stable auth secrets (see var): per-process randoms invalidate
        # minted API keys on every restart. Same value, all three FastAPI-
        # Users domains (one app, one process family).
        FASTAPI_USERS_JWT_SECRET                  = "${var.jwt_secret}"
        FASTAPI_USERS_RESET_PASSWORD_TOKEN_SECRET = "${var.jwt_secret}"
        FASTAPI_USERS_VERIFICATION_TOKEN_SECRET   = "${var.jwt_secret}"
        # (aligned = for all three; the test enforces var wiring, not spaces)
      }

      # memory 1280 + RESUME-ON-OOM feed strategy (2026-09-19): 2048 cannot
      # place (steady-state fleet 5.8GB + 2.6GB group > 7.6GB node; stopping
      # dump/unleash for RAM is not our call). 1280 died once 35min in with
      # 54 chunks / 1312 entities COMMITTED (vectors persist in LanceDB) —
      # re-fire resumes past them. Repeat re-fire on OOM until COMPLETED;
      # each death loses only in-flight work. Never squeeze blind.
      resources {
        cpu    = 1000
        memory = 1280
      }

      service {
        name     = "cognee-server"
        port     = "server"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }

    task "mcp" {
      driver = "docker"

      config {
        network_mode = "host"
        # BYPASS the image entrypoint (Nomad `entrypoint` replaces it —
        # `command` does NOT: it becomes argv to the entrypoint, which then
        # appends a duplicate --transport and dies with exit 2; field hit
        # 2026-09-19). The entrypoint unconditionally appends `--host
        # 0.0.0.0`, which in host mode would publish the auth-less MCP
        # transport publicly. Direct binary invocation keeps --host
        # 127.0.0.1. VERIFY post-deploy: PID1 cmdline is the binary (no
        # entrypoint echoes) with exactly one --host, and 127.0.0.1:8001
        # in /proc/net/tcp.
        entrypoint = ["/app/.venv/bin/cognee-mcp"]
        # Per-arch amd64 manifest (list f4beabc8... observed 2026-09-19).
        image = "registry.pkubelka.cz/cognee-mcp:2026-09-19@sha256:db0a982ddb4d019e92d4d22eeb4b0d46c16c54260a59381bda1a1cea8b27cbcf"
        ports = ["mcp"]

        # API mode skips migrations and touches no storage: stateless, no
        # volume. --no-migration is belt-and-braces. Ports/addr are
        # scheduler-assigned (NOMAD_*); host lo is shared so they are exact.
        args = [
          "--no-migration",
          "--transport", "http",
          "--host", "127.0.0.1",
          "--port", "${NOMAD_PORT_mcp}",
          "--api-url", "http://${NOMAD_ADDR_server}",
          "--api-auth-scheme", "x-api-key",
        ]
      }

      env {
        # No TRANSPORT_MODE/HTTP_PORT: entrypoint bypassed (see command).
        # COGNEE_BASE_URL is dead config now (explicit --api-url wins) —
        # kept out deliberately so exactly one source sets the URL.
        COGNEE_API_AUTH_SCHEME  = "x-api-key"
        COGNEE_API_KEY          = "${var.cognee_api_key}"
      }

      # memory 448: measured 350MB idle on-VPS (VmRSS 2026-09-19); API-mode
      # MCP is thin HTTP translation (embeddings run server-side).
      resources {
        cpu    = 250
        memory = 448
      }

      service {
        name     = "cognee-mcp"
        port     = "mcp"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }

    task "edge" {
      driver = "docker"

      config {
        network_mode = "host"
        # Per-arch amd64 manifest (list 4c6e91c6... observed 2026-09-19).
        # The MCP transport ships no client auth, so the edge owns it for both
        # endpoints. No Access apps on these hostnames (machine clients).
        image = "registry.pkubelka.cz/caddy:2026-09-19@sha256:d8c17a862962def15cde69863a3a463f25a2664942eafd7bdbf050e9c3116b83"
        ports = ["edge"]

        # /local is the task dir (standard docker-driver mount of the template
        # output below) — no host-path coupling for the Caddyfile itself.
        # argv[0] MUST be the binary: this image sets no ENTRYPOINT, so bare
        # ["run", ...] execs a nonexistent "run" (field hit 2026-09-19).
        args = [
          "caddy",
          "run",
          "--config", "/local/Caddyfile",
          "--adapter", "caddyfile",
        ]
      }

      template {
        destination = "local/Caddyfile"
        data        = <<EOH
# (template data; site address binds host loopback — see task comment)
# auto_https off: no :80 redirect listener (host :80 belongs to coolify),
# no ACME — TLS terminates at Cloudflare, this edge is loopback-only.
{
	auto_https off
}
# Shared handlers (snippet: single source inside the template — both sites
# below import it, so auth/proxy can never drift between local and tunnel).
(edge-common) {
	# bind (NOT the site addresses below!): Caddy uses site addresses only
	# for Host matching and listens on :port all-interfaces by default.
	# Without this, the edge binds [::] (posture violation) and loses the
	# bind race to squatters (root cause of the 2026-09-19 "phantoms").
	# BOTH loopbacks (never a wildcard): the connector dials `localhost`
	# (::1-first) while direct checks use 127.0.0.1. Exact lo binds only.
	bind 127.0.0.1 ::1
	# Access log to stdout (alloc logs): origin-side proof of arrivals.
	# Default format, no secrets (paths+statuses).
	log
	# One-way bcrypt hash via -var (never git): even the job store can't
	# yield the password. Empty hash => Caddy refuses to boot (fail-closed).
	basic_auth {
		${var.edge_user} ${var.edge_hash}
	}
	# header_up Host: the edge terminates the public Host; upstreams must
	# see their OWN address. cognee-mcp (uvicorn) 421s foreign Hosts
	# (field hit 2026-09-19); the API tolerates them today but uniform
	# rewriting keeps the next strict backend from breaking the same way.
	# header_up -Authorization: STRIP the edge basic-auth before proxying.
	# The server prefers the Authorization header over X-Api-Key: forwarded
	# edge creds (Basic, meaningless to it) 401 every keyed REST call
	# (field hit 2026-09-19 — direct X-Api-Key 200s, edge-forwarded 401s).
	# Backends never need it (server: X-Api-Key; mcp: its own key upstream).
	handle /api/* {
		reverse_proxy {{ env "NOMAD_ADDR_server" }} {
			header_up Host {http.reverse_proxy.upstream.hostport}
			header_up -Authorization
		}
	}
	handle /mcp* {
		reverse_proxy {{ env "NOMAD_ADDR_mcp" }} {
			header_up Host {http.reverse_proxy.upstream.hostport}
			header_up -Authorization
		}
	}
	# NOTE: NOMAD_* resolve to scheduler-assigned 127.0.0.1:<dyn>; host lo
	# is shared so they are exact (measured 2026-09-19).
	handle {
		respond "cognee edge ok" 200
	}
}
# Site 1: loopback + dynamic port — local checks (Host 127.0.0.1:<port>).
http://127.0.0.1:{{ env "NOMAD_PORT_edge" }} {
	import edge-common
}
# Site 2: the PUBLIC hostname on the SAME socket/port (never bare :80 —
# host :80 belongs to coolify). The tunnel terminates TLS and forwards
# Host: cognee.pkubelka.cz, which matches ONLY here. Without this site,
# tunnel requests match no site and Caddy answers empty-200 (field hit
# 2026-09-19: localhost:8102/127.0.0.1:8102 redirect experiment proved
# the connector dials fine — the 200s were unmatched-Host at OUR edge).
http://cognee.pkubelka.cz:{{ env "NOMAD_PORT_edge" }} {
	import edge-common
}
EOH
      }

      # memory 64: caddy idle ~30MB (observed in edge logs path).
      resources {
        cpu    = 100
        memory = 64
      }

      service {
        name     = "cognee-edge"
        port     = "edge"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }
  }
}
