"""Credentials and model clients. No keys anywhere: every call uses Entra ID tokens.

- In Azure: the workload's user-assigned managed identity (AZURE_CLIENT_ID).
- On a workstation: the developer's Azure CLI sign-in (`az login`).
"""

from __future__ import annotations

from azure.identity import AzureCliCredential as SyncAzureCliCredential
from azure.identity import ManagedIdentityCredential as SyncManagedIdentityCredential
from azure.identity.aio import AzureCliCredential, ManagedIdentityCredential, get_bearer_token_provider
from openai import AsyncOpenAI
from semantic_kernel import Kernel
from semantic_kernel.connectors.ai.open_ai import OpenAIChatCompletion, OpenAITextEmbedding

from .config import Settings

COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default"
CHAT_SERVICE_ID = "chat"
EMBEDDING_SERVICE_ID = "embedding"


def async_credential(settings: Settings):
    """Explicit credential choice; no environment-variable secrets are ever consulted."""
    if settings.managed_identity_client_id:
        return ManagedIdentityCredential(client_id=settings.managed_identity_client_id)
    if settings.running_in_azure:
        raise RuntimeError("AZURE_CLIENT_ID is required when running in Azure")
    return AzureCliCredential()


def sync_credential(settings: Settings):
    if settings.managed_identity_client_id:
        return SyncManagedIdentityCredential(client_id=settings.managed_identity_client_id)
    return SyncAzureCliCredential()


def openai_client(settings: Settings, credential) -> AsyncOpenAI:
    """OpenAI v1 API on the Foundry resource, authenticated with a refreshing Entra token."""
    return AsyncOpenAI(
        base_url=f"{settings.openai_endpoint}/openai/v1/",
        api_key=get_bearer_token_provider(credential, COGNITIVE_SERVICES_SCOPE),
        timeout=60.0,
        max_retries=3,
    )


def build_kernel(settings: Settings, client: AsyncOpenAI) -> Kernel:
    """Semantic Kernel with one chat service and one embedding service sharing a client."""
    kernel = Kernel()
    kernel.add_service(
        OpenAIChatCompletion(
            ai_model_id=settings.chat_deployment, service_id=CHAT_SERVICE_ID, async_client=client
        )
    )
    kernel.add_service(
        OpenAITextEmbedding(
            ai_model_id=settings.embedding_deployment, service_id=EMBEDDING_SERVICE_ID, async_client=client
        )
    )
    return kernel
