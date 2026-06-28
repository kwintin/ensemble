import asyncio

async def fetch(client, url):
    return await client.get(url)

async def fetch_all(client, urls):
    results = []
    for url in urls:
        results.append(await fetch(client, url))   # serialized; no concurrency
    return results
