# Terraform — Technitium DNS + DHCP

Terraform equivalent of the [`ansible/`](../../ansible/README.md) Technitium setup:
manage both servers (`dnldns101` primary, `dnldns201` secondary) from one config.

> **Read this first — Ansible is the better fit here.** Technitium has **no official
> Terraform provider**, and its API is **imperative query-param calls, not RESTful
> CRUD**. This scaffold wraps the API with the generic **`terracurl`** provider, which
> means real limitations (below). It's provided for parity/preference; for day-to-day
> DNS/DHCP management the **Ansible** version is more idiomatic.

## How it maps to the Ansible version

| Concern | Approach (same design as Ansible) |
|---------|-----------------------------------|
| DNS records | **Single source** = the shared BIND files in `../../ansible/zones/`. Imported to the **primary**; the **secondary transfers** them. |
| Zones | `module.primary` creates Primary zones; `module.secondary` creates Secondary zones. |
| DHCP + settings | Pushed to **both** via each module; DHCP ranges **split** per host (`primary_dhcp_ranges` / `secondary_dhcp_ranges`). |
| Two servers | The `technitium` module is instantiated twice (`module.primary`, `module.secondary`). |

## Layout
```
terraform/technitium/
  versions.tf · variables.tf · main.tf         # two module instances
  terraform.tfvars.example
  modules/technitium/{settings,zones,dhcp}.tf   # terracurl_request resources
```

## Prerequisites
- Terraform ≥ 1.5.
- The **`../../ansible/zones/*.zone`** files must be present (shared source of truth) —
  i.e. the Ansible scaffold is on `main`/in your working tree.
- A Technitium API token via env: `export TF_VAR_api_token="..."`.

## Usage
```bash
cd terraform/technitium
cp terraform.tfvars.example terraform.tfvars     # edit; keep the token OUT of it
export TF_VAR_api_token="<token>"
terraform init
terraform plan
terraform apply
```

## Limitations (why Ansible is preferred)
- **No drift detection / no read.** `terracurl` fires the create request on apply and the
  destroy request on `destroy`; it does **not** reconcile against the server's actual
  state. Re-applying re-POSTs (fine for Technitium's idempotent `set`/`import`, noisy for
  `create`).
- **Token lands in state.** Technitium auths via a URL query param, so the token is
  embedded in request URLs and therefore in `terraform.tfstate`. Use an **encrypted
  remote backend**, or accept local-only state and guard it. State is gitignored here.
- **Endpoint/param names are unverified** — validate against your running version
  (`http://<host>:5380/api`).
- Record changes still go through the **zone files** (bump SOA serial) → primary import →
  secondary transfer, exactly as with Ansible.
