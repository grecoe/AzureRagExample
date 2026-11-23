"""How an application consumes the deployed API.

Usage:
    python client_example.py https://<api-fqdn> <api-client-id> "How do I rotate the ingestion key?"

The token comes from your own Azure CLI sign-in. The API's Easy Auth policy admits
only the operator's object ID, so any other identity receives 401 or 403.
"""

from __future__ import annotations

import json
import sys
import urllib.request

from azure.identity import AzureCliCredential


def ask(base_url: str, api_client_id: str, question: str, mode: str = "generative") -> dict:
    token = AzureCliCredential().get_token(f"api://{api_client_id}/.default").token
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/ask",
        data=json.dumps({"question": question, "mode": mode}).encode("utf-8"),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    if not request.full_url.startswith("https://"):
        raise ValueError("Use the https endpoint")
    with urllib.request.urlopen(request, timeout=120) as response:  # noqa: S310 - https enforced above
        return json.loads(response.read())


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    result = ask(sys.argv[1], sys.argv[2], sys.argv[3])
    print(result["answer"] or "(extractive: see passages)")
    for passage in result["passages"]:
        print(f"  [{passage['label']}] {passage['locator']}")
