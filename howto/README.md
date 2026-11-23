# How-To Guides

Task-focused guides for running the RAG example after it is deployed. For the deployment itself, start with [../deployment/README.md](../deployment/README.md).

| Guide | Use it to |
| --- | --- |
| [01-seed.md](01-seed.md) | Fill the index for the first time, from the sample data or a Git repository |
| [02-update-and-refresh-plan.md](02-update-and-refresh-plan.md) | Keep the index current, decide when to refresh and rebuild without downtime |
| [03-query.md](03-query.md) | Ask questions from your workstation or through the API |
| [04-consume.md](04-consume.md) | Use the system from an application, and add a caller safely |
| [05-operate.md](05-operate.md) | Monitor health, cost and quality |
| [06-troubleshoot.md](06-troubleshoot.md) | Diagnose common failures |

All commands assume PowerShell 7, a signed-in Azure CLI (`az login`) as the operator, and that you start in the `azure-rag-example` folder.
