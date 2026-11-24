<!-- safefly-copilot: skill:research-methodology v1 -->
<!-- safefly-copilot-run-id: 2def904f-19e2-424d-8952-d84bde65da75 -->
<!-- safefly-copilot-session: 1bde191a-101c-462b-b952-baa763c2f83a -->

# Vector databases in Azure: create, populate, and query

**The basic workflow is: choose a vector-capable service, create its index or
schema, generate embeddings for your content, upload the content and embeddings,
and search using an embedding of the user's question.** Azure AI Search provides
a managed search index; Azure Cosmos DB for NoSQL and Azure Database for
PostgreSQL can keep vectors alongside operational data.

This report explains the choices and walks through Azure AI Search using Python.
It is an educational example, not a proposal to change SafeFly's architecture.
No Azure resources were created, no repository dependencies were installed, and
the example was not executed against a live Azure service.

**Evidence:** Microsoft documentation reviewed on November 19, 2026. Service
capabilities and SDK patterns below are documentation-confirmed; availability,
quota, permissions, cost, and behavior in your subscription remain unverified.
Current Microsoft pages also use the name **Foundry IQ (Azure AI Search)**. This
report uses Azure AI Search for the underlying search service and index APIs.

## 1. What a vector database actually stores

An **embedding** is a list of numbers produced by a model to represent content.
Similar content tends to have nearby vectors in the model's embedding space.
For example, a question about undoing a failed release can match a paragraph
about rollback even when the exact words differ.

There are three distinct components:

| Component | Responsibility |
| --- | --- |
| Embedding model, such as an Azure OpenAI deployment | Turn content and questions into numerical vectors. |
| Vector-capable store | Store vectors, content, and metadata; find nearby vectors efficiently. |
| Application or agent | Authenticate the user, enforce access, retrieve results, and optionally generate an answer. |

Creating an Azure OpenAI deployment alone does **not** create a searchable database
of your documents. Likewise, creating a vector field alone does not populate it.
Either your ingestion code or a configured vectorization pipeline must generate
and store the embeddings. [1][2]

For text, a useful stored record normally contains:

- A stable chunk ID and parent document ID.
- The chunk's original text and a source reference for citations.
- The embedding vector.
- Filterable metadata, such as a corpus, category, or authorized access groups.
- Source revision, content hash, and embedding model/version metadata for maintenance.

Keep the original text: a vector is not a readable copy of the document. Also
treat embeddings as sensitive derived data, not anonymized text.

### The two data flows

```text
Ingestion:
Source documents -> extract text -> split into chunks -> embedding model
                 -> store each chunk + vector + metadata

Query:
User question -> authenticate and authorize -> same embedding model
              -> vector search with access filters -> ranked chunks + sources
              -> optionally send authorized chunks to a language model
```

The optional last step is **retrieval-augmented generation (RAG)**. Retrieval
returns evidence; a language model uses that evidence to compose an answer.
Neither vector search nor RAG is model fine-tuning, and neither guarantees that
the returned content or generated answer is correct.

## 2. Which Azure service should you use?

There is no single Azure resource named "the vector database." Several services
support vector storage and retrieval. Start with workload needs and any database
you already operate, rather than automatically adding another service. [3]

| Choice | A useful fit | What you create | How you populate and query it |
| --- | --- | --- | --- |
| Azure AI Search | Search across documents or multiple sources; managed extraction, hybrid search, and optional semantic ranking. | Search service and an index containing text, metadata, vector fields, and vector-search configuration. | Push JSON records and vectors, or use indexers and integrated vectorization; query through Search APIs or SDKs. |
| Azure Cosmos DB for NoSQL | Operational JSON data and embeddings should remain together; an existing Cosmos DB workload. | Account/database/container, a container vector policy, and a vector indexing policy. | Upsert items containing embeddings; query with `VectorDistance`, `TOP`, and appropriate partition/access predicates. |
| Azure Database for PostgreSQL flexible server | Relational data, SQL, joins, and an existing PostgreSQL workload. | Server/database, allowlisted `vector` extension, table with a vector column, and an appropriate vector index. | Insert or upsert rows and vectors; use SQL distance operators such as `<=>` for cosine distance. |

Azure DocumentDB, Azure Managed Redis, and Azure SQL Database are additional
options; see Microsoft's broader comparison rather than assuming identical
limits or retrieval features across products. [3]

**Trade-off:** AI Search maintains a separate, derived index that you must keep
aligned with source changes. A database-centered design can store a record and
its embedding together, but you still need to regenerate the embedding when its
content changes. Exact data freshness and vector-index readiness depend on the
chosen service and configuration.

The worked example below uses **Azure AI Search** to make every step visible.
It does not imply that AI Search is always preferable to an existing database.

## 3. Create the Azure resources and configure access

### Create a search service

In the Azure portal, find Azure AI Search / Foundry IQ and create a service. Choose
your subscription, resource group, unique service name, region, and pricing tier.
Verify that the region and tier support your intended features and capacity.
The service endpoint looks like:

```text
https://<search-service-name>.search.windows.net
```

The Free tier is intended for small evaluations, not a production capacity or
availability commitment. Use current service limits and pricing for sizing. [4]

### Deploy an embedding model

Create or use an approved Azure OpenAI resource and deploy an embedding model.
The example assumes **`text-embedding-3-small` with its default 1,536 dimensions**.
Record the resource endpoint and the **deployment name**, which can differ from
the underlying model name. The API's `model` argument is the deployment name. [2]

The query embedding and document embeddings must use the same compatible model,
model version, and dimensionality. Matching vector length alone is insufficient:
two different models can produce incompatible vectors of the same length.

### Configure Microsoft Entra ID permissions

Enable role-based access on the search service. Assign roles through
**Access control (IAM)** using an identity authorized to assign roles. [5]

| Identity/task | Role and scope |
| --- | --- |
| Create the index definition | `Search Service Contributor` on the search service. |
| Load, update, and query documents | `Search Index Data Contributor` on the search service or appropriate index. |
| Query-only runtime | `Search Index Data Reader` on the appropriate scope. |
| Call the embedding model | `Cognitive Services OpenAI User` on the Azure OpenAI resource. |

For this all-in-one learning example, your development identity needs the first,
second, and fourth permissions. Data Contributor already includes query access.
In production, separate schema administration, ingestion, and query identities.
Subscription Contributor alone does not grant Search document access through
Entra authentication.

Also ensure that the machine running the example can reach **both** endpoints.
For private resources, use the approved network path and DNS; do not make a
private service public just to run a sample. Role assignment changes can take
time to propagate.

## 4. Worked example: create and populate an AI Search vector index

The example uses three tiny, synthetic text chunks. They are already chunked;
this is not a PDF parser or a production ingestion implementation.

### Prepare a local scratch environment

Run the following in a new scratch directory **outside the SafeFly checkout**.
These are instructions for a standalone demo, not new repository dependencies.
Use a supported Python version; Python 3.11 or later is a reasonable starting
point, subject to the selected packages' requirements.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install azure-search-documents azure-identity openai

az login
az account set --subscription '<subscription-id>'

$env:AZURE_SEARCH_ENDPOINT = 'https://<search-service-name>.search.windows.net'
$env:AZURE_SEARCH_INDEX = 'vector-learning-demo-v1'
$env:AZURE_OPENAI_ENDPOINT = 'https://<openai-resource-name>.openai.azure.com'
$env:AZURE_OPENAI_EMBEDDING_DEPLOYMENT = '<your-text-embedding-3-small-deployment>'
```

Replace the placeholders. These environment variables contain configuration,
not API keys. `DefaultAzureCredential` uses available credentials, including your
Azure CLI login locally; a deployed application can use managed identity. Ensure
the identity selected by the credential chain is the one you authorized. [2][5]

Combine the next four Python blocks, in order, into `vector_demo.py` in that
scratch directory. The schema block is a **one-time creation** step: it deliberately
fails if the named index already exists instead of silently modifying it.

### Connect to Search and the embedding model

```python
import os
import time

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    HnswAlgorithmConfiguration,
    HnswParameters,
    SearchField,
    SearchFieldDataType,
    SearchIndex,
    SearchableField,
    SimpleField,
    VectorSearch,
    VectorSearchProfile,
)
from azure.search.documents.models import VectorizedQuery
from openai import OpenAI

credential = DefaultAzureCredential()
search_endpoint = os.environ["AZURE_SEARCH_ENDPOINT"]
index_name = os.environ["AZURE_SEARCH_INDEX"]
deployment = os.environ["AZURE_OPENAI_EMBEDDING_DEPLOYMENT"]
dimensions = 1536

token_provider = get_bearer_token_provider(
    credential, "https://ai.azure.com/.default"
)
embedding_client = OpenAI(
    base_url=os.environ["AZURE_OPENAI_ENDPOINT"].rstrip("/") + "/openai/v1/",
    api_key=token_provider,
)
index_client = SearchIndexClient(search_endpoint, credential)
search_client = SearchClient(search_endpoint, index_name, credential)


def embed(text: str) -> list[float]:
    response = embedding_client.embeddings.create(model=deployment, input=text)
    vector = response.data[0].embedding
    if len(vector) != dimensions:
        raise ValueError("Embedding output does not match the index dimensions.")
    return vector
```

Despite the SDK argument name `api_key`, the value above is an Entra token-provider
callable, not a stored API key. The v1 endpoint and token scope follow Microsoft's
current Python embeddings example. [2]

### Create the index schema

```python
index = SearchIndex(
    name=index_name,
    fields=[
        SimpleField(name="id", type=SearchFieldDataType.String, key=True),
        SimpleField(name="parentId", type=SearchFieldDataType.String),
        SimpleField(name="source", type=SearchFieldDataType.String),
        SimpleField(
            name="corpus", type=SearchFieldDataType.String, filterable=True
        ),
        SearchableField(name="content", type=SearchFieldDataType.String),
        SearchField(
            name="contentVector",
            type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
            searchable=True,
            hidden=True,
            vector_search_dimensions=dimensions,
            vector_search_profile_name="vector-profile",
        ),
    ],
    vector_search=VectorSearch(
        algorithms=[
            HnswAlgorithmConfiguration(
                name="hnsw-cosine",
                parameters=HnswParameters(metric="cosine"),
            )
        ],
        profiles=[
            VectorSearchProfile(
                name="vector-profile",
                algorithm_configuration_name="hnsw-cosine",
            )
        ],
    ),
)
index_client.create_index(index)
```

This creates an empty index, not embedded content. The vector field holds 1,536
numbers per chunk and references a vector-search profile. HNSW is an approximate
nearest-neighbor algorithm; cosine is the similarity metric used here. The text
field supports keyword search, and `corpus` supports filtering. The vector is
hidden from normal retrieval responses. [1][6]

### Generate embeddings and upload the records

```python
documents = [
    {
        "id": "guide-release-0001",
        "parentId": "guide-release",
        "source": "demo:release-guide",
        "corpus": "demo",
        "content": (
            "After a failed application release, roll back to the previous "
            "working version and verify that the application is healthy."
        ),
    },
    {
        "id": "guide-backup-0001",
        "parentId": "guide-backup",
        "source": "demo:backup-guide",
        "corpus": "demo",
        "content": (
            "Database recovery restores data from a backup. Test restores "
            "regularly and retain backups according to the retention policy."
        ),
    },
    {
        "id": "guide-meetings-0001",
        "parentId": "guide-meetings",
        "source": "demo:meeting-guide",
        "corpus": "other",
        "content": "Publish the meeting agenda before the weekly planning call.",
    },
]

for document in documents:
    document["contentVector"] = embed(document["content"])

outcomes = search_client.upload_documents(documents=documents)
failures = [result for result in outcomes if not result.succeeded]
if failures:
    raise RuntimeError(f"Indexing failed for {len(failures)} demo chunks.")

deadline = time.monotonic() + 60
while search_client.get_document_count() < len(documents):
    if time.monotonic() >= deadline:
        raise TimeoutError("Demo documents were not searchable within 60 seconds.")
    time.sleep(2)
```

The actual population step is `upload_documents`: the client sends the text,
metadata, and vectors to Search. Creating the model or the index does not do this
automatically. Inspect every per-document result; a request can contain individual
failures. Accepted writes also need time to become searchable. The count check is
a bounded demonstration readiness check, not a production consistency guarantee.

`upload_documents` inserts new keys and replaces existing records with matching
keys. Send a complete record when using it. For partial updates, use merge or
merge-or-upload semantics deliberately; collections are replaced, not appended.
Re-uploading a key does not delete obsolete chunks with different keys. [7]

## 5. Query the index

### Pure vector search and hybrid search

Append this final block to the same file:

```python
question = "How can I undo a bad application deployment?"
query_vector = embed(question)
vector_query = VectorizedQuery(
    vector=query_vector,
    fields="contentVector",
    k_nearest_neighbors=5,
)

for mode, search_text in (("vector", None), ("hybrid", question)):
    results = search_client.search(
        search_text=search_text,
        vector_queries=[vector_query],
        filter="corpus eq 'demo'",
        vector_filter_mode="preFilter",
        select=["id", "content", "source"],
        top=3,
    )
    print(f"\n{mode} results:")
    for result in results:
        print(result["id"], result["@search.score"], result["source"])
        print(result["content"])
```

Run the completed file:

```powershell
.\.venv\Scripts\python.exe .\vector_demo.py
```

For later queries against the same index, reuse the connection and query blocks;
do not rerun the one-time schema creation. `source` values in this example are
synthetic labels, not real document URLs.

What happens during each query:

1. The question is embedded using the same deployment used during ingestion.
2. Search compares that vector with indexed vectors in the selected field.
3. The filter restricts the corpus before vector retrieval.
4. Search returns ranked records, including readable text and source references.

`k_nearest_neighbors=5` requests up to five vector candidates. `top=3` limits the
final returned list. Only two sample records match the filter, so this demo can
return at most two results. Exact order and scores must be observed, not assumed.

Passing `search_text=None` gives vector-only retrieval. Passing the question as
`search_text` adds keyword retrieval; AI Search merges the rankings using
**Reciprocal Rank Fusion (RRF)**. Hybrid search is useful when meaning matters but
exact identifiers, acronyms, or product names also matter. [1]

**Scores are not confidence percentages.** Search transforms or combines ranking
signals, and scores from vector-only and hybrid searches are not directly
comparable. A nearest-neighbor query can return the least-bad matches even when
none answers the question. Evaluate relevance rather than accepting every hit.

### Optional semantic reranking

Semantic ranking is a separate stage that reranks retrieved results using their
text. It requires a semantic configuration on the index and feature availability
on the service. It is not enabled by the sample above. Configure the relevant
text fields, then use a semantic query and the matching configuration name.
Microsoft's quickstart includes this variation. [1]

### Optional answer generation

To build a document assistant, send the authorized retrieved text and source
references to a chat model, alongside the question. Ask it to cite its sources
and say when evidence is insufficient. Treat document content as untrusted data,
not instructions that can change tool permissions or authorize actions.

Search itself returns matching records; it does not automatically produce a
grounded prose answer. A chat model deployment is optional for vector search.

## 6. Populate real documents instead of the three demo chunks

There are two common ingestion approaches. [6]

### Application-managed ingestion

Your job or application reads an approved source, extracts text, splits it into
chunks, generates embeddings, and uploads records. You own parsing, update and
deletion detection, retries, permissions metadata, and progress tracking.

Use chunks that preserve useful context, such as a heading and its paragraphs.
For experimentation, 500-1,000 tokens with modest overlap is a starting hypothesis,
not a universal optimum. Measure with representative questions and respect the
embedding model's current input limits. Tables, code, and PDFs often need more
careful extraction than splitting every fixed number of characters.

For larger loads, batch embedding requests within model quotas and Search uploads
within both document-count and payload-size limits. Microsoft's Search guidance
specifies up to 1,000 documents or about 16 MB per indexing request, whichever
limit is reached first. A document here means a **chunk record**, not an original
PDF. Retry transient failures with bounded backoff and surface persistent errors.

### Integrated vectorization

AI Search can orchestrate the ingestion pipeline for supported data sources:

```text
Supported source -> indexer -> text extraction and splitting skill
                 -> embedding skill -> chunk/vector index
```

The portal's **Import data** wizard can help create the data source, index,
skillset, and indexer. A source connector, an embedding skill, and correct field
mappings are still required; an arbitrary document URL is not automatically an
authorized, supported source. Use an indexer schedule and inspect its run history.

A **query-time vectorizer** is separately configured on a vector-search profile.
With it, callers can send a text vector query and Search calls the embedding
deployment. Without it, as in the Python example, the caller must supply the
vector. Configuring an ingestion embedding skill alone does not configure this
query-time behavior. [6]

For keyless integrated vectorization, the Search service's managed identity needs
access to the source and embedding resource. Grant appropriate source read access
and embedding-model permissions, and configure the required network connections.
Those outbound service permissions are separate from the caller's Search roles.

## 7. The equivalent path in Cosmos DB or PostgreSQL

### Azure Cosmos DB for NoSQL

Create or use a compatible account and database, then create a container with a
vector policy describing the embedding property's path, dimensions, data type,
and distance function. Add a vector index in its indexing policy, and upsert JSON
items containing source text, metadata, partition key, and generated vectors.
Use `SELECT TOP N ... ORDER BY VectorDistance(...)` with a query embedding and
the appropriate partition/access filters. [8]

Do not assume the index choice is interchangeable: the documented `flat` index
supports up to 505 dimensions, so it does not fit the 1,536-dimensional example.
`quantizedFlat` and `diskANN` support higher dimensions, but their documented
quantization path needs at least 1,000 vectors; a three-record experiment uses a
full scan instead. Check current account/throughput limitations and request-unit
costs before extrapolating from a tiny demo.

### Azure Database for PostgreSQL flexible server

Allowlist the extension named `vector`, enable it in the target database, and
create a table containing original content, metadata, and a `vector(1536)` column
for this model. Insert or upsert generated embeddings alongside the rows.
Add an appropriate supported vector index for scale. Query using a parameterized
SQL statement ordered by the cosine-distance operator `<=>`, with `LIMIT` and
required access predicates. Do not construct SQL by concatenating user text. [9]

These are different storage/query implementations of the same pattern:
**embed documents, store vectors with their source data, embed the question, and
retrieve the closest authorized records.**

## 8. Keep the store accurate, secure, and affordable

| Concern | Practical handling |
| --- | --- |
| Changed source content | Re-extract, re-chunk where needed, regenerate affected embeddings, and update the index. Track source revision and content hash. |
| Deleted documents or fewer replacement chunks | Explicitly remove every obsolete chunk, including stale source permissions. Uploading the new chunks alone is insufficient. |
| Model or dimension change | Build a new compatible vector field/index and re-embed the corpus. Validate before switching queries; do not mix incompatible vectors. |
| Authorization | Derive access filters from the authenticated identity and trusted policy. A user-supplied corpus filter, such as the demo's, is not an authorization system. Apply restrictions before returning text or sending it to a model. |
| Original source permissions | Do not assume a copied document retains its source ACL automatically. Configure supported permission ingestion/enforcement or implement trusted security filtering, including revocations. |
| Credentials and network | Use approved managed identities, least privilege, and private networking where required. Keep keys, tokens, sensitive text, vectors, and raw provider responses out of logs. |
| Retrieval quality | Test answer-bearing matches, irrelevant questions, exact IDs, filters, and permission boundaries. Compare vector and hybrid results; measure recall and latency. |
| Monitoring | Track ingestion failures and lag, embedding throttling, per-document write failures, query latency, index/vector capacity, and authorization failures. |
| Exact facts and audit state | Use authoritative records and exact queries for current state, ownership, approval, or audit evidence. Semantic similarity is not a substitute for those checks. |

Costs include the Search service or database, embedding tokens during ingestion
and queries, optional reranking, source storage, networking, and optional answer
generation. A 1,536-element float32 vector alone occupies 6,144 bytes (6 KiB),
before search-index structures, metadata, original text, replicas, and transfer
serialization. Overlap increases the number of chunks and embedding work.

Use the current pricing pages and representative load measurements, not a fixed
cost estimate from this report. Remove only the specific demo index and any
dedicated demo resources when finished. Deleting an index does not stop charges
for a paid Search service that remains provisioned. [3][4]

## 9. Troubleshooting

| Symptom | Check first |
| --- | --- |
| 401 authentication failure | Active credential/tenant, token audience, and the correct endpoint for the client. |
| 403 authorization failure | Search RBAC enabled, correct data-plane and embedding roles, role propagation, and network restrictions. |
| Embedding request returns 404 | Correct Azure OpenAI endpoint, `/openai/v1/` base path, and deployment name rather than an assumed model name. |
| 400 / dimension mismatch | Actual vector length, index dimensions, input size, and compatible model settings on ingestion and queries. |
| Index already exists | The demo creates it once. Reuse its query blocks or choose another dedicated demo index name; do not delete an unknown index. |
| Upload accepted but query is empty | Per-document outcomes, indexing readiness, selected index, filter values, and whether vectors were actually populated. |
| Similarity results seem wrong | Model/version mismatch, poor extraction or chunking, incompatible metric, stale content, restrictive filters, or irrelevant nearest neighbors. |
| 429 / throttling | Model token quota, request rate, Search/database capacity, and bounded retry behavior. |
| Integrated ingestion fails | Indexer execution history, source access, skill mappings, Search managed identity, model quota, and outbound networking. |

## References

All references are Microsoft documentation reviewed for this report. The worked
example combines the documented Search SDK pattern with Azure OpenAI embedding
generation; it is not presented as a cloud-validated deployment.

1. [Vector search quickstart](https://learn.microsoft.com/azure/search/search-get-started-vector?pivots=python)
2. [Generate embeddings with Azure OpenAI](https://learn.microsoft.com/azure/foundry/openai/how-to/embeddings)
3. [Choose an Azure service for vector search](https://learn.microsoft.com/azure/architecture/guide/technology-choices/vector-search)
4. [Create a search service in the Azure portal](https://learn.microsoft.com/azure/search/search-create-service-portal)
5. [Connect to Search using roles](https://learn.microsoft.com/azure/search/search-security-rbac)
6. [Integrated vectorization](https://learn.microsoft.com/azure/search/vector-search-integrated-vectorization)
7. [Update or rebuild a Search index](https://learn.microsoft.com/azure/search/search-howto-reindex#update-content)
8. [Vector search in Azure Cosmos DB for NoSQL](https://learn.microsoft.com/azure/cosmos-db/vector-search)
9. [Enable and use pgvector in Azure Database for PostgreSQL](https://learn.microsoft.com/azure/postgresql/extensions/how-to-use-pgvector)
