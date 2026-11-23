# Tests

Unit tests for the logic that decides what gets indexed, what gets answered, and who gets in. They need no Azure resources and no network.

```powershell
cd src
python -m unittest discover -s tests -t .
```

| Class | Covers |
| --- | --- |
| `ChunkerTests` | Heading titles and anchors; headings inside code fences; HTML comment removal; the byte limit with multibyte text; stable IDs; hashes that ignore line endings |
| `SourceTests` | Git URL rules (HTTPS, host allow-list, no credentials); ref option injection; file filters and symlink skipping |
| `GroundingTests` | Valid cited output; uncited or unknown citations rejected; explicit not-found; the evidence gate failing closed; a source unable to close its block |
| `IngestPlanTests` | Unchanged files skipped; partial uploads reprocessed; shortened and removed files cleaned up; the empty-source and mass-delete guards, including chunks lost from files that still exist |
| `ConfigTests` | Local auth refused in Azure; the ingest role needs no request auth; Easy Auth requires principals; HTTP endpoints refused; principal ID normalization |
| `AuthorizeTests` | Only the allowed principal passes the API check |

What is not tested here: calls to Azure AI Search, Azure OpenAI or Easy Auth. Check those after deployment with [../../howto/03-query.md](../../howto/03-query.md).
